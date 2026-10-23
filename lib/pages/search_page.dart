import 'package:flutter/material.dart';

import '../config/config.dart';
import '../data/douban_hot.dart' show DoubanHot, picUrlAndHeaders;
import '../data/spider_data.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';
import 'detail_page.dart';

/// 全站搜索.
///
/// 手机 (原布局): 顶栏输入框 + 搜索按钮 + 源筛选 + 结果列表;
/// 空状态给出热词 (豆瓣热播片名) 快捷入口.
///
/// TV (对照原版 NovaTV SearchActivity / layout/activity_search.xml):
///   左栏 = 指定搜索源按钮 + 输入框 + 搜索/清空按钮 + 屏显键盘
///          (远程搜索/删除 + A-Z + 0-9, 全部可被遥控器移动焦点);
///   中栏 = 热词列表 (可聚焦, 选中即搜);
///   右栏 = 源筛选 + 结果列表.
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
  final _inputFocus = FocusNode();
  late final List<Site> _sites;
  final Map<Site, List<VodItem>> _results = {};
  String _query = '';
  int _done = 0;

  /// 左侧选中的源; null = 全部 (对照原版搜索页左侧源站列表).
  Site? _filter;

  /// 搜索前指定的源 (对照原版 tvSearchCheckboxBtn "指定搜索源");
  /// null = 并行搜索全部源.
  Site? _searchSite;

  bool _running = false;

  /// 搜索完成后把焦点移到第一条结果 (TV 遥控器流程).
  bool _focusFirstResult = false;

  bool _inputFocused = false;

  List<String> _hotWords = const [];
  bool _hotLoading = true;

  /// 屏显键盘 (对照原版 SearchKeyboard: 远程搜索/删除 各占半行 + A-Z + 0-9).
  static final List<String> _keyboardKeys = <String>[
    '远程搜索',
    '删除',
    ...List.generate(26, (i) => String.fromCharCode(65 + i)),
    ...List.generate(10, (i) => '$i'),
  ];

  @override
  void initState() {
    super.initState();
    _sites = Config.loaded?.sites.where((s) => s.isRealSource).toList() ?? const [];
    _inputFocus.addListener(() {
      if (mounted && _inputFocused != _inputFocus.hasFocus) {
        setState(() => _inputFocused = _inputFocus.hasFocus);
      }
    });
    if (widget.initialQuery.isNotEmpty) {
      _ctrl.text = widget.initialQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(widget.initialQuery));
    }
    _loadHotWords();
    // TV: 无软键盘, 输入框自动获焦, 遥控器下键即可移到键盘按键.
    if (TvMode.isTV.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _inputFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _loadHotWords() async {
    // 热词 = 豆瓣热播片名 (按天缓存, 首页复用同一缓存).
    final hot = await DoubanHot.fetch();
    if (!mounted) return;
    setState(() {
      _hotWords = hot.map((e) => e.name).where((n) => n.isNotEmpty).take(20).toList();
      _hotLoading = false;
    });
  }

  Future<void> _search([String? preset]) async {
    final q = (preset ?? _ctrl.text).trim();
    if (q.isEmpty || _running) {
      if (q.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入搜索词')));
      }
      return;
    }
    // 收起软键盘 (手机), 避免遮挡结果.
    FocusScope.of(context).unfocus();
    setState(() {
      _query = q;
      _running = true;
      _done = 0;
      _filter = null;
      _results.clear();
      _focusFirstResult = false;
    });
    await _searchAll(q);
  }

  Future<void> _searchAll(String q) async {
    // 并行搜索, 单个源失败不影响整体.
    final targets = _searchSite == null ? _sites : <Site>[_searchSite!];
    await Future.wait(targets.map((site) async {
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
    setState(() {
      _running = false;
      if (TvMode.isTV.value && _results.values.any((v) => v.isNotEmpty)) {
        _focusFirstResult = true;
      }
    });
    if (_focusFirstResult) {
      // autofocus 只在本帧生效, 下一帧清零防止后续重建抢焦点.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _focusFirstResult = false);
      });
    }
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

  // ---------------------------------------------------------------- 布局入口

  @override
  Widget build(BuildContext context) {
    if (!TvMode.isTV.value) return _mobileScaffold();
    return _tvScaffold();
  }

  /// 手机: 原布局 (顶栏输入 + 搜索按钮).
  Widget _mobileScaffold() {
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

  /// TV: 三栏 (键盘 / 热词 / 结果), 全屏无底部导航.
  Widget _tvScaffold() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索', style: TextStyle(fontSize: 20)),
        leading: const BackButton(),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 430, child: _tvLeftPanel()),
          const VerticalDivider(width: 1),
          SizedBox(width: 240, child: _hotWordPanel()),
          const VerticalDivider(width: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- TV 左栏

  Widget _tvLeftPanel() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // 指定搜索源 (对照原版 tvSearchCheckboxBtn).
        TvButton(
          label: _searchSite?.name ?? '全部源站',
          icon: Icons.tune,
          height: 52,
          fontSize: 17,
          onTap: _pickSearchSite,
        ),
        const SizedBox(height: 10),
        // 输入框: 焦点态白色描边, 只读 (输入全靠下方键盘).
        Container(
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _inputFocused ? Colors.white : Colors.grey.shade700,
              width: _inputFocused ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: TextField(
            controller: _ctrl,
            focusNode: _inputFocus,
            readOnly: true,
            showCursor: true,
            style: const TextStyle(fontSize: 18),
            decoration: const InputDecoration(
              hintText: '请输入要搜索的内容',
              hintStyle: TextStyle(fontSize: 16),
              border: InputBorder.none,
              isCollapsed: true,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TvButton(
                label: '搜索',
                icon: Icons.search,
                height: 56,
                fontSize: 18,
                selected: true,
                onTap: () => _search(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TvButton(
                label: '清空',
                height: 56,
                fontSize: 18,
                onTap: () {
                  _ctrl.clear();
                  setState(() {
                    _results.clear();
                    _query = '';
                    _focusFirstResult = false;
                  });
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _keyboard(),
      ],
    );
  }

  /// 屏显键盘: 首行 远程搜索/删除 各占半行, 其后每行 6 个字符键.
  Widget _keyboard() {
    final rows = <Widget>[
      Row(
        children: [
          Expanded(child: _keyBtn('远程搜索', wide: true)),
          Expanded(child: _keyBtn('删除', wide: true)),
        ],
      ),
    ];
    const perRow = 6;
    for (var i = 2; i < _keyboardKeys.length; i += perRow) {
      final keys = _keyboardKeys.skip(i).take(perRow).toList();
      rows.add(Row(children: [for (final k in keys) Expanded(child: _keyBtn(k))]));
    }
    return Column(children: rows);
  }

  Widget _keyBtn(String key, {bool wide = false}) {
    return Padding(
      padding: const EdgeInsets.all(3),
      child: TvFocusable(
        radius: 6,
        onTap: () => _onKey(key),
        child: Container(
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0x6C3D3D3D),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            key,
            style: TextStyle(
              fontSize: wide ? 16 : 20,
              fontWeight: wide ? FontWeight.w600 : FontWeight.normal,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  void _onKey(String key) {
    switch (key) {
      case '远程搜索':
        _search();
      case '删除':
        final text = _ctrl.text;
        if (text.isNotEmpty) {
          _ctrl.text = text.substring(0, text.length - 1);
          _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
        }
      default:
        _ctrl.text += key;
        _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    }
  }

  /// 指定搜索源弹层: TV 对话框 / 手机 SimpleDialog.
  Future<void> _pickSearchSite() async {
    final picked = await showDialog<Site?>(
      context: context,
      builder: (ctx) {
        final options = <Site?>[null, ..._sites];
        if (!TvMode.isTV.value) {
          return SimpleDialog(
            title: const Text('指定搜索源'),
            children: [
              for (final s in options)
                RadioListTile<Site?>(
                  value: s,
                  groupValue: _searchSite,
                  title: Text(s?.name ?? '全部源站'),
                  subtitle: s == null ? null : Text(s.key),
                  onChanged: (v) => Navigator.of(ctx).pop(v),
                ),
            ],
          );
        }
        return AlertDialog(
          title: const Text('指定搜索源'),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < options.length; i++)
                  TvFocusable(
                    autofocus: i == 0,
                    radius: 8,
                    focusBackground: false,
                    onTap: () => Navigator.of(ctx).pop(options[i]),
                    child: ListTile(
                      leading: Icon(
                        options[i] == _searchSite
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: Colors.white70,
                      ),
                      title: Text(
                        options[i]?.name ?? '全部源站',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == _searchSite) return;
    setState(() => _searchSite = picked);
    // 已有查询时自动重搜 (对照原版选中源后立即刷新).
    if (_query.isNotEmpty && !_running) _search(_query);
  }

  // ---------------------------------------------------------------- TV 中栏: 热词

  Widget _hotWordPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text('热词', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (_hotLoading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                ),
              if (!_hotLoading && _hotWords.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('暂无热词', style: TextStyle(color: Colors.grey)),
                ),
              for (final w in _hotWords)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: TvFocusable(
                    radius: 20,
                    onTap: () {
                      _ctrl.text = w;
                      _search(w);
                    },
                    child: Container(
                      height: 50,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0x6C3D3D3D),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        w,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 结果区 (双端共用)

  Widget _body() {
    if (_query.isEmpty && !_running) {
      // 手机空态: 提示 + 热词 chips; TV 空态由左/中栏主导, 这里只放提示.
      if (TvMode.isTV.value) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('用左侧键盘输入, 或按"远程搜索"', textAlign: TextAlign.center),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Text('输入关键词, 将并行搜索全部 ${_sites.length} 个源', textAlign: TextAlign.center),
          ),
          if (_hotWords.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Center(
              child: Text('热词', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final w in _hotWords)
                  ActionChip(
                    label: Text(w, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onPressed: () {
                      _ctrl.text = w;
                      _search(w);
                    },
                  ),
              ],
            ),
          ],
        ],
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
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 8),
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
              fontSize: 15,
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
      itemBuilder: (ctx, i) => _row(flat[i], autofocus: TvMode.isTV.value && _focusFirstResult && i == 0),
    );
  }

  Widget _row(MapEntry<Site, VodItem> entry, {bool autofocus = false}) {
    final site = entry.key;
    final item = entry.value;
    final scheme = Theme.of(context).colorScheme;
    return TvFocusable(
      autofocus: autofocus,
      radius: 8,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DetailPage(site: site, vodId: item.id, vodName: item.name),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0x6C3D3D3D),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(width: 110, height: 150, child: _cover(item)),
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
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
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
