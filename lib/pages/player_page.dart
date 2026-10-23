import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../config/config.dart';
import '../data/history.dart';
import '../data/play_resolver.dart';
import '../data/watch_progress.dart';
import '../engine/engine_channel.dart';

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
      enableHardwareAcceleration: false,
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

  String get _epName =>
      _idx >= 0 && _idx < widget.epNames.length ? widget.epNames[_idx] : '第${_idx + 1}集';

  @override
  void initState() {
    super.initState();
    _idx = widget.startIndex.clamp(0, widget.epUrls.isEmpty ? 0 : widget.epUrls.length - 1);
    _bindStreams();
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

  Future<void> _openIndex(int index, {bool resume = false}) async {
    setState(() {
      _idx = index;
      _loading = true;
      _error = '';
      _restorePos = 0;
      _restoreDone = false;
    });
    final info = await PlayResolver.resolve(widget.site, widget.flag, widget.epUrls[index]);
    if (!mounted) return;
    if (info == null) {
      setState(() {
        _loading = false;
        _error = '没有可播放的地址\n(可能需要浏览器嗅探, 目前无法 support)';
      });
      return;
    }
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

  void _playNext() {
    if (_idx + 1 >= widget.epUrls.length) return;
    _openIndex(_idx + 1);
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
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
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.vodName} · $_epName'),
        actions: [
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
              child: Video(
                controller: _controller,
                controls: AdaptiveVideoControls,
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
}
