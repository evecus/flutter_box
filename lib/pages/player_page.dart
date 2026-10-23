import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../config/config.dart';
import '../danmaku/danmaku_dialogs.dart';
import '../danmaku/danmaku_manager.dart';
import '../danmaku/danmaku_settings.dart';
import '../data/history.dart';
import '../data/play_resolver.dart';
import '../data/watch_progress.dart';
import '../engine/engine_channel.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';

class PlayerPage extends StatefulWidget {
  final Site site;
  final String vodId;
  final String vodName;
  final String cover;
  final String flag;
  final List<String> epNames;
  final List<String> epUrls;
  final int startIndex;

  const PlayerPage({
    super.key,
    required this.site,
    required this.vodId,
    required this.vodName,
    required this.cover,
    required this.flag,
    required this.epNames,
    required this.epUrls,
    this.startIndex = 0,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final Player _player = Player();
  // 有声无画的常见原因: mpv 默认 hwdec=auto-safe 走 mediacodec 零拷贝 (直接渲染到 Surface),
  // 联发科/ColorOS 等机型上解码器输出格式不被 GL 纹理接受, 表现为只有声音黑屏.
  // mediacodec-copy 仍是硬解, 但帧拷回内存再上传纹理, 兼容性好得多.
  // 若仍黑屏, 把 hwdec 改成 'no' (纯软解) 再试.
  late final VideoController _controller = VideoController(
    _player,
    configuration: const VideoControllerConfiguration(
      hwdec: 'mediacodec-copy',
      // 日志显示 mediacodec 解码器已正常启动, 黑屏发生在"GL 纹理渲染"一环 (联发科/ColorOS
      // 上 media_kit 的 GPU 纹理路径可能拿不到画面). 关闭 GPU 渲染, 改走 CPU 像素缓冲纹理:
      // 解码仍由 mediacodec-copy 硬解, 只是上屏改用软件路径, 兼容性最好.
      enableHardwareAcceleration: true,
    ),
  );

  late int _idx;
  bool _loading = true;
  String _error = '';
  int _restorePos = 0;
  bool _restoreDone = false;
  int _lastSavedMs = 0;
  DateTime _lastSaveAt = DateTime.now();

  final _subs = <StreamSubscription<dynamic>>[];

  // ---- TV 全屏: 控制层自动隐藏 / 遥控器快进快退提示 ----
  static const _kTvOverlaySeconds = 8;
  bool _tvOverlay = true; // 进入时先显示一会儿 (含选集), 无操作后自动隐藏
  Timer? _tvOverlayTimer;
  final FocusNode _tvRootNode = FocusNode(debugLabel: 'player-root');
  final ValueNotifier<String> _seekHint = ValueNotifier<String>('');
  Timer? _seekHintTimer;

  /// 当前集是否已触发过弹幕搜索 (设置里开启弹幕后据此补搜).
  bool _danmakuSearched = false;

  String get _epName =>
      _idx >= 0 && _idx < widget.epNames.length ? widget.epNames[_idx] : '第${_idx + 1}集';

  @override
  void initState() {
    super.initState();
    _idx = widget.startIndex.clamp(0, widget.epUrls.isEmpty ? 0 : widget.epUrls.length - 1);
    if (TvMode.isTV.value) {
      // TV 全屏: 隐藏系统栏 (部分盒子/电视有状态栏或导航条), 控制层几秒后自动收起.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _showTvOverlay();
    }
    _bindStreams();
    // 弹幕设置变更 (行数/边距/开关等) → 重建弹幕区域 + 热更新容器属性.
    DanmuSettings.instance.revision.addListener(_onDanmuSettingsChanged);
    DanmakuManager.instance.status.addListener(_onDanmuStatus);
    _openIndex(_idx, resume: true);
  }

  void _bindStreams() {
    // 解码/渲染错误留痕, 便于 logcat 排查 (flutter: [player] ...)
    _subs.add(_player.stream.error.listen((e) => debugPrint('[player] error: $e')));
    _subs.add(_player.stream.width.listen((w) => debugPrint('[player] width=$w height=${_player.state.height}')));
    _subs.add(_player.stream.tracks.listen((t) => debugPrint(
        '[player] tracks video=${t.video.map((e) => '${e.id}:${e.codec}:${e.w}x${e.h}').toList()} audio=${t.audio.length}')));
    _subs.add(_player.stream.videoParams.listen((v) => debugPrint('[player] videoParams=$v')));
    _subs.add(_player.stream.log.listen((l) {
      if (l.level == 'error' || l.level == 'warn') debugPrint('[player] ${l.prefix}: ${l.text}');
    }));
    // Restore saved position once duration becomes known.
    _subs.add(_player.stream.duration.listen((d) async {
      if (_restoreDone || _restorePos <= 0 || d.inMilliseconds <= 0) return;
      if (d.inMilliseconds > _restorePos + 1000) {
        await _player.seek(Duration(milliseconds: _restorePos));
      }
      _restoreDone = true;
    }));

    // 弹幕: 播放位置驱动弹幕按时加入 (canvas_danmaku 无时间轴, 自行调度).
    _subs.add(_player.stream.position.listen((p) {
      DanmakuManager.instance.syncPosition(p);
    }));
    // 弹幕: 播放/暂停与缓冲同步 (对照 NovaTV startIfReady / pauseForBuffering).
    _subs.add(_player.stream.playing.listen((p) {
      DanmakuManager.instance.setPlaying(p);
    }));
    _subs.add(_player.stream.buffering.listen((b) {
      DanmakuManager.instance.setBuffering(b);
    }));

    // Periodic progress save (>= 5s moved & >= 10s elapsed since last save).
    _subs.add(_player.stream.position.listen((p) async {
      final ms = p.inMilliseconds;
      if (!_restoreDone && _restorePos > 0 && ms < _restorePos - 2000) return;
      if (ms - _lastSavedMs < 5000) return;
      final now = DateTime.now();
      if (now.difference(_lastSaveAt) < const Duration(seconds: 10) && _lastSavedMs > 0) {
        return;
      }
      _lastSaveAt = now;
      _lastSavedMs = ms;
      final dur = _player.state.duration.inMilliseconds;
      await WatchProgress.save(widget.site.key, widget.vodId, widget.vodName, _epName, ms, dur);
      await History.record(
        widget.site.key,
        widget.site.name,
        widget.vodId,
        widget.vodName,
        widget.cover,
        _epName,
        widget.epUrls[_idx],
        ms,
        dur,
      );
    }));
  }

  void _onDanmuSettingsChanged() {
    DanmakuManager.instance.applySettings();
    // 关闭→开启弹幕时补搜当前集.
    if (DanmuSettings.instance.open && !_danmakuSearched) {
      DanmakuManager.instance.loadBySearch(widget.vodName, _epName);
      _danmakuSearched = true;
    }
    if (mounted) setState(() {});
  }

  void _onDanmuStatus() {
    if (!mounted) return;
    final s = DanmakuManager.instance.status.value;
    if (s == DanmakuLoadStatus.ok) {
      _showMsg('加载弹幕成功');
    } else if (s == DanmakuLoadStatus.none) {
      _showMsg('未查询到匹配弹幕');
    } else if (s == DanmakuLoadStatus.failed) {
      _showMsg('加载弹幕失败');
    }
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openIndex(int index, {bool resume = false}) async {
    setState(() {
      _idx = index;
      _loading = true;
      _error = '';
      _restorePos = 0;
      _restoreDone = false;
      _danmakuSearched = false;
    });
    // 换集: 重置弹幕 (对照 NovaTV 的 resetDanmuState / check("")).
    // 注意这里不再无脑发起云搜 —— 对齐 NovaBox PlayFragment:
    //   爬虫 playerContent 自带了 danmaku 就直接用它; 只有没带时才云搜.
    _danmakuSearched = false;
    DanmakuManager.instance.clear();
    final info = await PlayResolver.resolve(widget.site, widget.flag, widget.epUrls[index]);
    if (!mounted) return;
    if (info == null) {
      setState(() {
        _loading = false;
        _error = '没有可播放的地址\n(可能需要浏览器嗅探, 目前无法 support)';
      });
      return;
    }
    _startDanmaku(info.danmaku);
    if (resume) {
      final saved = await WatchProgress.load(widget.site.key, widget.vodId);
      if (!mounted) return;
      if (saved != null) {
        final savedEp = saved['ep'] as String? ?? '';
        final pos = (saved['pos'] as int?) ?? 0;
        if (savedEp == _epName && pos > 5000) {
          _restorePos = pos - 3000;
          _lastSavedMs = pos;
        } else {
          _restorePos = 0;
        }
      }
    }
    try {
      await _player.open(Media(info.url, httpHeaders: info.headers));
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '播放初始化失败: $e';
      });
    }
  }

  /// 弹幕入口 (对照 NovaBox PlayFragment 的 searchDanmu / checkDanmu):
  ///   - [source] 非空 = 爬虫自带弹幕地址, 直接加载;
  ///   - 为空 = 用 片名 + 集名 走内置/自定义接口自动搜索;
  ///   - 自动搜索失败时 NovaBox 会回调 checkDanmu("") 做一次收尾, 这里等价处理.
  void _startDanmaku(String source) {
    _danmakuSearched = true;
    if (source.trim().isNotEmpty) {
      DanmakuManager.instance.loadSource(source.trim());
    } else {
      DanmakuManager.instance.loadBySearch(widget.vodName, _epName);
    }
  }

  void _playNext() {
    if (_idx + 1 >= widget.epUrls.length) return;
    _openIndex(_idx + 1);
  }

  /// 弹幕开关 (对照 NovaTV toggleDanmu: 开启时需要重新触发加载).
  Future<void> _toggleDanmu() async {
    final next = !DanmuSettings.instance.open;
    await DanmuSettings.instance.setOpen(next);
    DanmakuManager.instance.applySettings();
    if (next && !DanmakuManager.instance.hasDanmaku) {
      _danmakuSearched = true;
      DanmakuManager.instance.loadBySearch(widget.vodName, _epName);
    }
    if (mounted) setState(() {});
    _showMsg(next ? '弹幕已开启' : '弹幕已关闭');
  }

  void _openDanmuSetting() {
    DanmuDialogs.showFullSetting(context);
  }

  void _openDanmuSearch() {
    DanmuDialogs.showSearch(
      context,
      initialWord: widget.vodName,
      episode: _epName,
      onLoaded: (source) {
        DanmakuManager.instance.loadSource(source);
      },
    );
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    DanmuSettings.instance.revision.removeListener(_onDanmuSettingsChanged);
    DanmakuManager.instance.status.removeListener(_onDanmuStatus);
    DanmakuManager.instance.clear();
    DanmakuManager.instance.detach();
    // 对照原版播放页退出: setCurrentPlaySourceKey("")
    EngineChannel.setPlaySource('');
    _lastSavedMs = _player.state.position.inMilliseconds;
    if (_lastSavedMs > 0) {
      // Fire and forget; async writes after dispose are fine here.
      WatchProgress.save(
        widget.site.key,
        widget.vodId,
        widget.vodName,
        _epName,
        _lastSavedMs,
        _player.state.duration.inMilliseconds,
      );
    }
    _tvOverlayTimer?.cancel();
    _seekHintTimer?.cancel();
    _seekHint.dispose();
    _tvRootNode.dispose();
    if (TvMode.isTV.value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!TvMode.isTV.value) {
      // ---------------- 手机: 原布局 (AppBar + 16:9 视频 + 竖排选集) ----------------
      return Scaffold(
        appBar: AppBar(
          title: Text('${widget.vodName} · $_epName'),
          actions: [
            IconButton(
              icon: const Icon(Icons.subtitles_outlined),
              tooltip: '弹幕开关',
              onPressed: _toggleDanmu,
            ),
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: '弹幕设置',
              onPressed: _openDanmuSetting,
            ),
            IconButton(
              icon: const Icon(Icons.travel_explore),
              tooltip: '弹幕云搜',
              onPressed: _openDanmuSearch,
            ),
            if (widget.epUrls.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.skip_next_outlined),
                tooltip: '下一集',
                onPressed: _idx + 1 >= widget.epUrls.length ? null : _playNext,
              ),
          ],
        ),
        // Video 必须始终挂载: 以前 loading 时整页换成状态视图, open 完成后才创建 Video,
        // 纹理在"无人消费"的状态下起播, 部分机型因此有声无画.
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Video(
                      controller: _controller,
                      controls: AdaptiveVideoControls,
                    ),
                    _danmakuLayer(),
                  ],
                ),
              ),
              Expanded(
                child: _loading || _error.isNotEmpty ? _statusView() : _episodeBar(),
              ),
            ],
          ),
        ),
      );
    }
    // ---------------- TV: 全屏播放 ----------------
    // 视频铺满整屏; 顶栏/控制条/选集组成"控制层", 无操作 8 秒自动隐藏:
    //   隐藏时: OK=播放/暂停, 左/右=快退/快进 10s (显示进度提示), 上/下=唤出控制层, 返回=退出;
    //   显示时: 方向键在控制条/选集间移动焦点, 返回=先收起控制层.
    // 出错时强制显示控制层 (否则遥控器无处落焦点).
    final overlay = _tvOverlay || _error.isNotEmpty;
    return PopScope(
      canPop: !overlay,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _hideTvOverlay();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _tvRootNode,
          canRequestFocus: true,
          onKeyEvent: _onTvKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 必须显式 NoVideoControls: 默认的 AdaptiveVideoControls 是为鼠标/触摸设计的,
              // 会在 TV 上叠出第二套控件.
              Video(controller: _controller, controls: NoVideoControls),
              // 弹幕层: 位于视频之上, 控制层之下.
              _danmakuLayer(),
              if (overlay) ...[
                Positioned(left: 0, right: 0, top: 0, child: _tvTopBar()),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [_tvControlBar(), _tvEpisodeBar()],
                  ),
                ),
              ],
              // 控制层隐藏时的快进快退提示
              ValueListenableBuilder<String>(
                valueListenable: _seekHint,
                builder: (_, hint, __) => hint.isEmpty
                    ? const SizedBox.shrink()
                    : Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(hint, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
              ),
              if (_loading || _error.isNotEmpty) _statusView(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- TV 控制层显隐 / 按键 ----------------

  void _showTvOverlay() {
    _tvOverlayTimer?.cancel();
    if (!_tvOverlay && mounted) setState(() => _tvOverlay = true);
    _tvOverlayTimer = Timer(const Duration(seconds: _kTvOverlaySeconds), _hideTvOverlay);
  }

  void _hideTvOverlay() {
    _tvOverlayTimer?.cancel();
    if (!mounted || !_tvOverlay) return;
    setState(() => _tvOverlay = false);
    // 控制层卸载后焦点要回到根节点, 否则按键没人接 (根 Focus 才处理隐藏态按键).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tvRootNode.requestFocus();
    });
  }

  void _tvSeek(int seconds) {
    final dur = _player.state.duration;
    var target = _player.state.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    _player.seek(target);
    _seekHint.value = '${seconds > 0 ? '⏩' : '⏪'} ${_fmt(target)} / ${_fmt(dur)}';
    _seekHintTimer?.cancel();
    _seekHintTimer = Timer(const Duration(milliseconds: 1200), () => _seekHint.value = '');
  }

  KeyEventResult _onTvKey(FocusNode node, KeyEvent event) {
    // MENU 键: 弹幕开关 / 设置 (原有逻辑)
    if (_onMenuKey(node, event) == KeyEventResult.handled) return KeyEventResult.handled;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;

    // 遥控器媒体键: 任何状态都生效
    if (event is KeyDownEvent) {
      if (k == LogicalKeyboardKey.mediaPlayPause) {
        _player.playOrPause();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.mediaPlay) {
        _player.play();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.mediaPause) {
        _player.pause();
        return KeyEventResult.handled;
      }
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _tvSeek(30);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _tvSeek(-30);
      return KeyEventResult.handled;
    }

    if (_tvOverlay || _error.isNotEmpty) {
      // 控制层显示中: 任意按键续命, 方向键交给焦点遍历.
      _showTvOverlay();
      return KeyEventResult.ignored;
    }
    // 控制层隐藏中
    if (k == LogicalKeyboardKey.arrowLeft) {
      _tvSeek(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _tvSeek(10);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA) {
      _player.playOrPause();
      _showTvOverlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      _showTvOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 弹幕覆盖层: 位置/高度由设置决定 (顶边距 + 行数×字号×行高),
  /// canvas_danmaku 按容器高度自动计算轨道数.
  Widget _danmakuLayer() {
    return ValueListenableBuilder<int>(
      valueListenable: DanmuSettings.instance.revision,
      builder: (ctx, _, __) {
        final s = DanmuSettings.instance;
        if (!s.open) {
          DanmakuManager.instance.detach();
          return const SizedBox.shrink();
        }
        return Positioned(
          left: 0,
          right: 0,
          top: s.topMarginPx.toDouble(),
          height: s.trackHeightPx,
          child: DanmakuScreen<Object?>(
            key: const ValueKey('danmaku-screen'),
            createdController: (c) {
              DanmakuManager.instance.attach(c);
            },
            option: s.buildOption(),
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  void _seekBy(int seconds) {
    final target = _player.state.position + Duration(seconds: seconds);
    final dur = _player.state.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    _player.seek(clamped);
  }

  /// 顶部悬浮条: 返回 + 标题 + 下一集 (对照原版 PlayActivity 顶栏).
  Widget _tvTopBar() {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          TvButton(
            label: '返回',
            icon: Icons.arrow_back,
            height: 46,
            fontSize: 16,
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              '${widget.vodName} · $_epName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18),
            ),
          ),
          if (widget.epUrls.isNotEmpty)
            TvButton(
              label: '下一集',
              icon: Icons.skip_next_outlined,
              height: 46,
              fontSize: 16,
              onTap: _idx + 1 >= widget.epUrls.length ? null : _playNext,
            ),
        ],
      ),
    );
  }

  /// 底部控制条: 播放/暂停 + 快退/快进 + 进度条 + 弹幕行 (全部可被遥控器聚焦).
  Widget _tvControlBar() {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              StreamBuilder<bool>(
                stream: _player.stream.playing,
                initialData: _player.state.playing,
                builder: (ctx, snap) => TvButton(
                  autofocus: true,
                  label: snap.data == true ? '暂停' : '播放',
                  icon: snap.data == true ? Icons.pause : Icons.play_arrow,
                  height: 48,
                  fontSize: 16,
                  onTap: () => _player.playOrPause(),
                ),
              ),
              const SizedBox(width: 8),
              TvButton(
                label: '快退 10s',
                icon: Icons.replay_10,
                height: 48,
                fontSize: 16,
                onTap: () => _seekBy(-10),
              ),
              const SizedBox(width: 8),
              TvButton(
                label: '快进 10s',
                icon: Icons.forward_10,
                height: 48,
                fontSize: 16,
                onTap: () => _seekBy(10),
              ),
              const Spacer(),
              // 弹幕行: 开关 / 设置 / 云搜 (对照原版 VodController 弹幕按钮).
              TvButton(
                label: DanmuSettings.instance.open ? '弹幕开' : '弹幕关',
                icon: Icons.subtitles_outlined,
                height: 48,
                fontSize: 16,
                onTap: _toggleDanmu,
              ),
              const SizedBox(width: 8),
              TvButton(
                label: '弹幕设置',
                icon: Icons.tune,
                height: 48,
                fontSize: 16,
                onTap: _openDanmuSetting,
              ),
              const SizedBox(width: 8),
              TvButton(
                label: '弹幕云搜',
                icon: Icons.travel_explore,
                height: 48,
                fontSize: 16,
                onTap: _openDanmuSearch,
              ),
            ],
          ),
          Row(
            children: [
              SizedBox(
                width: 60,
                child: Text(_fmt(_player.state.position),
                    style: const TextStyle(fontSize: 14)),
              ),
              Expanded(
                child: StreamBuilder<Duration>(
                  stream: _player.stream.position,
                  builder: (ctx, snap) {
                    final pos = snap.data ?? _player.state.position;
                    final dur = _player.state.duration;
                    final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;
                    return Slider(
                      value: pos.inMilliseconds.clamp(0, maxMs).toDouble(),
                      max: maxMs.toDouble(),
                      onChanged: (v) =>
                          _player.seek(Duration(milliseconds: v.toInt())),
                    );
                  },
                ),
              ),
              SizedBox(
                width: 60,
                child: Text(_fmt(_player.state.duration),
                    style: const TextStyle(fontSize: 14)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// TV 选集: 横向排列的可聚焦按钮 (对照原版 PlayActivity 底部选集).
  Widget _tvEpisodeBar() {
    if (widget.epUrls.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 96,
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: widget.epUrls.length,
        itemBuilder: (ctx, i) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TvButton(
            label: widget.epNames[i].isEmpty ? '第${i + 1}集' : widget.epNames[i],
            selected: i == _idx,
            height: 64,
            fontSize: 16,
            onTap: i == _idx ? null : () => _openIndex(i),
          ),
        ),
      ),
    );
  }

  Widget _statusView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error.isEmpty)
            const SizedBox(width: 38, height: 38, child: CircularProgressIndicator(strokeWidth: 3)),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_error, textAlign: TextAlign.center),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
              if (_error.isNotEmpty)
                TextButton(
                  onPressed: () => _openIndex(_idx, resume: false),
                  child: const Text('重试'),
                ),
              if (_error.isEmpty && _idx + 1 < widget.epUrls.length)
                TextButton(onPressed: _playNext, child: const Text('下一集')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _episodeBar() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: widget.epUrls.length,
      itemBuilder: (ctx, i) {
        final selected = i == _idx;
        return ListTile(
          dense: true,
          selected: selected,
          leading: Text(
            '$i',
            style: TextStyle(
              color: selected ? Theme.of(context).colorScheme.primary : Colors.grey,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          title: Text(
            widget.epNames[i].isEmpty ? '第${i + 1}集' : widget.epNames[i],
            style: TextStyle(
              color: selected ? Theme.of(context).colorScheme.primary : null,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          onTap: selected ? null : () => _openIndex(i),
        );
      },
    );
  }

  // ---------------- TV 遥控 MENU 键: 短按切换弹幕 / 长按 2s 弹幕设置 ----------------

  DateTime? _menuDownAt;

  KeyEventResult _onMenuKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.contextMenu) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _menuDownAt = DateTime.now();
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent && _menuDownAt != null) {
      final held = DateTime.now().difference(_menuDownAt!);
      _menuDownAt = null;
      if (held >= const Duration(seconds: 2)) {
        _openDanmuSetting();
      } else {
        _toggleDanmu();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
