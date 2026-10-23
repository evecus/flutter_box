import 'package:flutter/material.dart';

import '../config/config.dart';
import '../data/spider_data.dart';
import 'detail_page.dart';

/// M3: 全站搜索 - 并行搜索已加载的所有源, 结果流式呈现.
class SearchPage extends StatefulWidget {
  final Site? initialSite;

  /// 预置搜索词 (豆瓣热播等无 vod_id 的条目点击时带入, 对照原版 jumpSearch).
  final String initialQuery;

  const SearchPage({super.key, this.initialSite, this.initialQuery = ''});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();
  late final List<Site> _sites;
  final Map<Site, List<VodItem>> _results = {};
  String _query = '';
  int _done = 0;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _sites = Config.loaded?.sites.where((s) => s.isRealSource).toList() ?? const [];
    if (widget.initialQuery.isNotEmpty) {
      _ctrl.text = widget.initialQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(widget.initialQuery));
    }
  }

  Future<void> _search([String? preset]) async {
    final q = (preset ?? _ctrl.text).trim();
    if (q.isEmpty || _running) {
      if (q.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入搜索词')));
      }
      return;
    }
    setState(() {
      _query = q;
      _running = true;
      _done = 0;
      _results.clear();
    });
    await _searchAll(q);
  }

  Future<void> _searchAll(String q) async {
    // 并行搜索, 单个源失败不影响整体.
    await Future.wait(_sites.map((site) async {
      try {
        final json = await SpiderData.search(site.key, q, '1');
        final list = vodList(json['list']);
        if (!mounted) return;
        // 过滤明显不相关的无效 entry (空名已过滤), 最多保留20个.
        setState(() {
          _results[site] = list.take(20).toList();
          _done++;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _done++);
      }
    }));
    if (!mounted) return;
    setState(() => _running = false);
  }

  /// 精确匹配优先: 若某源中结果名 == 搜索词则排前.
  List<MapEntry<Site, VodItem>> _flatten() {
    final hits = <MapEntry<Site, VodItem>>[];
    final rest = <MapEntry<Site, VodItem>>[];
    for (final entry in _results.entries) {
      for (final vod in entry.value) {
        if (vod.name == _query) {
          hits.add(MapEntry(entry.key, vod));
        } else {
          rest.add(MapEntry(entry.key, vod));
        }
      }
    }
    return [...hits, ...rest];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索影片 / 演员 / 关键词',
            border: InputBorder.none,
            suffixIcon: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _ctrl.clear();
                setState(() {
                  _results.clear();
                  _query = '';
                });
              },
            ),
          ),
          onSubmitted: (_) => _search(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _search(),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final flat = _flatten();
    if (_running) {
      final totalSites = _sites.length;
      return Column(
        children: [
          LinearProgressIndicator(value: totalSites > 0 ? _done / totalSites : null, minHeight: 3),
          Expanded(
            child: flat.isEmpty
                ? Center(child: Text('正在搜索 ("$_query") ...'))
                : _resultGrid(flat),
          ),
        ],
      );
    }
    if (_query.isEmpty) {
      return Center(
        child: Text(
          '输入关键词, 将并行搜索全部 ${_sites.length} 个源',
          textAlign: TextAlign.center,
        ),
      );
    }
    if (flat.isEmpty) {
      return const Center(child: Text('没有搜索结果'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '共 ${flat.length} 条来自 ${_results.length} 个源',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(child: _resultGrid(flat)),
      ],
    );
  }

  Widget _resultGrid(List<MapEntry<Site, VodItem>> flat) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        childAspectRatio: 0.58,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: flat.length,
      itemBuilder: (ctx, i) => _card(flat[i]),
    );
  }

  Widget _card(MapEntry<Site, VodItem> entry) {
    final site = entry.key;
    final item = entry.value;
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DetailPage(site: site, vodId: item.id, vodName: item.name),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
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
                            loadingBuilder: (ctx, child, progress) {
                              if (progress == null) return child;
                              return const Center(
                                  child: CircularProgressIndicator(strokeWidth: 2));
                            },
                          ),
                  ),
                ),
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      site.name,
                      style: const TextStyle(fontSize: 9, color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          if (item.remark != null && item.remark!.isNotEmpty)
            Text(item.remark!, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}
