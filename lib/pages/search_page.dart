import 'package:flutter/material.dart';

import '../config/config.dart';
import '../data/douban_hot.dart' show picUrlAndHeaders;
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

  /// 左侧选中的源; null = 全部 (对照原版搜索页左侧源站列表).
  Site? _filter;
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
      _filter = null;
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

  /// 精确匹配优先: 若某源中结果名 == 搜索词则排前; 选中某个源时只看该源.
  List<MapEntry<Site, VodItem>> _flatten() {
    final hits = <MapEntry<Site, VodItem>>[];
    final rest = <MapEntry<Site, VodItem>>[];
    for (final entry in _results.entries) {
      if (_filter != null && entry.key != _filter) continue;
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 40,
          decoration: BoxDecoration(
            border: Border.all(color: scheme.onSurface, width: 1.2),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: TextField(
            controller: _ctrl,
            autofocus: widget.initialQuery.isEmpty,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: '搜索影片 / 演员 / 关键词',
              border: InputBorder.none,
              isCollapsed: true,
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: () => _search()),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_query.isEmpty && !_running) {
      return Center(
        child: Text('输入关键词, 将并行搜索全部 ${_sites.length} 个源', textAlign: TextAlign.center),
      );
    }
    final flat = _flatten();
    final progress = _running
        ? LinearProgressIndicator(
            value: _sites.isNotEmpty ? _done / _sites.length : null, minHeight: 3)
        : const SizedBox(height: 3);
    if (_results.isEmpty) {
      return Column(
        children: [
          progress,
          Expanded(child: Center(child: Text(_running ? '正在搜索 ("$_query") ...' : '没有搜索结果'))),
        ],
      );
    }
    return Column(
      children: [
        progress,
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 118, child: _siteList()),
              Expanded(child: _resultList(flat)),
            ],
          ),
        ),
      ],
    );
  }

  /// 左侧: "全部" + 有结果的源 (按到达顺序), 对照原版 SearchActivity 的源站列表.
  Widget _siteList() {
    final entries = _results.entries.where((e) => e.value.isNotEmpty).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 4, 4, 12),
      children: [
        _siteTile('全部', _filter == null, () => setState(() => _filter = null)),
        for (final e in entries)
          _siteTile(e.key.name, _filter == e.key, () => setState(() => _filter = e.key)),
      ],
    );
  }

  Widget _siteTile(String name, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  /// 右侧: 封面 + 片名 + 源站蓝标 + 备注.
  Widget _resultList(List<MapEntry<Site, VodItem>> flat) {
    if (flat.isEmpty) {
      return Center(child: Text(_running ? '正在搜索 ...' : '没有搜索结果'));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 12),
      itemCount: flat.length,
      itemBuilder: (ctx, i) => _row(flat[i]),
    );
  }

  Widget _row(MapEntry<Site, VodItem> entry) {
    final site = entry.key;
    final item = entry.value;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DetailPage(site: site, vodId: item.id, vodName: item.name),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(width: 92, height: 124, child: _cover(item)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(site.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.onPrimary)),
                  ),
                  if (item.remark != null && item.remark!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(item.remark!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: Colors.grey)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(VodItem item) {
    final placeholder = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.movie_outlined, color: Colors.grey)),
    );
    if (item.cover.isEmpty) return placeholder;
    final (url, headers) = picUrlAndHeaders(item.cover);
    return Image.network(
      url,
      fit: BoxFit.cover,
      headers: headers.isEmpty ? null : headers,
      errorBuilder: (_, __, ___) => placeholder,
      loadingBuilder: (ctx, child, progress) => progress == null ? child : placeholder,
    );
  }
}
