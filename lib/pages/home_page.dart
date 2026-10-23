import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/config.dart';
import '../data/douban_hot.dart';
import '../data/history.dart';
import '../data/home_prefs.dart';
import '../data/spider_data.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';
import 'detail_page.dart';
import 'favorites_page.dart';
import 'history_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

/// 原版首页的 Flutter 移植 (HomeFragment + UserFragment + GridFragment):
/// 顶部 线路/站源/搜索/收藏/历史 + 横向分类 Tab + 每 Tab 海报网格.
/// "主页" Tab 的数据来源由 HomePrefs.homeRec 决定:
///   0 豆瓣热播 (直连豆瓣抓取, 失败回退 spider.homeVideoContent)
///   1 站点推荐 (homeContent 的 list)
///   2 观看历史 (本地观看记录)
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _TabSpec {
  /// 'my0' = 主页 (对照原版 DefaultConfig.adjustSort 插入的 my0); 其余为分类 type_id.
  final String id;
  final String name;
  const _TabSpec(this.id, this.name);
}

class _TabState {
  final List<VodItem> items = [];
  final ScrollController controller = ScrollController();
  bool loading = false;
  bool loaded = false;
  String error = '';
  int page = 1;
  bool hasMore = true;
}

class _HomePageState extends State<HomePage> {
  Site? _site;
  List<_TabSpec> _tabs = const [];
  int _tab = 0;
  final Map<String, _TabState> _states = {};

  /// homeContent 内存缓存 (对照原版 SourceViewModel.sortCache, 最多 5 个源).
  final Map<String, Map<String, dynamic>> _homeCache = {};

  bool _bootLoading = false;
  String _bootError = '';
  bool _lineBusy = false;

  bool get _hasConfig => Config.loaded != null && Config.loaded!.sites.any((s) => s.isRealSource);

  List<Site> get _sites => Config.loaded?.sites.where((s) => s.isRealSource).toList() ?? const [];

  String? _loadedConfigUrl;

