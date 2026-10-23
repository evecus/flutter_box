import 'package:flutter/material.dart';

import '../config/config.dart';
import '../data/favorites.dart';
import '../data/spider_data.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';
import 'player_page.dart';

class DetailPage extends StatefulWidget {
  final Site site;
  final String vodId;
  final String vodName;

  const DetailPage({super.key, required this.site, required this.vodId, required this.vodName});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic> _json = {};
  final List<PlayUrl> _groups = [];
  bool _loading = true;
  bool _error = false;
  int _groupIdx = 0;
  int _epIdx = -1;
  bool _fav = false;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final json = await SpiderData.detail(widget.site.key, widget.vodId);
      final list = asList(json['list']);
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _error = true;
          _loading = false;
        });
        return;
      }
      final vod = list.first;
      final groups = parsePlayGroups(
        vod['vod_play_url']?.toString() ?? '',
        vod['vod_play_from']?.toString() ?? '',
      );
      setState(() {
        _json = vod;
        _groups..clear()..addAll(groups);
        _loading = false;
      });
      _syncFav();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<void> _syncFav() async {
    final fav = await Favorites.isFav(widget.site.key, widget.vodId);
    if (!mounted) return;
    setState(() => _fav = fav);
  }

  Future<void> _toggleFav() async {
    await Favorites.toggle(FavoriteItem(
      siteKey: widget.site.key,
      siteName: widget.site.name,
      vodId: widget.vodId,
      name: (_json['vod_name'] ?? widget.vodName).toString(),
      cover: (_json['vod_pic'] ?? '').toString(),
    ));
    _syncFav();
  }

  void _openEp() {
    if (_groupIdx < 0 || _groupIdx >= _groups.length) return;
    final group = _groups[_groupIdx];
    if (_epIdx < 0 || _epIdx >= group.urls.length) {
      _epIdx = 0;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          site: widget.site,
          vodId: widget.vodId,
          vodName: (_json['vod_name'] ?? widget.vodName).toString(),
          cover: (_json['vod_pic'] ?? '').toString(),
          flag: group.flag,
          epNames: group.eps,
          epUrls: group.urls,
          startIndex: _epIdx,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.vodName),
        actions: [
          IconButton(
            icon: Icon(_fav ? Icons.favorite : Icons.favorite_border),
            tooltip: '收藏',
            onPressed: _toggleFav,
          ),
          IconButton(
            icon: _switching
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.swap_horiz),
            tooltip: '换源',
            onPressed: _switching ? null : _showSwitchMenu,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? Center(child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('详情加载失败'),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ))
              : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final tv = TvMode.isTV.value;
    return ListView(
      padding: EdgeInsets.all(tv ? 24 : 12),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (((_json['vod_pic'] ?? '') as String).isNotEmpty)
              SizedBox(
                width: tv ? 180 : 110,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _json['vod_pic'] as String,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(height: tv ? 240 : 150, color: Colors.grey.shade800),
                  ),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((_json['vod_name'] ?? widget.vodName).toString(),
                      style: tv
                          ? Theme.of(context).textTheme.headlineSmall
                          : Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  if (((_json['vod_year'] ?? '')).toString().isNotEmpty)
                    Text((_json['vod_year'] ?? '').toString(),
                        style: TextStyle(fontSize: tv ? 17 : 14)),
                  if (((_json['vod_area'] ?? '')).toString().isNotEmpty)
                    Text((_json['vod_area'] ?? '').toString(),
                        style: TextStyle(fontSize: tv ? 17 : 14)),
                  Text(widget.site.name,
                      style: TextStyle(color: Colors.grey, fontSize: tv ? 14 : 12)),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: tv ? 16 : 12),
        if (((_json['vod_remarks'] ?? '')).toString().isNotEmpty)
          Text((_json['vod_remarks'] ?? '').toString(),
              style: TextStyle(color: Colors.grey, fontSize: tv ? 15 : 14)),
        if (((_json['vod_actor'] ?? '')).toString().isNotEmpty)
          Text((_json['vod_actor'] ?? '').toString(),
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: tv ? 17 : 14)),
        if (((_json['vod_content'] ?? '')).toString().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text((_json['vod_content'] ?? '').toString(),
              maxLines: 8, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: tv ? 17 : 14)),
        ],
        const SizedBox(height: 16),
        for (final entry in _groups.asMap().entries) _groupSection(entry.key, entry.value),
      ],
    );
  }

  Widget _groupSection(int gi, PlayUrl group) {
    final tv = TvMode.isTV.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(group.flag,
            style: TextStyle(
                fontSize: tv ? 16 : 14, fontWeight: FontWeight.bold)),
        Wrap(
          spacing: tv ? 10 : 8,
          runSpacing: tv ? 10 : 8,
          children: [
            for (var i = 0; i < group.urls.length; i++)
              // TV: 选集按钮可聚焦, 首集自动获焦 (进入详情页即可按 OK 播放).
              TvFocusable(
                autofocus: tv && gi == 0 && i == 0,
                radius: 6,
                onTap: () {
                  setState(() {
                    _groupIdx = gi;
                    _epIdx = i;
                  });
                  _openEp();
                },
                child: Container(
                  constraints: BoxConstraints(minWidth: tv ? 76 : 0, minHeight: tv ? 52 : 0),
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(horizontal: tv ? 18 : 12, vertical: tv ? 12 : 8),
                  decoration: BoxDecoration(
                    color: const Color(0x6C3D3D3D),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                  ),
                  child: Text(
                    group.eps[i].isEmpty ? '第${i + 1}集' : group.eps[i].trim(),
                    style: TextStyle(fontSize: tv ? 17 : 14),
                  ),
                ),
              ),
          ],
        ),
        SizedBox(height: tv ? 16 : 12),
      ],
    );
  }

  Future<void> _showSwitchMenu() async {
    final loaded = Config.loaded;
    if (loaded == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有已加载的站点')));
      return;
    }
    final name = (_json['vod_name'] ?? widget.vodName).toString();
    final currentKey = widget.site.key;
    final candidates = <Site>[];
    for (final site in loaded.sites.where((s) => s.isRealSource && s.key != currentKey)) {
      candidates.add(site);
    }
    if (!mounted) return;
    // TV 用对话框 (遥控器可移动焦点), 手机保持底部弹层.
    final future = TvMode.isTV.value
        ? showDialog<Site>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('搜索 "$name" 并换源'),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              content: SizedBox(
                width: 420,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < candidates.length; i++)
                      TvFocusable(
                        autofocus: i == 0,
                        radius: 8,
                        focusBackground: false,
                        onTap: () => Navigator.of(ctx).pop(candidates[i]),
                        child: ListTile(
                          leading: const Icon(Icons.swap_horiz, color: Colors.white70),
                          title: Text(candidates[i].name,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15)),
                          subtitle: Text(candidates[i].key,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          )
        : showModalBottomSheet<Site>(
            context: context,
            builder: (ctx) {
              return SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('搜索 "$name" 并换源', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    ...candidates.map((s) => ListTile(
                          title: Text(s.name),
                          subtitle: Text(s.key),
                          onTap: () => Navigator.of(ctx).pop(s),
                        )),
                  ],
                ),
              );
            },
          );
    final site = await future;
    if (site == null) return;

    setState(() => _switching = true);
    try {
      final result = await SpiderData.search(site.key, name, '1');
      final list = vodList(result['list']);
      VodItem? match;
      for (final item in list) {
        if (item.name == name) {
          match = item;
          break;
        }
      }
      if (!mounted) return;
      if (match == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${site.name}未找到 "$name"')),
        );
        return;
      }
      // Push the matched detail, replacing this one.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => DetailPage(site: site, vodId: match!.id, vodName: match.name),
        ),
      );
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }
}
