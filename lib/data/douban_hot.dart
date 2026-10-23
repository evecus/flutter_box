import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine_channel.dart';
import 'spider_data.dart';

/// 原版 UserFragment.setDouBanData: 首页"豆瓣热播"直连豆瓣抓取当年热播电影.
/// - URL: https://movie.douban.com/j/new_search_subjects?sort=U&range=0,10&playable=1&year_range=YYYY,YYYY
/// - 按天缓存 (原版 Hawk home_hot / home_hot_day), 同一天不重复请求
/// - 抓取失败返回空列表, 由调用方回退到 spider.homeVideoContent()
class DoubanHot {
  static const _dayKey = 'home_hot_day';
  static const _jsonKey = 'home_hot';
  static const _maxItems = 25;

  /// 桌面 UA (原版 UA.randomOne() 的等价物; 豆瓣对 okhttp UA 返回 418).
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static String _today() {
    final now = DateTime.now();
    return '${now.year}${_two(now.month)}${_two(now.day)}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _url() {
    final y = DateTime.now().year;
    return 'https://movie.douban.com/j/new_search_subjects'
        '?sort=U&range=0,10&tags=&playable=1&start=0&year_range=$y,$y';
  }

  /// 取热播列表: 先按天缓存, 再网络 (Dart http → 引擎 OkHttp 兜底).
  /// 失败返回空列表 (不抛异常), 调用方回退 homeVideoContent.
  static Future<List<VodItem>> fetch() async {
    final today = _today();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_dayKey) == today) {
      final cached = prefs.getString(_jsonKey) ?? '';
      if (cached.isNotEmpty) {
        final items = _parse(cached);
        if (items.isNotEmpty) return items;
      }
    }
    var body = '';
    try {
      final res = await http
          .get(Uri.parse(_url()), headers: {'user-agent': _ua})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) body = res.body;
    } catch (_) {}
    if (body.isEmpty) {
      // 引擎 OkHttp 兜底 (IDN/证书等场景).
      body = await EngineChannel.getText(_url());
    }
    final items = _parse(body);
    if (items.isNotEmpty) {
      await prefs.setString(_dayKey, today);
      await prefs.setString(_jsonKey, body);
    }
    return items;
  }

  static List<VodItem> _parse(String body) {
    if (body.isEmpty) return const [];
    try {
      final map = jsonDecode(body);
      if (map is! Map || map['data'] is! List) return const [];
      final list = (map['data'] as List).take(_maxItems);
      return doubanHotList(list);
    } catch (_) {
      return const [];
    }
  }
}

/// FongMi 风格的图片地址后缀: "url@User-Agent=xx@Referer=yy".
/// 注意第一个 @ 段是 UA 的值本身 (无键名), 其余段才是 key=value.
/// Flutter 的 Image.network 不走这套约定, 拆成干净 URL + headers.
(String, Map<String, String>) picUrlAndHeaders(String url) {
  var u = url.trim();
  final headers = <String, String>{};
  final at = u.indexOf('@User-Agent=');
  if (at > 0) {
    final rest = u.substring(at + 12);
    u = u.substring(0, at);
    final segs = rest.split('@');
    if (segs.isNotEmpty && segs[0].isNotEmpty) headers['User-Agent'] = segs[0];
    for (var i = 1; i < segs.length; i++) {
      final eq = segs[i].indexOf('=');
      if (eq > 0) headers[segs[i].substring(0, eq)] = segs[i].substring(eq + 1);
    }
  }
  return (u, headers);
}
