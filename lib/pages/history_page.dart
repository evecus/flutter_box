import 'package:flutter/material.dart';

import '../data/history.dart';
import 'detail_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<HistoryItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await History.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String _tsText(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final d = now.difference(dt);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes}分钟前';
    if (d.inDays < 1) return '${d.inHours}小时前';
    if (d.inDays < 30) return '${d.inDays}天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  void _openItem(HistoryItem item) {
    final site = History.siteOf(item.siteKey);
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(child: Text('暂无观看记录'));
    }
    return Scaffold(
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final item = _items[i];
          final progress = item.dur > 0 ? (item.pos / item.dur).clamp(0.0, 1.0) : 0.0;
          return ListTile(
            leading: SizedBox(
              width: 72,
              child: item.cover.isEmpty
                  ? const Icon(Icons.movie_outlined)
                  : Image.network(
                      item.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 72, height: 46),
                    ),
            ),
            title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${item.siteName} · ${item.ep.isEmpty ? '播放' : item.ep}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: progress > 0.01 ? progress : null,
                        minHeight: 3,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_tsText(item.ts),
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () async {
                await History.remove(item.siteKey, item.vodId);
                _reload();
              },
            ),
            onTap: () => _openItem(item),
          );
        },
      ),
    );
  }
}
