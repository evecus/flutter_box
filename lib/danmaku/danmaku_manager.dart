import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'danmaku_api.dart';
import 'danmaku_parser.dart';
import 'danmaku_settings.dart';

/// 弹幕加载状态 (供播放页弹 Toast).
enum DanmakuLoadStatus { idle, loading, ok, none, failed }

/// 弹幕调度管理器:
///   canvas_danmaku 只负责"把弹幕画出来", 不带播放时间轴;
///   本类按播放器位置把带时间戳的弹幕按时加入, 并在 seek 时重新对齐,
///   行为对齐 NovaBox DanmuLoadController (seekTo + start, 缓冲时暂停).
///
/// 加载序号 (_loadSeq) 的约定 (对齐 NovaBox DanmuLoadController.prepare):
///   - 只在"发起一次新加载"的那一刻自增;
///   - [clear] 只清数据与画面, **绝不能**动 _loadSeq —— 否则新取的号会被
///     紧随其后的 clear 立刻作废, 所有加载结果都被当成过期响应丢掉,
///     表现为"弹幕永远加载不出来" (自动搜索与云搜选中都不例外).
class DanmakuManager {
  DanmakuManager._();
  static final DanmakuManager instance = DanmakuManager._();

  DanmakuController<Object?>? _controller;

  /// 控制器已回调, 但 DanmakuScreen 首帧尚未布局完 (内部轨道表未初始化),
  /// 此时投递弹幕会抛 LateInitializationError; 置位后才可以安全 addDanmaku.
  bool _ready = false;

  List<ParsedDanmaku> _entries = [];
  int _nextIdx = 0;
  int _lastPosMs = -1;

  /// 加载状态变化 (播放页监听后弹 Toast).
  final status = ValueNotifier<DanmakuLoadStatus>(DanmakuLoadStatus.idle);

  /// 当前加载序号, 用于丢弃过期请求.
  int _loadSeq = 0;

  bool get hasDanmaku => _entries.isNotEmpty;

  bool get attached => _controller != null;

  void attach(DanmakuController<Object?> controller) {
    _controller = controller;
    _ready = false;
    applySettings();
    // DanmakuScreen 在 initState 里回调 createdController, 此时 build/layout 还没跑,
    // 内部 _trackYPositions 仍是 late 未初始化状态. 等这一帧结束后再允许投递.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!identical(_controller, controller)) return;
      _ready = true;
    });
  }

  void detach() {
    _controller = null;
    _ready = false;
  }

  /// 设置变更后热更新弹幕容器属性 (字号/透明度/速度/行高).
  void applySettings() {
    final controller = _controller;
    if (controller == null) return;
    controller.updateOption(DanmuSettings.instance.buildOption());
  }

  /// 自动搜索并加载弹幕 (对齐 NovaBox PlayFragment.searchDanmu + checkDanmu).
  Future<void> loadBySearch(String name, String episode) async {
    clear();
    if (!DanmuSettings.instance.open) return;
    if (name.trim().isEmpty) return;
    // 先清空, 再取号 —— 顺序颠倒会让本次加载自己把自己作废.
    final seq = ++_loadSeq;
    status.value = DanmakuLoadStatus.loading;
    final source = await DanmakuApi.search(name, episode);
    if (seq != _loadSeq) return;
    if (source == null || source.isEmpty) {
      status.value = DanmakuLoadStatus.none;
      return;
    }
    await _applySource(source, seq);
  }

  /// 直接加载弹幕源 (bilibili XML 或可下载地址), 用于云搜选中的结果
  /// 与爬虫 playerContent 自带的 danmaku 字段.
  Future<void> loadSource(String source, {int? seq}) async {
    clear();
    if (!DanmuSettings.instance.open) return;
    final mySeq = seq ?? ++_loadSeq;
    status.value = DanmakuLoadStatus.loading;
    await _applySource(source, mySeq);
  }

  Future<void> _applySource(String source, int seq) async {
    final List<ParsedDanmaku> entries;
    try {
      entries = await DanmakuParser.parse(source);
    } catch (_) {
      if (seq != _loadSeq) return;
      status.value = DanmakuLoadStatus.failed;
      return;
    }
    if (seq != _loadSeq) return;
    if (entries.isEmpty) {
      status.value = DanmakuLoadStatus.none;
      return;
    }
    _entries = entries;
    _nextIdx = 0;
    // -1 表示"下一次 syncPosition 要先对齐到当前播放位置" (对照 NovaBox seekTo + start).
    _lastPosMs = -1;
    status.value = DanmakuLoadStatus.ok;
  }

  /// 清空当前弹幕 (换集/重新加载前调用).
  ///
  /// 注意: 这里不碰 _loadSeq —— 作废进行中的加载由"发起新加载时自增"完成,
  /// 语义上更清晰, 也不会把紧随其后的新加载误杀.
  void clear() {
    _entries = [];
    _nextIdx = 0;
    _lastPosMs = -1;
    _controller?.clear();
    if (status.value != DanmakuLoadStatus.idle) {
      status.value = DanmakuLoadStatus.idle;
    }
  }

  /// 播放位置同步: 按时加入弹幕; 位置跳变 (seek) 时清空并重新对齐.
  void syncPosition(Duration position) {
    if (_entries.isEmpty || !_ready) return;
    final posMs = position.inMilliseconds;
    // _lastPosMs < 0: 刚加载完弹幕, 先对齐到当前播放位置 (NovaBox 的 seekTo + start).
    final seeked = _lastPosMs < 0 || (posMs - _lastPosMs).abs() > 1000;
    if (seeked) {
      _controller?.clear();
      // 留 500ms 余量, 避免回溯到刚播过的弹幕.
      _nextIdx = _indexOf(posMs - 500);
    }
    _lastPosMs = posMs;
    // 每拍最多加入 N 条, 避免密集弹幕在一帧内全部涌入造成卡顿;
    // seek 后允许一次补更多, 尽快追平当前进度.
    final limit = seeked ? 40 : 8;
    var added = 0;
    while (_nextIdx < _entries.length && _entries[_nextIdx].timeMs <= posMs + 300) {
      _controller?.addDanmaku(_entries[_nextIdx].item);
      _nextIdx++;
      added++;
      if (added >= limit) break;
    }
  }

  void setPlaying(bool playing) {
    final controller = _controller;
    if (controller == null) return;
    if (playing) {
      controller.resume();
    } else {
      controller.pause();
    }
  }

  /// 缓冲中: 冻结弹幕动画, 避免缓冲结束瞬间弹幕跳变 (对照 NovaBox pauseForBuffering).
  void setBuffering(bool buffering) {
    final controller = _controller;
    if (controller == null) return;
    if (buffering) {
      controller.pause();
    } else if (DanmuSettings.instance.open) {
      controller.resume();
    }
  }

  /// 二分查找第一个时间 >= targetMs 的条目下标.
  int _indexOf(int targetMs) {
    var lo = 0;
    var hi = _entries.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_entries[mid].timeMs < targetMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
