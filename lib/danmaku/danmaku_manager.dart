import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';

import 'danmaku_api.dart';
import 'danmaku_parser.dart';
import 'danmaku_settings.dart';

/// 弹幕加载状态 (供播放页弹 Toast).
enum DanmakuLoadStatus { idle, loading, ok, none, failed }

/// 弹幕调度管理器:
///   canvas_danmaku 只负责"把弹幕画出来", 不带播放时间轴;
///   本类按播放器位置把带时间戳的弹幕按时加入, 并在 seek 时重新对齐,
///   行为对齐 NovaTV DanmuLoadController (seekTo + start, 缓冲时暂停).
class DanmakuManager {
  DanmakuManager._();
  static final DanmakuManager instance = DanmakuManager._();

  DanmakuController<Object?>? _controller;
  List<ParsedDanmaku> _entries = [];
  int _nextIdx = 0;
  int _lastPosMs = -1;
  bool _attached = false;

  /// 加载状态变化 (播放页监听后弹 Toast).
  final status = ValueNotifier<DanmakuLoadStatus>(DanmakuLoadStatus.idle);

  /// 当前加载序号, 用于丢弃过期请求.
  int _loadSeq = 0;

  bool get hasDanmaku => _entries.isNotEmpty;

  void attach(DanmakuController<Object?> controller) {
    _controller = controller;
    _attached = true;
    applySettings();
  }

  void detach() {
    _controller = null;
    _attached = false;
  }

  /// 设置变更后热更新弹幕容器属性 (字号/透明度/速度/行高).
  void applySettings() {
    if (!_attached) return;
    _controller?.updateOption(DanmuSettings.instance.buildOption());
  }

  /// 自动搜索并加载弹幕 (对照 NovaTV check(danmu, title, episode)).
  Future<void> loadBySearch(String name, String episode) async {
    final seq = ++_loadSeq;
    clear();
    if (!DanmuSettings.instance.open) return;
    if (name.trim().isEmpty) return;
    status.value = DanmakuLoadStatus.loading;
    final source = await DanmakuApi.search(name, episode);
    if (seq != _loadSeq) return;
    if (source == null || source.isEmpty) {
      status.value = DanmakuLoadStatus.none;
      return;
    }
    await loadSource(source, seq: seq);
  }

  /// 直接加载弹幕源 (bilibili XML 或可下载地址), 用于云搜选中的结果.
  Future<void> loadSource(String source, {int? seq}) async {
    final mySeq = seq ?? ++_loadSeq;
    clear();
    if (!DanmuSettings.instance.open) return;
    status.value = DanmakuLoadStatus.loading;
    final entries = await DanmakuParser.parse(source);
    if (mySeq != _loadSeq) return;
    if (entries.isEmpty) {
      status.value = DanmakuLoadStatus.none;
      return;
    }
    _entries = entries;
    _nextIdx = 0;
    _lastPosMs = -1;
    status.value = DanmakuLoadStatus.ok;
  }

  /// 清空当前弹幕 (换集/重新加载前调用).
  void clear() {
    _entries = [];
    _nextIdx = 0;
    _lastPosMs = -1;
    _loadSeq++;
    _controller?.clear();
    if (status.value != DanmakuLoadStatus.idle) {
      status.value = DanmakuLoadStatus.idle;
    }
  }

  /// 播放位置同步: 按时加入弹幕; 位置跳变 (seek) 时清空并重新对齐.
  void syncPosition(Duration position) {
    if (_entries.isEmpty || !_attached) return;
    final posMs = position.inMilliseconds;
    if (_lastPosMs >= 0 && (posMs - _lastPosMs).abs() > 1000) {
      // seek: 重新对齐到当前位置 (留 500ms 余量避免回溯重复).
      _controller?.clear();
      _nextIdx = _indexOf(posMs - 500);
    }
    _lastPosMs = posMs;
    // 每拍最多加入 8 条, 避免密集弹幕在一帧内全部涌入造成卡顿.
    var added = 0;
    while (_nextIdx < _entries.length && _entries[_nextIdx].timeMs <= posMs + 300) {
      _controller?.addDanmaku(_entries[_nextIdx].item);
      _nextIdx++;
      added++;
      if (added >= 8) break;
    }
  }

  void setPlaying(bool playing) {
    if (!_attached) return;
    if (playing) {
      _controller?.resume();
    } else {
      _controller?.pause();
    }
  }

  /// 缓冲中: 冻结弹幕动画, 避免缓冲结束瞬间弹幕跳变 (对照 NovaTV pauseForBuffering).
  void setBuffering(bool buffering) {
    if (!_attached) return;
    if (buffering) {
      _controller?.pause();
    } else if (DanmuSettings.instance.open) {
      _controller?.resume();
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
