import 'package:flutter/material.dart';

import '../tv/tv_mode.dart';
import 'favorites_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'settings_page.dart';

/// 应用外壳: 手机 = 底部导航 (原布局); TV = 左侧导航栏 + 大字号
/// (对照原版 NovaTV 首页结构: 顶部图标栏 + 分类行 + 内容区, 焦点上下移动).
class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _tab = 0;

  static const _titles = ['首页', '收藏', '历史', '设置'];

  static const _destinations = [
    (Icons.home_outlined, Icons.home, '首页'),
    (Icons.favorite_border_outlined, Icons.favorite, '收藏'),
    (Icons.history, Icons.history, '历史'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  void _select(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    final pages = const [
      HomePage(),
      FavoritesPage(),
      HistoryPage(),
      SettingsPage(),
    ];
    if (!TvMode.isTV.value) {
      // ---------------- 手机: 原底部导航布局 ----------------
      return Scaffold(
        appBar: AppBar(title: Text(_titles[_tab])),
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _select,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
            NavigationDestination(icon: Icon(Icons.favorite_border_outlined), selectedIcon: Icon(Icons.favorite), label: '收藏'),
            NavigationDestination(icon: Icon(Icons.history), selectedIcon: Icon(Icons.history), label: '历史'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
          ],
        ),
      );
    }
    // ---------------- TV: 左侧导航栏 (遥控器上下移动焦点) ----------------
    return Scaffold(
      body: Row(
        children: [
          // 初始焦点落在导航栏上: 按右键进入内容区, 上下键切换页签
          // (对照原版 HomeActivity 顶部图标栏作为默认焦点).
          Focus(
            canRequestFocus: true,
            autofocus: true,
            child: NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              groupAlignment: -0.85,
              leading: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.movie_filter_rounded,
                        size: 34, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 4),
                    const Text('NovaBox',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.$1, size: 28),
                    selectedIcon: Icon(d.$2, size: 28),
                    label: Text(d.$3, style: const TextStyle(fontSize: 15)),
                  ),
              ],
            ),
          ),
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
                Expanded(child: IndexedStack(index: _tab, children: pages)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
