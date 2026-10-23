import 'dart:convert';

import '../engine/engine_channel.dart';

/// Runtime state + typed wrappers for engine calls.
class SpiderData {

  /// home: {"class":[{"type_name":.., "type_id":..}],"list":[...]}
  static Future<Map<String, dynamic>> home(String siteKey, bool filter) async {
    final raw = await EngineChannel.invoke(siteKey, 'home', filter ? 'true' : 'false');
    return _asMap(raw);
  }

  static Future<Map<String, dynamic>> homeVod(String siteKey) async {
    return _asMap(await EngineChannel.invoke(siteKey, 'homeVod', ''));
  }

  static Future<Map<String, dynamic>> category(
      String siteKey, String tid, String page, Map<String, String> extend) async {
    final arg = jsonEncode({
      'tid': tid,
      'pg': page,
      'filter': false,
      'ext': extend,
    });
    return _asMap(await EngineChannel.invoke(siteKey, 'category', arg));
  }

  static Future<Map<String, dynamic>> detail(String siteKey, String id) async {
    return _asMap(await EngineChannel.invoke(siteKey, 'detail', jsonEncode({'id': id})));
  }

  static Future<Map<String, dynamic>> search(String siteKey, String key, String page) async {
    return _asMap(await EngineChannel.invoke(
        siteKey, 'search', jsonEncode({'wd': key, 'pg': page})));
  }

  static Future<Map<String, dynamic>> play(
      String siteKey, String flag, String id) async {
    return _asMap(
        await EngineChannel.invoke(siteKey, 'player', jsonEncode({'flag': flag, 'id': id})));
  }

  static Map<String, dynamic> _asMap(String raw) {
    if (raw.isEmpty) return <String, dynamic>{};
    var text = raw.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) text = text.substring(start, end + 1);
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) return parsed;
    } catch (_) {}
    return <String, dynamic>{};
  }
}

/// Row data helpers shared by pages.
class VodItem {
  final String id;

  /// 所属源 key. 豆瓣热播/观看历史等条目可能不属于当前首页源,
  /// 点击进详情时要回原始源 (对照原版 Movie.Video.sourceKey).
  final String siteKey;
  final String name;
  final String cover;
  final String? remark;

  /// 豆瓣评分 (vod_score / vod_douban_score), 展示为角标.
  final String? score;

  /// 年份 (vod_year), 展示为左上角角标 (对照原版 item_grid.xml tvYear).
  final String? year;

  const VodItem({
    required this.id,
    required this.name,
    required this.cover,
    this.remark,
    this.score,
    this.year,
    this.siteKey = '',
  });

  /// id 为空的条目 (豆瓣直连抓取的热播没有 vod_id):
  /// 原版 UserFragment 对这类条目跳搜索页 (jumpSearch).
  bool get searchOnly => id.isEmpty;
}

class PlayUrl {
  final String flag;
  final List<String> eps;
  final List<String> urls;
  final String playFrom;
  const PlayUrl(this.flag, this.eps, this.urls, this.playFrom);
}

List<Map<String, dynamic>> asList(dynamic raw) {
  if (raw is List) {
    return raw.whereType<Map<String, dynamic>>().toList();
  }
  return const [];
}

List<VodItem> vodList(dynamic raw, {String siteKey = ''}) {
  return asList(raw).map((m) {
    return VodItem(
      id: m['vod_id']?.toString() ?? '',
      siteKey: siteKey,
      name: (m['vod_name'] as String?) ?? '',
      cover: (m['vod_pic'] as String?) ?? '',
      remark: m['vod_remarks'] as String?,
      score: _scoreOf(m),
      year: _yearOf(m),
    );
  }).where((v) => v.name.isNotEmpty).toList();
}

/// 评分字段: mac-cms 风格 vod_score, 豆瓣风格 vod_douban_score.
/// 过滤 "0"/""/"暂无" 等无意义值, 避免角标刷屏.
String? _scoreOf(Map<String, dynamic> m) {
  for (final key in const ['vod_score', 'vod_douban_score']) {
    final v = m[key]?.toString().trim();
    if (v != null && v.isNotEmpty && v != '0' && v != '0.0' && v != '暂无' && v != '暂无评分') {
      return v;
    }
  }
  return null;
}

/// 年份角标 (对照原版 GridAdapter tvYear: year <= 0 时隐藏).
String? _yearOf(Map<String, dynamic> m) {
  final v = m['vod_year']?.toString().trim();
  if (v == null || v.isEmpty || v == '0') return null;
  final n = int.tryParse(v);
  if (n != null && n <= 0) return null;
  return v;
}

/// 原版 UserFragment.loadHots: 豆瓣直连抓取的热播 JSON
/// {"data":[{"title":"...","rate":"7.8","cover":"https://..."}]}.
/// rate 拼 " 分" 作为备注; 条目没有 vod_id, 点击走搜索 (searchOnly).
const String kDoubanUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

List<VodItem> doubanHotList(dynamic raw) {
  return asList(raw).map((m) {
    final rate = m['rate']?.toString().trim() ?? '';
    final cover = (m['cover'] as String?) ?? '';
    return VodItem(
      id: '',
      name: (m['title'] as String?) ?? '',
      // 对照原版 loadHots: 豆瓣图床有防盗链, 封面必须带 UA + Referer (由 picUrlAndHeaders 拆成请求头).
      cover: cover.isEmpty ? '' : '$cover@User-Agent=$kDoubanUa@Referer=https://www.douban.com/',
      remark: rate.isNotEmpty && rate != '0' ? '$rate 分' : null,
      score: rate.isNotEmpty && rate != '0' ? rate : null,
    );
  }).where((v) => v.name.isNotEmpty).toList();
}

List<Map<String, dynamic>> classList(dynamic raw) {
  return asList(raw)
      .where((m) => (m['type_id'] ?? '').toString().isNotEmpty)
      .toList();
}

/// "flag1#!#第1集$url#第2集$url2" style groups are separated by $$$.
List<PlayUrl> parsePlayGroups(String playUrl, String playFrom) {
  final flags = playFrom.split('\$\$\$');
  final groups = playUrl.split('\$\$\$');
  final result = <PlayUrl>[];
  for (var i = 0; i < groups.length; i++) {
    final flag = i < flags.length && flags[i].isNotEmpty ? flags[i] : 'playlist';
    final eps = <String>[];
    final links = <String>[];
    for (final ep in groups[i].split('#')) {
      if (ep.isEmpty) continue;
      final sep = ep.indexOf('\$');
      if (sep > 0) {
        eps.add(ep.substring(0, sep).trim());
        links.add(ep.substring(sep + 1).trim());
      } else {
        eps.add('第${eps.length + 1}集');
        links.add(ep.trim());
      }
    }
    if (links.isNotEmpty) result.add(PlayUrl(flag, eps, links, flag));
  }
  return result;
}

String playUrlOf(Map<String, dynamic> json, {String? flag, String? id}) {
  var url = (json['url'] as String?) ?? '';
  final parse = json['parse'];
  if (parse is List && parse.isNotEmpty && !url.startsWith('http')) {
    // Some jar sources return "url" empty and parse urls list.
    final first = parse.first;
    if (first is String) url = first;
  }
  if (url.isEmpty) {
    // attempt header["player"] pattern fallback
    final jx = json['jx'];
    if (jx is String && jx.startsWith('http')) url = jx;
  }
  return url;
}
