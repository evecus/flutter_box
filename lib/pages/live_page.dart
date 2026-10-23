import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../live/live_models.dart';
import '../live/live_store.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';
import 'root_page.dart';

// ---- 原版视觉规范 (对照 shape_live_focus / LiveChannelItemAdapter) ----
const _kBlue = Color(0xFF1890FF); // color_1890FF
const _kSelectedBg = Color(0x331890FF); // #331890FF
const _kBadgeBg = Color(0x6C3D3D3D); // shape_user_search 常态底色
const _kBadgeSeconds = 6; // 原版 postTimeout
const _kOverlaySeconds = 4; // 原版 controlOverlayTimer

/// 直播页 (对照原版 LiveFragment, 最小范围).
///
/// 设置页配置一个直播源地址 → 进入本页拉取直播列表 (m3u/txt/json) →
/// 分组/频道/线路三列点击播放.
/// 明确不做: 回看 / 多源切换 / EPG / 画面比例 / 播放解码 / 超时换源配置
/// (超时用默认值: 缓冲 10s 换源, 出错 3.5s 换源, 对照原版默认).
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  // ---- 直播列表数据 ----
  List<LiveChannelGroup> _groups = const [];
  bool _loading = false;
  bool _noSource = false;
  String _error = '';

  // ---- 选中/播放状态 (对照 LiveFragment 字段) ----
  int _selectedGroupIndex = -1; // liveChannelGroupAdapter.selectedGroupIndex
  int _selectedChannelIndex = -1; // liveChannelItemAdapter.selectedChannelIndex
  int _playGroupIndex = -1; // currentChannelGroupIndex
  int _playChannelIndex = -1; // currentLiveChannelIndex
  LiveChannelItem? _currentChannel; // currentLiveChannelItem
  final Set<int> _passwordConfirmed = {}; // channelGroupPasswordConfirmed
  int _changeSourceTimes = 0; // currentLiveChangeSourceTimes
  bool _needManualPlay = false; // needManualPlay

  // ---- 播放器 (硬解配置与播放页一致) ----
  final Player _player = Player();
  late final VideoController _controller = VideoController(
    _player,
    configuration: const VideoControllerConfiguration(
      hwdec: 'mediacodec-copy',
      enableHardwareAcceleration: true,
    ),
  );
  final _subs = <StreamSubscription<dynamic>>[];
  bool _videoMounted = false; // Video 必须始终挂载 (见播放页注释)
  bool _playing = false;
  bool _buffering = false;

  // ---- 手机控制浮层 / 竖屏全屏 ----
  bool _overlayVisible = false;
  Timer? _overlayTimer;
  bool _portraitFullscreen = false;

  // ---- 右上角频道名角标 ----
  bool _badgeVisible = false;
  String _badgeName = '';
  Timer? _badgeTimer;

  // ---- 自动换源定时器 ----
  Timer? _bufferTimeoutTimer;
  Timer? _errorRetryTimer;

  // ---- 列表滚动定位 (对照 scrollToPosition) ----
  final _groupKeys = <int, GlobalKey>{};
  final _channelKeys = <int, GlobalKey>{};
  final _sourceKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _bindStreams();
    RootPage.tabIndex.addListener(_onTabChanged);
    LiveStore.instance.liveUrlChanged.addListener(_onLiveUrlChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    RootPage.tabIndex.removeListener(_onTabChanged);
    LiveStore.instance.liveUrlChanged.removeListener(_onLiveUrlChanged);
    _badgeTimer?.cancel();
    _overlayTimer?.cancel();
    _cancelTimers();
    for (final s in _subs) {
      s.cancel();
    }
    RootPage.liveFullscreen.value = false;
    _player.dispose();
    super.dispose();
  }

  // ================= 数据加载 =================

  Future<void> _bootstrap() async {
    await LiveStore.instance.init();
    if (!mounted) return;
    if (LiveStore.instance.liveUrl.isEmpty) {
      // 对照 showNoLiveSourceTip: 未配置直播源
      setState(() => _noSource = true);
      return;
    }
    await _loadLives();
  }

  Future<void> _loadLives() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final (ok, msg, groups) =
        await LiveStore.fetchAndParse(LiveStore.instance.liveUrl);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _loading = false;
        _error = msg;
        _groups = const [];
      });
      return;
    }
    _groups = groups;
    _initLiveState();
    setState(() {
      _loading = false;
      _error = '';
    });
    _scrollIntoView();
  }

  void _onLiveUrlChanged() {
    if (!mounted) return;
    final url = LiveStore.instance.liveUrlChanged.value;
    if (url.isEmpty) {
      setState(() {
        _groups = const [];
        _noSource = true;
        _error = '';
      });
      _resetPlayState();
      return;
    }
    _noSource = false;
    _loadLives();
  }

  /// 对照 initLiveState: 定位上次频道 (仅高亮不自动播放),
  /// 没有则落到第一个无密码分组.
  void _initLiveState() {
    final lastChannelName = LiveStore.instance.lastChannelName;
    var lastGroupIndex = -1;
    var lastChannelIndex = -1;
    if (lastChannelName.isNotEmpty) {
      for (final g in _groups) {
        if (g.channels.isEmpty) continue;
        for (final c in g.channels) {
          if (c.channelName == lastChannelName) {
            lastGroupIndex = g.groupIndex;
            lastChannelIndex = c.channelIndex;
            break;
          }
        }
        if (lastGroupIndex != -1) break;
      }
    }
    if (lastGroupIndex == -1) {
      lastGroupIndex = _firstNoPasswordGroup();
      if (lastGroupIndex == -1) lastGroupIndex = 0;
      lastChannelIndex = 0;
    }
    _selectedGroupIndex = lastGroupIndex;
    // 密码分组不确认则不亮频道 (对照 loadChannelGroupDataOnly)
    _selectedChannelIndex =
        _needPassword(lastGroupIndex) ? -1 : lastChannelIndex;
    _playGroupIndex = -1;
    _playChannelIndex = -1;
    _currentChannel = null;
  }

  void _resetPlayState() {
    _cancelTimers();
    _selectedGroupIndex = -1;
    _selectedChannelIndex = -1;
    _playGroupIndex = -1;
    _playChannelIndex = -1;
    _currentChannel = null;
    _passwordConfirmed.clear();
    _changeSourceTimes = 0;
    _player.stop();
    if (mounted) {
      setState(() {
        _playing = false;
        _buffering = false;
      });
    }
  }

  // ================= 播放核心 (对照 playChannel) =================

  /// [changeSource] 换源 (不重置当前频道); [force] 强制重载 (刷新用,
  /// 绕过原版的"同频道/唯一线路"短路分支).
  bool _playChannel(int groupIndex, int channelIndex,
      {bool changeSource = false, bool force = false}) {
    final item = _channelAt(groupIndex, channelIndex);
    if (item == null || item.sourceNum == 0) return false;
    final sameChannel =
        groupIndex == _playGroupIndex && channelIndex == _playChannelIndex;
    if (!force &&
        !_needManualPlay &&
        ((sameChannel && !changeSource) ||
            (changeSource &&
                _currentChannel != null &&
                _currentChannel!.sourceNum == 1))) {
      // 点击当前已选频道/唯一线路: 不重载, 暂停中则补一次播放
      if (!_playing) _player.play();
      return true;
    }
    if (changeSource && _currentChannel == null) return false;
    _needManualPlay = false;
    if (!changeSource) {
      _playGroupIndex = groupIndex;
      _playChannelIndex = channelIndex;
      _currentChannel = item;
      LiveStore.instance.setLastChannelName(item.channelName);
    }
    // UI 高亮同步 (对照 playChannel 末尾的 adapter 同步)
    _selectedGroupIndex = _playGroupIndex;
    _selectedChannelIndex = _playChannelIndex;
    _changeSourceTimes = 0;
    _videoMounted = true;
    _showBadge(item.channelName);
    _cancelTimers();
    _player.open(Media(item.url, httpHeaders: item.getHeaders()));
    setState(() {});
    _scrollIntoView();
    return true;
  }

  void _playPreSource() {
    if (_currentChannel == null) return;
    _currentChannel!.preSource();
    _playChannel(_playGroupIndex, _playChannelIndex, changeSource: true);
  }

  void _playNextSource() {
    if (_currentChannel == null) return;
    _currentChannel!.nextSource();
    _playChannel(_playGroupIndex, _playChannelIndex, changeSource: true);
  }

  /// 线路点击 (对照 playChannelBySource).
  void _playChannelBySource(int sourceIndex) {
    final item = _currentChannel;
    if (item == null) return;
    if (sourceIndex < 0 || sourceIndex >= item.sourceNum) return;
    item.sourceIndex = sourceIndex;
    _playChannel(_playGroupIndex, _playChannelIndex, changeSource: true);
  }

  /// 刷新当前频道 (对照 refreshChannel).
  /// 原版走 playChannel(..., true), 但唯一线路会被短路分支挡住而不重载,
  /// 这里直接 force 重载, 保证刷新按钮真的重新拉流.
  void _refreshChannel() {
    if (_currentChannel != null) {
      _playChannel(_playGroupIndex, _playChannelIndex, changeSource: true, force: true);
    }
  }

  void _clickLiveChannel(int position) {
    // 对照 clickLiveChannel: 取当前选中分组的第 position 个频道
    _playChannel(_selectedGroupIndex, position);
  }

  // ================= 自动换源 (对照 mConnectTimeoutChangeSourceRun) =================

  void _onTimeoutChangeSource() {
    final item = _currentChannel;
    if (item == null) return;
    // media_kit 单核, 对照时跳过原版 switchLivePlayerAndReplay 的多内核切换
    _changeSourceTimes++;
    if (item.sourceNum == _changeSourceTimes) {
      // 所有线路失败 → 组内下一个频道 (原版默认不跨组)
      _changeSourceTimes = 0;
      final (gi, ci) = _getNextChannel(1);
      _playChannel(gi, ci);
    } else {
      _playNextSource();
    }
  }

  /// 对照 getNextChannel (LIVE_CROSS_GROUP 默认 false: 组内循环).
  (int, int) _getNextChannel(int direction) {
    final channels = _channelsOf(_playGroupIndex);
    if (channels.isEmpty) return (-1, -1);
    var channelIndex = _playChannelIndex;
    if (direction > 0) {
      channelIndex++;
      if (channelIndex >= channels.length) channelIndex = 0;
    } else {
      channelIndex--;
      if (channelIndex < 0) channelIndex = channels.length - 1;
    }
    return (_playGroupIndex, channelIndex);
  }

  void _scheduleBufferTimeout() {
    _errorRetryTimer?.cancel();
    _bufferTimeoutTimer?.cancel();
    _bufferTimeoutTimer = Timer(
        const Duration(milliseconds: LiveStore.defaultTimeoutMs), _onTimeoutChangeSource);
  }

  void _scheduleErrorRetry() {
    _bufferTimeoutTimer?.cancel();
    _errorRetryTimer?.cancel();
    _errorRetryTimer = Timer(
        const Duration(milliseconds: LiveStore.errorRetryDelayMs), _onTimeoutChangeSource);
  }

  void _cancelTimers() {
    _bufferTimeoutTimer?.cancel();
    _errorRetryTimer?.cancel();
    _bufferTimeoutTimer = null;
    _errorRetryTimer = null;
  }

  void _bindStreams() {
    _subs.add(_player.stream.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
      if (p) {
        // 对照 STATE_PLAYING: 取消换源任务并重置失败计数
        _cancelTimers();
        _changeSourceTimes = 0;
      }
    }));
    _subs.add(_player.stream.buffering.listen((b) {
      if (!mounted) return;
      setState(() => _buffering = b);
      if (b) {
        // 对照 STATE_PREPARING/BUFFERING: 启动超时换源
        _scheduleBufferTimeout();
      } else {
        // 对照 STATE_BUFFERED: 取消超时任务 (计数只在播放成功时重置,
        // 出错时 buffering 也会变 false, 不能在此重置)
        _bufferTimeoutTimer?.cancel();
        _bufferTimeoutTimer = null;
      }
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (!mounted) return;
      debugPrint('[live] player error: $e');
      // 对照 STATE_ERROR: 3.5s 后换源
      _scheduleErrorRetry();
    }));
    _subs.add(_player.stream.completed.listen((done) {
      if (!mounted || !done) return;
      // 对照 STATE_PLAYBACK_COMPLETED: 直播流结束与错误同样处理
      _scheduleErrorRetry();
    }));
  }

  // ================= 分组/密码 (对照 selectChannelGroup / showPasswordDialog) =================

  void _selectChannelGroup(int groupIndex) {
    if (groupIndex < 0 || groupIndex >= _groups.length) return;
    // 已选中且无需密码 → 无操作
    if (groupIndex == _selectedGroupIndex && !_needPassword(groupIndex)) return;
    final previous = _selectedGroupIndex;
    _selectedGroupIndex = groupIndex;
    if (_needPassword(groupIndex)) {
      _showPasswordDialog(groupIndex);
      setState(() {});
      return;
    }
    // 对照 loadChannelGroupData: 换组重置频道高亮, 同组保留
    if (groupIndex != previous) _selectedChannelIndex = -1;
    setState(() {});
    _scrollIntoView();
  }

  void _showPasswordDialog(int groupIndex) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _PasswordDialog(
        onConfirm: (password) => _confirmPassword(ctx, groupIndex, password),
      ),
    );
  }

  void _confirmPassword(BuildContext ctx, int groupIndex, String password) {
    if (groupIndex < 0 || groupIndex >= _groups.length) return;
    if (password == _groups[groupIndex].groupPassword) {
      _passwordConfirmed.add(groupIndex);
      Navigator.pop(ctx);
      // 对照 loadChannelGroupDataAndPlay(groupIndex, -1): 只加载不播放
      _selectedGroupIndex = groupIndex;
      _selectedChannelIndex = -1;
      setState(() {});
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码错误')),
      );
    }
  }

  bool _needPassword(int groupIndex) {
    if (groupIndex < 0 || groupIndex >= _groups.length) return false;
    return _groups[groupIndex].groupPassword.isNotEmpty &&
        !_passwordConfirmed.contains(groupIndex);
  }

  /// 对照 getLiveChannels: 密码分组未确认时返回空列表.
  List<LiveChannelItem> _channelsOf(int groupIndex) {
    if (groupIndex < 0 || groupIndex >= _groups.length) return const [];
    if (_needPassword(groupIndex)) return const [];
    return _groups[groupIndex].channels;
  }

  LiveChannelItem? _channelAt(int groupIndex, int channelIndex) {
    final channels = _channelsOf(groupIndex);
    if (channelIndex < 0 || channelIndex >= channels.length) return null;
    return channels[channelIndex];
  }

  int _firstNoPasswordGroup() {
    for (final g in _groups) {
      if (g.groupPassword.isEmpty) return g.groupIndex;
    }
    return -1;
  }

  // ================= 浮层 / 角标 / 全屏 =================

  void _toggleOverlay() {
    if (_overlayVisible) {
      _hideOverlay();
    } else {
      setState(() => _overlayVisible = true);
      _scheduleHideOverlay();
    }
  }

  void _scheduleHideOverlay() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: _kOverlaySeconds), () {
      if (mounted && _overlayVisible) setState(() => _overlayVisible = false);
    });
  }

  void _hideOverlay() {
    _overlayTimer?.cancel();
    if (mounted && _overlayVisible) setState(() => _overlayVisible = false);
  }

  /// 对照 updateRightTopChannelInfo: 切台后短暂显示频道名 + 加载圈.
  void _showBadge(String name) {
    _badgeTimer?.cancel();
    _badgeName = name;
    _badgeVisible = true;
    _badgeTimer = Timer(const Duration(seconds: _kBadgeSeconds), () {
      if (mounted && _badgeVisible) setState(() => _badgeVisible = false);
    });
  }

  void _togglePlayPause() {
    if (_needManualPlay) {
      // 切走过 Tab 播放器已 stop: 必须重新 setUrl+play (对照 ivPlayPauseCenter)
      if (_currentChannel != null) {
        _playChannel(_playGroupIndex, _playChannelIndex);
      }
    } else if (_playing) {
      _player.pause();
    } else if (_currentChannel != null) {
      _player.play();
    }
    _scheduleHideOverlay();
  }

  Future<void> _enterFullscreen() async {
    if (_portraitFullscreen) return;
    setState(() => _portraitFullscreen = true);
    RootPage.liveFullscreen.value = true;
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
    _scheduleHideOverlay();
  }

  Future<void> _exitFullscreen() async {
    if (!_portraitFullscreen) return;
    _overlayTimer?.cancel();
    setState(() {
      _portraitFullscreen = false;
      _overlayVisible = false;
    });
    RootPage.liveFullscreen.value = false;
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
  }

  void _toggleFullscreen() {
    if (_portraitFullscreen) {
      _exitFullscreen();
    } else {
      _enterFullscreen();
    }
  }

  // ================= 切 Tab (对照 onFragmentPause) =================

  void _onTabChanged() {
    if (!mounted) return;
    if (RootPage.tabIndex.value == RootPage.liveTabIndex) return;
    // 用 stop 而非 pause: "准备中/缓冲中"时 pause 不生效, 加载完成会自动续播
    _cancelTimers();
    _needManualPlay = true;
    _player.stop();
    if (_portraitFullscreen) {
      _portraitFullscreen = false;
      RootPage.liveFullscreen.value = false;
      try {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (_) {}
    }
    setState(() {
      _playing = false;
      _buffering = false;
      _overlayVisible = false;
    });
  }

  // ================= 滚动定位 =================

  void _scrollIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisible(_groupKeys, _selectedGroupIndex);
      _ensureVisible(_channelKeys, _selectedChannelIndex);
      final srcIdx = _currentChannel?.sourceIndex ?? -1;
      if (srcIdx >= 0) _ensureVisible(_sourceKeys, srcIdx);
    });
  }

  void _ensureVisible(Map<int, GlobalKey> keys, int index) {
    if (index < 0) return;
    final ctx = keys[index]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        alignment: 0.5, duration: const Duration(milliseconds: 200));
  }

  // ================= 构建 =================

  String get _channelNameText {
    if (_noSource) return '未配置直播源';
    return _currentChannel?.channelName ?? '请选择频道';
  }

  @override
  Widget build(BuildContext context) {
    if (TvMode.isTV.value) return _buildTV();
    return _buildPhone();
  }

  // ---- 手机: 播放器(2) + 信息栏(52dp) + 三列列表(3), 对照 fragment_live.xml ----
  Widget _buildPhone() {
    if (_portraitFullscreen) {
      return PopScope(
        // 全屏时系统返回键 = 退出全屏 (对照原版 handleBack).
        // onPopInvokedWithResult 自 Flutter 3.24 (Dart 3.5) 起可用,
        // 与 pubspec sdk 下限 3.5.0 对应; 重复进入时 _exitFullscreen 幂等.
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _exitFullscreen();
        },
        child: ColoredBox(
          color: Colors.black,
          child: _buildPlayerArea(tv: false),
        ),
      );
    }
    return Column(
      children: [
        Expanded(flex: 2, child: _buildPlayerArea(tv: false)),
        _buildInfoBar(tv: false),
        Expanded(flex: 3, child: _buildBodyArea(tv: false)),
      ],
    );
  }

  // ---- TV: 播放器(72%) + 右侧面板(28%), 对照 layout-sw600dp/fragment_live.xml ----
  Widget _buildTV() {
    return Row(
      children: [
        Expanded(flex: 72, child: _buildPlayerArea(tv: true)),
        Expanded(
          flex: 28,
          child: Column(
            children: [
              _buildInfoBar(tv: true),
              Expanded(child: _buildBodyArea(tv: true)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlayerArea({required bool tv}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (_videoMounted) _buildVideoTap() else _buildPlayerPlaceholder(),
        if (_buffering && !_playing)
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        if (_badgeVisible)
          Positioned(top: 6, right: 6, child: _buildBadge(tv: tv)),
        if (tv) _buildTvControlBar() else _buildOverlay(),
      ],
    );
  }

  Widget _buildPlayerPlaceholder() {
    if (_noSource) return _buildNoSourceHint();
    if (_error.isNotEmpty && _groups.isEmpty) return _buildErrorHint();
    return const SizedBox.shrink();
  }

  Widget _buildVideoTap() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: TvMode.isTV.value ? null : _toggleOverlay,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: Video(controller: _controller, fit: BoxFit.contain),
    );
  }

  /// 对照 LiveController.onFling: 左滑上一源, 右滑下一源.
  void _onHorizontalDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < 120) return;
    if (v > 0) {
      _playNextSourceManual();
    } else {
      _playPreSourceManual();
    }
  }

  void _playPreSourceManual() {
    if (!_isCurrentLiveChannelValid()) return;
    _playPreSource();
  }

  void _playNextSourceManual() {
    if (!_isCurrentLiveChannelValid()) return;
    _playNextSource();
  }

  bool _isCurrentLiveChannelValid() {
    if (_currentChannel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择频道')),
      );
      return false;
    }
    return true;
  }

  Widget _buildNoSourceHint() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.live_tv_outlined, size: 48, color: Colors.white38),
          const SizedBox(height: 12),
          const Text('未配置直播源',
              style: TextStyle(fontSize: 16, color: Colors.white70)),
          const SizedBox(height: 4),
          const Text('请先到【设置 → 直播】中配置直播源地址',
              style: TextStyle(fontSize: 12, color: Colors.white38)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () =>
                RootPage.tabIndex.value = RootPage.settingsTabIndex,
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorHint() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.white38),
            const SizedBox(height: 12),
            Text(
              _error.isEmpty ? '直播列表为空' : _error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _loadLives, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge({required bool tv}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _kBadgeBg,
        borderRadius: BorderRadius.circular(20), // shape_user_search: 胶囊
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_badgeName,
              style: TextStyle(
                  fontSize: tv ? 13 : 12, color: const Color(0xFFFCFFFF))),
          const SizedBox(width: 6),
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBar({required bool tv}) {
    return Container(
      height: 52,
      padding: EdgeInsets.only(left: tv ? 14 : 16, right: 8),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(
            child: Text(
              _channelNameText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: tv ? 16 : 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBodyArea({required bool tv}) {
    if (_noSource) return const SizedBox.shrink();
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_groups.isEmpty) return _buildErrorHint();
    return _buildChannelArea(tv: tv);
  }

  Widget _buildChannelArea({required bool tv}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 原版权重: 手机 1 : 1.5 : 1, TV(sw600dp) 0.5 : 0.8 : 0.5
        Expanded(flex: tv ? 5 : 2, child: _buildGroupList(tv: tv)),
        Expanded(flex: tv ? 8 : 3, child: _buildChannelList(tv: tv)),
        Expanded(flex: tv ? 5 : 2, child: _buildSourceList(tv: tv)),
      ],
    );
  }

  Widget _buildGroupList({required bool tv}) {
    return ListView.builder(
      padding: const EdgeInsets.all(4),
      itemCount: _groups.length,
      itemBuilder: (_, i) {
        final key = _groupKeys.putIfAbsent(i, () => GlobalKey());
        return KeyedSubtree(
          key: key,
          child: _LiveListItem(
            text: _groups[i].groupName,
            selected: i == _selectedGroupIndex,
            large: tv,
            onTap: () => _selectChannelGroup(i),
          ),
        );
      },
    );
  }

  Widget _buildChannelList({required bool tv}) {
    final channels = _channelsOf(_selectedGroupIndex);
    return ListView.builder(
      padding: const EdgeInsets.all(4),
      itemCount: channels.length,
      itemBuilder: (_, i) {
        final key = _channelKeys.putIfAbsent(i, () => GlobalKey());
        return KeyedSubtree(
          key: key,
          child: _LiveListItem(
            num: '${channels[i].channelNum}',
            text: channels[i].channelName,
            selected: i == _selectedChannelIndex,
            large: tv,
            onTap: () => _clickLiveChannel(i),
          ),
        );
      },
    );
  }

  Widget _buildSourceList({required bool tv}) {
    // 源列表只在有播放频道时填充 (对照 updateMobileSourceList)
    final item = _currentChannel;
    if (item == null) return const SizedBox.shrink();
    return ListView.builder(
      padding: const EdgeInsets.all(4),
      itemCount: item.sourceNum,
      itemBuilder: (_, i) {
        final key = _sourceKeys.putIfAbsent(i, () => GlobalKey());
        return KeyedSubtree(
          key: key,
          child: _LiveListItem(
            text: item.channelSourceNames[i],
            selected: i == item.sourceIndex,
            large: tv,
            onTap: () => _playChannelBySource(i),
          ),
        );
      },
    );
  }

  // ---- 手机控制浮层 (对照 live_control_overlay) ----
  Widget _buildOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_overlayVisible,
        child: AnimatedOpacity(
          opacity: _overlayVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Stack(
            children: [
              // 返回键仅全屏时显示 (对照 showControlOverlay)
              if (_portraitFullscreen)
                Positioned(
                  top: 8,
                  left: 8,
                  child: _overlayButton(
                      icon: Icons.arrow_back, onTap: _exitFullscreen),
                ),
              Center(
                child: _overlayButton(
                  icon: _playing ? Icons.pause : Icons.play_arrow,
                  size: 56,
                  onTap: _togglePlayPause,
                ),
              ),
              Positioned(
                bottom: 8,
                left: 8,
                child: _overlayButton(icon: Icons.refresh, onTap: _refreshChannel),
              ),
              Positioned(
                bottom: 8,
                right: 8,
                child: _overlayButton(
                  icon: _portraitFullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  onTap: _toggleFullscreen,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overlayButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 40,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0x66000000),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: size * 0.5, color: Colors.white),
      ),
    );
  }

  // ---- TV 底部常驻控制条 (遥控器可聚焦) ----
  Widget _buildTvControlBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: const Color(0x99000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TvButton(
              label: _playing ? '暂停' : '播放',
              icon: _playing ? Icons.pause : Icons.play_arrow,
              height: 40,
              fontSize: 15,
              onTap: _togglePlayPause,
            ),
            const SizedBox(width: 12),
            TvButton(
              label: '刷新',
              icon: Icons.refresh,
              height: 40,
              fontSize: 15,
              onTap: _refreshChannel,
            ),
            const SizedBox(width: 12),
            TvButton(
              label: '上一源',
              icon: Icons.skip_previous,
              height: 40,
              fontSize: 15,
              onTap: _playPreSourceManual,
            ),
            const SizedBox(width: 12),
            TvButton(
              label: '下一源',
              icon: Icons.skip_next,
              height: 40,
              fontSize: 15,
              onTap: _playNextSourceManual,
            ),
          ],
        ),
      ),
    );
  }
}