  @override
  void initState() {
    super.initState();
    Config.changeNotifier.addListener(_onConfigChanged);
    HomePrefs.recNotifier.addListener(_onHomeRecChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    Config.changeNotifier.removeListener(_onConfigChanged);
    HomePrefs.recNotifier.removeListener(_onHomeRecChanged);
    for (final st in _states.values) {
      st.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    await HomePrefs.load();
    if (!mounted) return;
    await _onConfigChanged();
  }

  /// 首页列表数据来源变化 (设置页切换) → 重载"主页" Tab.
  void _onHomeRecChanged() => _reloadHomeTab();

  Future<void> _onConfigChanged() async {
    if (!mounted) return;
    if (!_hasConfig) {
      await _bootstrap();
      return;
    }
    final configUrl = Config.loaded!.url;
    // 解析首页源: 优先 Hawk HOME_API 保存的 key (原版 ApiConfig.parseJson 末尾逻辑),
    // 不存在则退回第一个源.
    Site? site;
    final savedKey = HomePrefs.homeApi;
    if (savedKey.isNotEmpty) {
      for (final s in _sites) {
        if (s.key == savedKey) {
          site = s;
          break;
        }
      }
    }
    site ??= _sites.first;
    await HomePrefs.setHomeApi(site.key);
    final sameSite = _site?.key == site.key;
    final sameConfig = _loadedConfigUrl == configUrl;
    _loadedConfigUrl = configUrl;
    _site = site;
    if (!sameSite || !sameConfig) {
      await _loadHomeContent();
    }
  }

  Future<void> _bootstrap() async {
    if (_bootLoading || Config.loaded != null) return;
    final url = await Config.loadUrl();
    if (url.isEmpty || !mounted) {
      setState(() => _bootError = '请先在"设置"导入 TVBox 配置');
      return;
    }
    setState(() {
      _bootLoading = true;
      _bootError = '';
    });
    final (ok, msg) = await Config.applyInput(url);
    if (!mounted) return;
    setState(() => _bootLoading = false);
    if (!ok) setState(() => _bootError = msg);
  }

  // ---------------------------------------------------------------- 数据加载

  Future<void> _loadHomeContent() async {
    final site = _site;
    if (site == null) return;
    setState(() {
      _tabs = const [_TabSpec('my0', '主页')];
      _tab = 0;
    });
    for (final st in _states.values) {
      st.controller.dispose();
    }
    _states.clear();

    // 豆瓣热播 / 观看历史 与站点 homeContent 无关 (原版 UserFragment 独立加载),
    // 不能排在 home 之后: home 慢/失败时, 热播也跟着白屏. 站点推荐(1)才依赖 home 结果.
    if (HomePrefs.homeRec != 1) {
      _reloadHomeTab();
    }

    var json = _homeCache[site.key];
    if (json == null) {
      setState(() => _bootLoading = true);
      // 对照原版 SourceViewModel.getSort: homeContent(true); 空结果不缓存 (否则一次失败
      // 首页就永久空白), 失败时重试一次 (jar/js 爬虫首次创建偶发超时).
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
        try {
          final r = await SpiderData.home(site.key, true);
          if (r.isNotEmpty) {
            json = r;
            _homeCache[site.key] = r;
            if (_homeCache.length > 5) {
              _homeCache.remove(_homeCache.keys.first);
            }
            break;
          }
        } catch (_) {}
        if (!mounted) return;
      }
      if (!mounted) return;
      setState(() => _bootLoading = false);
    }
    final classes = classList(json?['class']);
    if (!mounted) return;
    setState(() {
      _tabs = [
        const _TabSpec('my0', '主页'),
        ...classes.map((c) => _TabSpec(c['type_id']?.toString() ?? '', c['type_name']?.toString() ?? '')),
      ];
    });
    final st = _states['my0'];
    if (HomePrefs.homeRec == 1 || st == null || (!st.loaded && !st.loading)) {
      await _reloadHomeTab();
    }
  }

  /// "主页" Tab: 按 HomePrefs.homeRec 取数.
  Future<void> _reloadHomeTab() async {
    final site = _site;
    if (site == null) return;
    final st = _states.putIfAbsent('my0', () => _TabState());
    if (st.loading) return;
    setState(() {
      st.loading = true;
      st.error = '';
    });
    try {
      final items = await _fetchHomeRecItems(site);
      if (!mounted) return;
      setState(() {
        st.items
          ..clear()
          ..addAll(items);
        st.loading = false;
        st.loaded = true;
        // "主页" Tab 没有分页 (豆瓣热播/站点推荐/历史都是一页),
        // 必须显式关闭, 否则触底会误触发 categoryContent('my0').
        st.hasMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        st.loading = false;
        st.error = '加载失败';
      });
    }
  }

  Future<List<VodItem>> _fetchHomeRecItems(Site site) async {
    switch (HomePrefs.homeRec) {
      case 1:
        // 站点推荐: homeContent 的 list (对照原版 UserFragment homeSourceRec).
        final json = _homeCache[site.key] ?? await SpiderData.home(site.key, true);
        return vodList(json['list'], siteKey: site.key);
      case 2:
        // 观看历史: 本地记录 (对照原版 UserFragment RoomDataManger.getAllVodRecord).
        final records = await History.list();
        return records
            .map((h) => VodItem(
                  id: h.vodId,
                  siteKey: h.siteKey,
                  name: h.name,
                  cover: h.cover,
                  remark: h.ep.isEmpty ? null : '上次看到${h.ep}',
                ))
            .where((v) => v.name.isNotEmpty)
            .toList();
      default:
        // 豆瓣热播: 直连豆瓣 (对照原版 UserFragment.setDouBanData);
        // 失败回退 spider.homeVideoContent (对照 SourceViewModel.getHomeRecList).
        final hot = await DoubanHot.fetch();
        if (hot.isNotEmpty) return hot;
        final json = await SpiderData.homeVod(site.key);
        final vod = vodList(json['list'], siteKey: site.key);
        if (vod.isNotEmpty) return vod;
        // 再退一步: 站点 homeContent 自带的推荐列表 (很多 jar 源只在这里给数据).
        return vodList(_homeCache[site.key]?['list'], siteKey: site.key);
    }
  }

  Future<void> _loadCategory(_TabSpec tab, {bool more = false}) async {
    final site = _site;
    if (site == null || tab.id.isEmpty) return;
    final st = _states.putIfAbsent(tab.id, () => _TabState());
    if (st.loading) return;
    setState(() => st.loading = true);
    try {
      final json = await SpiderData.category(site.key, tab.id, '${st.page}', {});
      final next = vodList(json['list'], siteKey: site.key);
      if (!mounted) return;
      final pc = int.tryParse('${json['pagecount']}') ?? 0;
      setState(() {
        if (more) {
          st.items.addAll(next);
        } else {
          st.items
            ..clear()
            ..addAll(next);
        }
        st.page++;
        // 对照原版 GridFragment: pagecount<=0 时不限制, 否则 page>maxPage 即结束;
        // 本页无数据也直接结束, 避免无限转圈.
        st.hasMore = next.isNotEmpty && (pc <= 0 || st.page <= pc);
        st.loading = false;
        st.loaded = true;
        st.error = '';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        st.loading = false;
        st.error = '加载失败';
      });
    }
  }

  void _selectTab(int i) {
    if (i < 0 || i >= _tabs.length) return;
    setState(() => _tab = i);
    final tab = _tabs[i];
    if (tab.id == 'my0') {
      final st = _states['my0'];
      if (st == null || !st.loaded) _reloadHomeTab();
      return;
    }
    final st = _states[tab.id];
    if (st == null || !st.loaded) _loadCategory(tab);
  }

  // ---------------------------------------------------------------- 交互

  Future<void> _selectSite(Site site) async {
    if (site.key == _site?.key) return;
    await HomePrefs.setHomeApi(site.key);
    setState(() => _site = site);
    await _loadHomeContent();
  }

  /// 通用单选弹层: TV 用对话框 (遥控器可上下移动焦点, 首项自动聚焦),
  /// 手机保持底部弹层 (对照原版 SelectDialog / bottom sheet 行为).
  Future<T?> _pick<T>(String title, List<T> items, String Function(T) labelOf, T? current) {
    if (items.isEmpty) return Future.value(null);
    if (!TvMode.isTV.value) {
      return showModalBottomSheet<T>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final s in items)
                ListTile(
                  leading: Icon(s == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  title: Text(labelOf(s), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_subtitleOf(s)),
                  onTap: () => Navigator.of(ctx).pop(s),
                ),
            ],
          ),
        ),
      );
    }
    return showDialog<T>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (var i = 0; i < items.length; i++)
                TvFocusable(
                  autofocus: i == 0,
                  radius: 8,
                  // 列表项文字为白色: 焦点态只发光+放大, 不用白填充 (避免白字白底).
                  focusBackground: false,
                  onTap: () => Navigator.of(ctx).pop(items[i]),
                  child: ListTile(
                    leading: Icon(
                      items[i] == current ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: Colors.white70,
                    ),
                    title: Text(
                      labelOf(items[i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        ],
      ),
    );
  }

  String _subtitleOf(Object? s) {
    if (s is Site) return s.key;
    if (s is ConfigLine) return s.url;
    return '';
  }

  void _showSitePicker() {
    _pick<Site>('切换站源', _sites, (s) => s.displayName, _site).then((site) {
      if (site != null) _selectSite(site);
    });
  }

  /// 线路切换 (对照原版"配置地址"列表, 复用设置页的应用链路).
  Future<void> _switchLine(ConfigLine line) async {
    final loaded = Config.loaded;
    if (loaded == null || _lineBusy) return;
    if (line.url == loaded.url) return;
    setState(() => _lineBusy = true);
    final (ok, msg) = await Config.applyInput(line.url, keepLines: loaded.lines);
    if (!mounted) return;
    setState(() => _lineBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已切换到线路: ${line.name}' : msg)),
    );
  }

  void _showLinePicker() {
    final loaded = Config.loaded;
    if (loaded == null || loaded.lines.length < 2) return;
    _pick<ConfigLine>('切换线路', loaded.lines, (l) => l.name, loaded.lines.firstWhere(
      (l) => l.url == loaded.url,
      orElse: () => loaded.lines.first,
    )).then((line) {
      if (line != null) _switchLine(line);
    });
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchPage(initialSite: _site)),
    );
  }

  void _openVod(VodItem item) {
    final site = History.siteOf(item.siteKey) ?? _site;
    if (site == null) return;
    if (item.searchOnly) {
      // 豆瓣热播条目没有 vod_id: 跳搜索页 (对照原版 UserFragment.jumpSearch).
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SearchPage(initialSite: site, initialQuery: item.name)),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(site: site, vodId: item.id, vodName: item.name),
      ),
    );
  }

  // ---------------------------------------------------------------- UI

  /// MENU 键 (对照原版 HomeActivity.dispatchKeyEvent): 短按 = 换源,
  /// 长按 2s = 设置页. 仅 TV 模式生效.
  DateTime? _menuDownAt;

  KeyEventResult _onMenuKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.contextMenu) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _menuDownAt = DateTime.now();
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent && _menuDownAt != null) {
      final held = DateTime.now().difference(_menuDownAt!);
      _menuDownAt = null;
      if (held.inMilliseconds >= 2000) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsPage()),
        );
      } else {
        _showSitePicker();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_hasConfig) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_bootLoading) const CircularProgressIndicator(),
              if (!_bootLoading)
                Text(_bootError.isEmpty ? '未导入配置' : _bootError, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('请到"设置"页导入 TVBox 配置', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    final body = Column(
      children: [
        _topBar(theme),
        _tabBar(theme),
        Expanded(child: _content()),
      ],
    );
    if (!TvMode.isTV.value) return body;
    return Focus(
      canRequestFocus: true,
      onKeyEvent: _onMenuKey,
      child: body,
    );
  }

  Widget _topBar(ThemeData theme) {
    final tv = TvMode.isTV.value;
    final loaded = Config.loaded;
    final lines = loaded?.lines ?? const [];
    String lineLabel = '线路';
    if (loaded != null) {
      for (final l in lines) {
        if (l.url == loaded.url) {
          lineLabel = l.name;
          break;
        }
      }
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(tv ? 20 : 12, tv ? 12 : 8, tv ? 16 : 8, 4),
      child: Row(
        children: [
          // 线路 / 站源: TV 下为可聚焦 chip (焦点白描边), 手机为普通 InkWell.
          TvFocusable(
            radius: 8,
            onTap: _lineBusy ? null : _showLinePicker,
            child: _barChip(
              label: lineLabel,
              icon: Icons.arrow_drop_down,
              busy: _lineBusy,
            ),
          ),
          const SizedBox(width: 6),
          TvFocusable(
            radius: 8,
            onTap: _showSitePicker,
            child: _barChip(
              label: _site?.displayName ?? '站源',
              icon: Icons.arrow_drop_down,
            ),
          ),
          const SizedBox(width: 6),
          // 搜索入口: TV 下为醒目大按钮 (对照原版顶部搜索按钮).
          Expanded(
            child: TvFocusable(
              radius: 18,
              onTap: _openSearch,
              child: Container(
                height: tv ? 52 : 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 18, color: Colors.grey),
                    const SizedBox(width: 8),
                    Text('搜索影视...',
                        style: TextStyle(fontSize: tv ? 17 : 12, color: Colors.grey)),
                  ],
                ),
              ),
            ),
          ),
          if (tv) ...[
            const SizedBox(width: 8),
            TvButton(
              label: '收藏',
              icon: Icons.star_border,
              height: 52,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FavoritesPage()),
              ),
            ),
            const SizedBox(width: 6),
            TvButton(
              label: '历史',
              icon: Icons.history,
              height: 52,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryPage()),
              ),
            ),
          ] else ...[
            IconButton(
              tooltip: '收藏',
              icon: const Icon(Icons.star_border),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FavoritesPage()),
              ),
            ),
            IconButton(
              tooltip: '历史',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryPage()),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _barChip({required String label, required IconData icon, bool busy = false}) {
    final theme = Theme.of(context);
    final tv = TvMode.isTV.value;
    return Container(
      height: tv ? 44 : 36,
      padding: EdgeInsets.symmetric(horizontal: tv ? 12 : 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (busy)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Text(label,
                style: TextStyle(
                    fontSize: tv ? 17 : 13, fontWeight: FontWeight.w600)),
          Icon(icon, size: tv ? 22 : 18, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _tabBar(ThemeData theme) {
    if (_tabs.length <= 1) return const SizedBox.shrink();
    final tv = TvMode.isTV.value;
    return SizedBox(
      height: tv ? 60 : 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: tv ? 16 : 8),
        itemCount: _tabs.length,
        itemBuilder: (ctx, i) {
          final selected = i == _tab;
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: tv ? 4 : 6),
            child: ChoiceChip(
              label: Text(_tabs[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: selected,
              labelStyle: TextStyle(
                fontSize: tv ? 17 : 13,
                color: selected ? theme.colorScheme.onPrimary : null,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
              padding: EdgeInsets.symmetric(horizontal: tv ? 16 : 8, vertical: tv ? 10 : 4),
              onSelected: (_) => _selectTab(i),
            ),
          );
        },
      ),
    );
  }

  Widget _content() {
    if (_tab >= _tabs.length) return const SizedBox.shrink();
    final tab = _tabs[_tab];
    final st = _states[tab.id];
    if (st == null || (!st.loaded && st.items.isEmpty)) {
      return Center(
        child: st != null && st.error.isNotEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(st.error),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => tab.id == 'my0' ? _reloadHomeTab() : _loadCategory(tab),
                    child: const Text('重试'),
                  ),
                ],
              )
            : const CircularProgressIndicator(),
      );
    }
    if (st.items.isEmpty) {
      final hint = tab.id == 'my0'
          ? (HomePrefs.homeRec == 2 ? '暂无观看历史' : '暂无数据')
          : '暂无数据';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(hint, style: const TextStyle(color: Colors.grey)),
            if (HomePrefs.homeRec != 2) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  _homeCache.remove(_site?.key);
                  _loadHomeContent();
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      );
    }
    return IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < _tabs.length; i++)
          _tabGrid(_tabs[i], _states[_tabs[i].id] ?? (_states[_tabs[i].id] = _TabState())),
      ],
    );
  }

  Widget _tabGrid(_TabSpec tab, _TabState st) {
    return GridView.builder(
      controller: st.controller,
      padding: EdgeInsets.all(TvMode.isTV.value ? 16 : 8),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        // TV: 大海报 (对照原版 item_grid.xml vs_214 x vs_280 ≈ 0.76,
        // 留出片名栏后取 0.66); 手机: 原 130 宽小网格.
        maxCrossAxisExtent: TvMode.isTV.value ? 240 : 130,
        childAspectRatio: TvMode.isTV.value ? 0.68 : 0.62,
        mainAxisSpacing: TvMode.isTV.value ? 16 : 8,
        crossAxisSpacing: TvMode.isTV.value ? 16 : 8,
      ),
      itemCount: st.items.length + (st.hasMore && tab.id != 'my0' ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i >= st.items.length) {
          // 触底加载更多 (对照原版 BaseQuickAdapter RequestLoadMoreListener).
          if (!st.loading && st.controller.hasClients) {
            final pos = st.controller.position;
            if (pos.hasContentDimensions && pos.pixels >= pos.maxScrollExtent - 200) {
              _loadCategory(tab, more: true);
            }
          }
          return const Center(
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return _poster(st.items[i]);
      },
    );
  }

  Widget _poster(VodItem item) {
    final isHomeTab = _tab == 0;
    // 备注分片: 优先 remarks; 没有 remarks 但有评分时展示评分
    // (豆瓣热播的 remark 已是 "8.4 分", 不再重复).
    var note = item.remark?.trim() ?? '';
    if (note.isEmpty && item.score != null && item.score!.isNotEmpty) {
      note = '评分 ${item.score}';
    }
    final year = item.year?.trim() ?? '';
    final tv = TvMode.isTV.value;
    return TvFocusable(
      onTap: () => _openVod(item),
      radius: 8,
      focusMargin: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 海报 (对照原版 RoundTransformation 圆角 + Picasso).
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _cover(item),
                ),
                // 左上角角标: 年份 (仅分类 Tab, 对照原版 item_grid.xml tvYear;
                // 主页 Tab 的原版 item_user_hot_vod.xml 没有年份角标).
                if (year.isNotEmpty && !isHomeTab)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: _badge(year, bg: Colors.black54),
                  ),
                // 左上角角标: 主页 Tab 的数据来源 (对照 item_user_hot_vod.xml tvRate).
                if (isHomeTab)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: _badge(
                      HomePrefs.homeRec == 2
                          ? (History.siteOf(item.siteKey)?.displayName ?? '搜')
                          : HomePrefs.recName(HomePrefs.homeRec),
                      bg: HomePrefs.homeRec == 2 ? Colors.black54 : const Color(0xBD0CADE2),
                    ),
                  ),
                // 底部: 备注分片 + 片名栏 (对照 tvNote / tvName).
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (note.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 2),
                          child: _badge(note, bg: Colors.black54),
                        ),
                      Container(
                        width: double.infinity,
                        color: Colors.black54,
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: tv ? 14 : 12, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cover(VodItem item) {
    if (item.cover.isEmpty) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.movie_outlined, color: Colors.grey)),
      );
    }
    final (url, headers) = picUrlAndHeaders(item.cover);
    return Image.network(
      url,
      fit: BoxFit.cover,
      headers: headers.isEmpty ? null : headers,
      errorBuilder: (_, __, ___) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.broken_image_outlined, color: Colors.grey)),
      ),
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }

  Widget _badge(String text, {required Color bg}) {
    final tv = TvMode.isTV.value;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: tv ? 14 : 10, color: Colors.white),
      ),
    );
  }
}
