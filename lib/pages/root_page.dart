import 'package:flutter/material.dart';

import 'favorites_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'settings_page.dart';

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _tab = 0;

  static const _titles = ['首页', '收藏', '历史', '设置'];

  @override
  Widget build(BuildContext context) {
    final pages = const [
      HomePage(),
      FavoritesPage(),
      HistoryPage(),
      SettingsPage(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
      ),
      body: IndexedStack(
        index: _tab,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
          NavigationDestination(icon: Icon(Icons.favorite_border_outlined), selectedIcon: Icon(Icons.favorite), label: '收藏'),
          NavigationDestination(icon: Icon(Icons.history), selectedIcon: Icon(Icons.history), label: '历史'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
