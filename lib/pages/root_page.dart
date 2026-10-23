import 'package:flutter/material.dart';

import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';
import 'favorites_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'live_page.dart';
import 'settings_page.dart';

/// 应用外壳: 手机 = 底部导航 (原布局); TV = 左侧导航栏 + 大字号
/// (对照原版 NovaTV 首页结构: 顶部图标栏 + 分类行 + 内容区, 焦点上下移动).
class RootPage extends StatefulWidget {
  const RootPage({super.key});

  /// 当前页签索引. 直播页监听它: 离开直播 tab 时停止播放
  /// (对照原版 LiveFragment.onFragmentPause: 切走时释放播放器).
  /// 直播页内也可反向写它跳转到设置页 (配置直播源).
  static final ValueNotifier<int> tabIndex = ValueNotifier<int>(0);

  /// 直播页手机端全屏状态: true 时隐藏 AppBar 与底部导航,
  /// 配合 SystemUiMode.immersiveSticky 实现真全屏 (对照原版
  /// LiveActivity 全屏直播).
  static final ValueNotifier<bool> liveFullscreen = ValueNotifier<bool>(false);

  /// 页签索引常量 (直播页监听 / 跳转用).
  static const int liveTabIndex = 1;
  static const int settingsTabIndex = 4;

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _tab = 0;

  /// 页面栈用 GlobalKey: TV 直播全屏时外壳 (导航栏/标题栏) 被收起, 页面栈换了父节点,
  /// 没有 GlobalKey 的话 State 会被重建 → 直播页 dispose → 播放中断.
  final GlobalKey _stackKey = GlobalKey(debugLabel: 'root-page-stack');

  /// 上一次是否处于全屏: 刚退出全屏时导航栏重建, 它的 autofocus 会抢走直播页刚还回的焦点.
  bool _wasFullscreen = false;

  static const _titles = ['首页', '直播', '收藏', '历史', '设置'];

  static const _destinations = [
    (Icons.home_outlined, Icons.home, '首页'),
    (Icons.live_tv_outlined, Icons.live_tv, '直播'),
    (Icons.favorite_border_outlined, Icons.favorite, '收藏'),
    (Icons.history, Icons.history, '历史'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  void initState() {
    super.initState();
    // 与全局 tabIndex 同步 (直播页可能反向跳转改它).
    _tab = RootPage.tabIndex.value;
    RootPage.tabIndex.addListener(_onTabIndexChanged);
  }

  @override
  void dispose() {
    RootPage.tabIndex.removeListener(_onTabIndexChanged);
    super.dispose();
  }

  /// 外部 (直播页跳设置/返回) 改写 tabIndex 时同步本地页签.
  void _onTabIndexChanged() {
    if (!mounted) return;
    final i = RootPage.tabIndex.value;
    if (i == _tab) return;
    setState(() => _tab = i);
  }

  void _select(int i) {
    setState(() => _tab = i);
    RootPage.tabIndex.value = i;
  }

  @override
  Widget build(BuildContext context) {
    const pages = [
      HomePage(),
      LivePage(),
      FavoritesPage(),
      HistoryPage(),
      SettingsPage(),
    ];
    if (!TvMode.isTV.value) {
      // ---------------- 手机: 原底部导航布局 ----------------
      // 直播全屏时隐藏 AppBar / 底部导航 (对照原版全屏直播).
      return ValueListenableBuilder<bool>(
        valueListenable: RootPage.liveFullscreen,
        builder: (ctx, fullscreen, _) => Scaffold(
          appBar: fullscreen ? null : AppBar(title: Text(_titles[_tab])),
          body: IndexedStack(index: _tab, children: pages),
          bottomNavigationBar: fullscreen
              ? null
              : NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: _select,
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
                    NavigationDestination(icon: Icon(Icons.live_tv_outlined), selectedIcon: Icon(Icons.live_tv), label: '直播'),
                    NavigationDestination(icon: Icon(Icons.favorite_border_outlined), selectedIcon: Icon(Icons.favorite), label: '收藏'),
                    NavigationDestination(icon: Icon(Icons.history), selectedIcon: Icon(Icons.history), label: '历史'),
                    NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
                  ],
                ),
        ),
      );
    }
    // ---------------- TV: 左侧导航栏 (遥控器上下移动焦点) ----------------
    // 关键点:
    // 1. IndexedStack 里 5 个页面同时挂载, 不可见页面的控件仍在焦点树里, 方向键会"跳进看不见的
    //    页面"或被其 autofocus 抢走焦点 → 用 ExcludeFocus 把非当前页整体排除出焦点遍历.
    // 2. 导航项自己是可聚焦控件 (旧实现用 NavigationRail 外包一个空 Focus, 初始焦点落在空壳上).
    final stack = IndexedStack(
      key: _stackKey,
      index: _tab,
      children: [
        for (var i = 0; i < pages.length; i++)
          ExcludeFocus(excluding: i != _tab, child: pages[i]),
      ],
    );
    return ValueListenableBuilder<bool>(
      valueListenable: RootPage.liveFullscreen,
      builder: (ctx, fullscreen, _) {
        // TV 全屏 (直播): 收起导航栏与标题栏, 页面铺满整屏.
        if (fullscreen) {
          _wasFullscreen = true;
          return Scaffold(backgroundColor: Colors.black, body: stack);
        }
        final railAutofocus = !_wasFullscreen;
        _wasFullscreen = false;
        return Scaffold(
          body: Row(
            children: [
              _tvRail(ctx, autofocus: railAutofocus),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    // TV 无 AppBar: 用一行大号标题代替 (10-foot UI).
                    Container(
                      height: 52,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.only(left: 20),
                      child: Text(
                        _titles[_tab],
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(child: stack),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// TV 左侧导航: 每项是 [TvFocusable]; OK 键切换页签, 向右键进入内容区.
  Widget _tvRail(BuildContext context, {required bool autofocus}) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 112,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.movie_filter_rounded, size: 34, color: primary),
                const SizedBox(height: 4),
                const Text('NovaBox', style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          for (var i = 0; i < _destinations.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: TvFocusable(
                // 初始焦点落在当前选中的导航项上
                autofocus: autofocus && i == _tab,
                radius: 14,
                onTap: () => _select(i),
                child: Container(
                  height: 72,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: i == _tab ? primary.withValues(alpha: 0.28) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        i == _tab ? _destinations[i].$2 : _destinations[i].$1,
                        size: 28,
                        color: i == _tab ? Colors.white : Colors.white70,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _destinations[i].$3,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: i == _tab ? FontWeight.bold : FontWeight.normal,
                          color: i == _tab ? Colors.white : Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
