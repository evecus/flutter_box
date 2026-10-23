import 'package:flutter/material.dart';

import '../config/config.dart';
import '../data/spider_data.dart';
import 'detail_page.dart';

class BrowsePage extends StatefulWidget {
  final Site site;
  final String initialTid;

  const BrowsePage({super.key, required this.site, this.initialTid = ''});

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  final _controller = ScrollController();

  List<Map<String, dynamic>> _classes = [];
  List<VodItem> _items = [];
  String _tid = '';
  String _page = '1';
  bool _loading = false;
  bool _searchMode = false;
  bool _homeFetched = false;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tid = widget.initialTid;
    _bootstrapClasses();
    _reload();
  }

  Future<void> _bootstrapClasses() async {
    if (_homeFetched) return;
    try {
      final json = await SpiderData.home(widget.site.key, true);
      final classes = classList(json['class']);
      _homeFetched = classes.isNotEmpty;
      if (mounted && classes.isNotEmpty) {
        setState(() => _classes = classes);
      }
    } catch (_) {}
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      if (_searchMode) {
        final json = await SpiderData.search(widget.site.key, _searchCtrl.text.trim(), _page);
        final next = vodList(json['list']);
        setState(() {
          _items = _page == '1' ? next : [..._items, ...next];
        });
      } else if (_tid.isEmpty) {
        final json = await SpiderData.home(widget.site.key, true);
        final next = vodList(json['list']);
        _homeFetched = true;
        setState(() {
          if (classList(json['class']).isNotEmpty) _classes = classList(json['class']);
          _items = next;
        });
      } else {
        final json = await SpiderData.category(widget.site.key, _tid, _page, {});
        final next = vodList(json['list']);
        setState(() {
          _items = _page == '1' ? next : [..._items, ...next];
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setClass(String tid) {
    setState(() {
      _tid = tid;
      _page = '1';
      _items = [];
    });
    _reload();
  }

  void _nextPage() {
    setState(() => _page = '${(int.tryParse(_page) ?? 1) + 1}');
    _controller.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searchMode
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: '搜索...', border: InputBorder.none),
                onSubmitted: (_) => _reload(),
              )
            : Text(widget.site.name),
        leading: BackButton(onPressed: () {
          if (_searchMode) {
            setState(() {
              _searchMode = false;
              _items = [];
              _tid = '';
              _page = '1';
            });
            _reload();
          } else {
            Navigator.of(context).pop();
          }
        }),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              setState(() {
                _searchMode = true;
                _items = [];
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_classes.isNotEmpty && !_searchMode)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _classChip('', '首页'),
                  ..._classes.map((m) => _classChip(
                        m['type_id'].toString(),
                        m['type_name']?.toString() ?? '',
                      )),
                ],
              ),
            ),
          Expanded(
            child: _loading && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(child: Text(_searchMode ? '输入关键字回车搜索' : '暂无数据'))
                    : GridView.builder(
                        controller: _controller,
                        padding: const EdgeInsets.all(8),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 130,
                          childAspectRatio: 0.62,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: _items.length,
                        itemBuilder: (ctx, i) => _gridItem(_items[i]),
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  if (_loading)
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const Spacer(),
                  TextButton(onPressed: _loading ? null : _nextPage, child: const Text('更多 (下一页)')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _classChip(String tid, String name) {
    final selected = _tid == tid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: ChoiceChip(
        label: Text(name),
        selected: selected,
        onSelected: (_) => _setClass(tid),
      ),
    );
  }

  Widget _gridItem(VodItem item) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DetailPage(site: widget.site, vodId: item.id, vodName: item.name),
          ),
        );
      },
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
                child: _cover(item),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          if (item.remark != null && item.remark!.isNotEmpty)
            Text(item.remark!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _cover(VodItem item) {
    if (item.cover.isEmpty) {
      return const Center(child: Icon(Icons.movie_outlined));
    }
    return Image.network(
      item.cover,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined)),
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      },
    );
  }
}
