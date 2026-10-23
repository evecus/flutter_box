import 'package:flutter/material.dart';

import '../data/favorites.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';
import 'detail_page.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  List<FavoriteItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await Favorites.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _openItem(FavoriteItem item) {
    final site = Favorites.siteOf(item.siteKey);
    if (site == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${item.siteName}未加载, 请先应用配置')),
      );
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => DetailPage(site: site, vodId: item.vodId, vodName: item.name),
        ))
        .then((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
    final tv = TvMode.isTV.value;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(child: Text('暂无收藏'));
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: GridView.builder(
        padding: EdgeInsets.all(tv ? 16 : 8),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: tv ? 240 : 130,
          childAspectRatio: tv ? 0.68 : 0.62,
          mainAxisSpacing: tv ? 16 : 8,
          crossAxisSpacing: tv ? 16 : 8,
        ),
        itemCount: _items.length,
        itemBuilder: (ctx, i) {
          final item = _items[i];
          return TvFocusable(
            onTap: () => _openItem(item),
            onLongPress: () async {
              await Favorites.remove(item.siteKey, item.vodId);
              _reload();
            },
            radius: 8,
            focusMargin: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: item.cover.isEmpty
                          ? const Center(child: Icon(Icons.movie_outlined))
                          : Image.network(
                              item.cover,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              errorBuilder: (_, __, ___) =>
                                  const Center(child: Icon(Icons.broken_image_outlined)),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: tv ? 16 : 12)),
                Text(item.siteName, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: tv ? 14 : 10, color: Colors.grey)),
              ],
            ),
          );
        },
      ),
    );
  }
}