/// 分组密码对话框 (对照 LivePasswordDialog).
class _PasswordDialog extends StatefulWidget {
  final ValueChanged<String> onConfirm;

  const _PasswordDialog({required this.onConfirm});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('分组密码'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(labelText: '请输入密码'),
        onSubmitted: widget.onConfirm,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => widget.onConfirm(_ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 直播列表项 (对照 item_live_channel / item_live_channel_group +
/// shape_live_focus + LiveChannelItemAdapter 配色).
class _LiveListItem extends StatefulWidget {
  final String text;
  final String? num;
  final bool selected;
  final bool large; // TV 大字号
  final VoidCallback onTap;

  const _LiveListItem({
    required this.text,
    this.num,
    required this.selected,
    required this.onTap,
    this.large = false,
  });

  @override
  State<_LiveListItem> createState() => _LiveListItemState();
}

class _LiveListItemState extends State<_LiveListItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // 焦点 = #1890FF 实底 (黑字); 选中 = #331890FF 底 + #1890FF 1dp 描边 (#1890FF 字);
    // 常规 = 透明底. 原版常规是黑字 (直播页浅色底), 本工程暗色主题故用白字.
    final Color? bg =
        _focused ? _kBlue : (widget.selected ? _kSelectedBg : null);
    final Color borderColor =
        (_focused || !widget.selected) ? Colors.transparent : _kBlue;
    final Color textColor =
        _focused ? Colors.black : (widget.selected ? _kBlue : Colors.white);

    return TvFocusable(
      onTap: widget.onTap,
      onFocusChange: (v) => setState(() => _focused = v),
      focusScale: 1.0, // 原版焦点无缩放
      focusBackground: false, // 自绘焦点底色
      glowColor: Colors.transparent, // 原版焦点无光晕
      radius: 6,
      focusMargin: 2,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: widget.large ? 10 : 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: borderColor, width: widget.selected ? 1 : 0),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.num != null) ...[
              Text(widget.num!,
                  style: TextStyle(
                      fontSize: widget.large ? 14 : 11, color: textColor)),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                widget.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: widget.large ? 17 : 13, color: textColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
