import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'danmaku_settings.dart';

/// 云搜候选弹幕结果.
class DanmuSearchResult {
  final String name;
  final String url;

  /// true 表示内置接口的剧集条目 (url 指向 comment JSON, 需再转 xml);
  /// false 表示自定义接口直接返回的弹幕地址.
  final bool builtIn;

  DanmuSearchResult(this.name, this.url, {this.builtIn = false});
}

/// 弹幕搜索 API (移植自 NovaTV DanmakuApi):
///   - 内置 echo-danmaku 服务: search/episodes → comment JSON → 转 bilibili XML
///   - 自定义接口: 支持 {name}/{episode} 占位 GET, 或 POST name/episode 表单
///   - 云搜 (searchList): 返回候选列表供用户手动选择
class DanmakuApi {
  DanmakuApi._();

  static const String builtinApi = 'https://logvardanmu.konfan.cn/87654321';
  static const Duration timeout = Duration(seconds: 20);

  /// 取消标记: 每次搜索前自增, 回调里比对以丢弃过期响应.
  static int _searchSeq = 0;

  static void cancel() {
    _searchSeq++;
  }

  /// 当前生效的弹幕接口地址 (自定义优先, 否则内置).
  static String getApiUrl() {
    final s = DanmuSettings.instance;
    if (s.useDefaultApi) return builtinApi;
    if (s.customApi.isNotEmpty) return s.customApi;
    return builtinApi;
  }

  /// 设置页展示用: 未自定义时为空.
  static String getDisplayApiUrl() {
    final s = DanmuSettings.instance;
    if (s.useDefaultApi) return '';
    return s.customApi;
  }

  static bool _hasPlaceholder(String url) =>
      url.contains('{name}') || url.contains('{episode}');

  static bool _isDanmakuSearchApi(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u.endsWith('/danmaku');
  }

  static String _normalizeBaseUrl(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/87654321')) {
      u = u.substring(0, u.length - '/87654321'.length);
    }
    return u;
  }

  static String _encode(String text) => Uri.encodeComponent(text);

  /// 自动搜索弹幕: 返回弹幕内容 (bilibili XML 或可下载地址), 失败返回 null.
  static Future<String?> search(String name, String episode) async {
    final apiUrl = getApiUrl();
    if (apiUrl.isEmpty) return null;
    final seq = ++_searchSeq;
    try {
      if (_hasPlaceholder(apiUrl)) {
        final url = apiUrl
            .replaceAll('{name}', _encode(name))
            .replaceAll('{episode}', _encode(episode));
        final body = await _getString(url);
        if (seq != _searchSeq) return null;
        return _parseUrl(body);
      }
      if (_isDanmakuSearchApi(apiUrl)) {
        // 自定义检索接口: POST name/episode, 响应里取 url.
        final body = await _postForm(apiUrl, {'name': name, 'episode': episode});
        if (seq != _searchSeq) return null;
        return _parseUrl(body);
      }
      return await _searchBuiltin(apiUrl, name, episode, seq);
    } catch (_) {
      return null;
    }
  }

  /// 内置 echo-danmaku 全流程.
  static Future<String?> _searchBuiltin(
      String apiUrl, String name, String episode, int seq) async {
    final base = _normalizeBaseUrl(apiUrl);
    final epNum = _extractNumber(episode);
    // 1) search/episodes
    var url = '$base/api/v2/search/episodes?anime=${_encode(name)}';
    if (epNum > 0) url += '&episode=$epNum';
    try {
      final body = await _getString(url);
      if (seq != _searchSeq) return null;
      final match = _findEpisodeFromSearchEpisodes(body, episode);
      if (match != null && match.id.isNotEmpty) {
        return await _loadBuiltinComment(base, match.id, seq);
      }
    } catch (_) {}
    // 2) 兜底: search/anime → bangumi
    try {
      final body = await _getString('$base/api/v2/search/anime?keyword=${_encode(name)}');
      if (seq != _searchSeq) return null;
      final animeId = _findAnimeId(body);
      if (animeId.isEmpty) return null;
      final bangumi = await _getString('$base/api/v2/bangumi/$animeId');
      if (seq != _searchSeq) return null;
      final match = _findEpisode(bangumi, episode);
      if (match != null && match.id.isNotEmpty) {
        return await _loadBuiltinComment(base, match.id, seq);
      }
    } catch (_) {}
    return null;
  }

  static Future<String> _loadBuiltinComment(String base, String episodeId, int seq) async {
    final body = await _getString('$base/api/v2/comment/$episodeId?format=json');
    if (seq != _searchSeq) return '';
    return commentJsonToXml(body);
  }

  /// 云搜: 返回候选弹幕列表.
  static Future<List<DanmuSearchResult>> searchList(String name, String episode) async {
    final apiUrl = getApiUrl();
    if (apiUrl.isEmpty) return [];
    try {
      if (!_hasPlaceholder(apiUrl) && !_isDanmakuSearchApi(apiUrl)) {
        final base = _normalizeBaseUrl(apiUrl);
        final url = '$base/api/v2/search/episodes?anime=${_encode(name)}';
        final body = await _getString(url);
        return _parseBuiltinSearchList(body, base);
      }
      String body;
      if (_hasPlaceholder(apiUrl)) {
        final url = apiUrl
            .replaceAll('{name}', _encode(name))
            .replaceAll('{episode}', _encode(episode));
        body = await _getString(url);
      } else {
        body = await _postForm(apiUrl, {'name': name, 'episode': episode});
      }
      return _parseSearchList(body);
    } catch (_) {
      return [];
    }
  }

  /// 加载云搜中用户选中的条目: 内置条目需再取 comment JSON 转 xml,
  /// 自定义条目本身就是可用地址, 直接返回.
  static Future<String> loadSearchResult(DanmuSearchResult result) async {
    if (result.url.isEmpty) return '';
    if (!result.builtIn) return result.url;
    final body = await _getString(result.url);
    return commentJsonToXml(body);
  }

  // ---------------- HTTP ----------------

  static Future<String> _getString(String url) async {
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': 'novabox-flutter',
      'Accept-Encoding': 'gzip',
    }).timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}');
    }
    return _decodeBody(resp.bodyBytes);
  }

  static Future<String> _postForm(String url, Map<String, String> fields) async {
    final resp = await http
        .post(Uri.parse(url), body: fields, headers: {'User-Agent': 'novabox-flutter'})
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}');
    }
    return _decodeBody(resp.bodyBytes);
  }

  /// dart:io HttpClient 默认 autoUncompress, 但保险起见仍检测 gzip/zlib 魔数手动解压.
  static String _decodeBody(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      return utf8.decode(GZipCodec().decode(bytes));
    }
    if (bytes.length >= 2 && bytes[0] == 0x78) {
      return utf8.decode(ZLibCodec().decode(bytes));
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ---------------- 响应解析 ----------------

  /// 从响应体解析弹幕地址: JSON 数组/对象取 url 字段, 或纯文本地址.
  static String _parseUrl(String body) {
    final text = body.trim();
    if (text.isEmpty) return '';
    if (text.startsWith('[')) {
      try {
        final array = jsonDecode(text) as List<dynamic>;
        for (final item in array) {
          if (item is Map) {
            final url = (item['url'] ?? '').toString().trim();
            if (url.isNotEmpty) return url;
          }
        }
      } catch (_) {}
      return '';
    }
    if (text.startsWith('{')) {
      try {
        final obj = jsonDecode(text) as Map<String, dynamic>;
        return (obj['url'] ?? '').toString().trim();
      } catch (_) {}
      return '';
    }
    if (text.startsWith('http') || text.startsWith('file')) return text;
    return '';
  }

  static List<DanmuSearchResult> _parseSearchList(String body) {
    final results = <DanmuSearchResult>[];
    final text = body.trim();
    if (text.isEmpty) return results;
    try {
      if (text.startsWith('[')) {
        _appendSearchResults(results, jsonDecode(text) as List<dynamic>);
        return results;
      }
      if (!text.startsWith('{')) return results;
      final obj = jsonDecode(text) as Map<String, dynamic>;
      var items = obj['data'] ?? obj['list'] ?? obj['results'];
      if (items is List) {
        _appendSearchResults(results, items);
        return results;
      }
      final url = (obj['url'] ?? '').toString().trim();
      if (url.isNotEmpty) {
        final name = (obj['name'] ?? obj['title'] ?? '').toString();
        results.add(DanmuSearchResult(name, url));
      }
    } catch (_) {}
    return results;
  }

  static void _appendSearchResults(List<DanmuSearchResult> results, List<dynamic> items) {
    for (final item in items) {
      if (item is! Map) continue;
      final url = (item['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      final name = (item['name'] ?? item['title'] ?? item['episode'] ?? item['vod_name'] ?? '')
          .toString();
      results.add(DanmuSearchResult(name, url));
    }
  }

  static List<DanmuSearchResult> _parseBuiltinSearchList(String body, String base) {
    final results = <DanmuSearchResult>[];
    if (body.trim().isEmpty) return results;
    try {
      final obj = jsonDecode(body) as Map<String, dynamic>;
      _appendBuiltinResults(results, base, obj, '');
      final bangumi = obj['bangumi'];
      if (bangumi is Map) {
        final animeName = (bangumi['animeTitle'] ?? bangumi['title'] ?? bangumi['name'] ?? '')
            .toString();
        _appendBuiltinResults(results, base, bangumi, animeName);
      }
      _appendBuiltinAnimeResults(results, base, obj['animes'] ?? obj['anime'] ?? obj['data']);
    } catch (_) {}
    return results;
  }

  static void _appendBuiltinAnimeResults(List<DanmuSearchResult> results, String base, dynamic animes) {
    if (animes is! List) return;
    for (final anime in animes) {
      if (anime is! Map) continue;
      final animeName = (anime['animeTitle'] ?? anime['title'] ?? anime['name'] ?? '').toString();
      _appendBuiltinResults(results, base, anime, animeName);
      final bangumi = anime['bangumi'];
      if (bangumi is Map) {
        _appendBuiltinResults(results, base, bangumi, animeName);
      }
    }
  }

  static void _appendBuiltinResults(
      List<DanmuSearchResult> results, String base, Map<dynamic, dynamic> object, String animeName) {
    final episodes = object['episodes'];
    if (episodes is! List) return;
    for (final ep in episodes) {
      if (ep is! Map) continue;
      final id = _firstString(ep, ['episodeId', 'id']);
      if (id.isEmpty) continue;
      final epName = _firstString(ep, ['episodeTitle', 'title', 'name']);
      var name = animeName.isEmpty ? epName : '$animeName $epName';
      if (name.isEmpty) name = id;
      results.add(DanmuSearchResult(name, '$base/api/v2/comment/$id?format=json', builtIn: true));
    }
  }

  static String _findAnimeId(String body) {
    try {
      final obj = jsonDecode(body) as Map<String, dynamic>;
      var array = obj['animes'] ?? obj['anime'] ?? obj['data'];
      if (array is List && array.isNotEmpty) {
        final item = array.first;
        if (item is Map) {
          return _firstString(item, ['animeId', 'id']);
        }
      }
    } catch (_) {}
    return '';
  }

  static _EpisodeMatch? _findEpisodeFromSearchEpisodes(String body, String episode) {
    final match = _findEpisode(body, episode, allowMovieFallback: false);
    if (match != null) return match;
    return _findMovieFallback(body, episode);
  }

  static _EpisodeMatch? _findEpisode(String body, String episode,
      {bool allowMovieFallback = true}) {
    try {
      final obj = jsonDecode(body) as Map<String, dynamic>;
      final episodeList = _findEpisodeList(obj);
      if (episodeList == null || episodeList.isEmpty) return null;
      final targetNumber = _extractNumber(episode);
      _EpisodeMatch? first;
      _EpisodeMatch? firstMandarin;
      for (final item in episodeList) {
        final id = _firstString(item, ['episodeId', 'id']);
        if (id.isEmpty) continue;
        final title = _firstString(item, ['episodeTitle', 'title', 'name']);
        final number = _parseEpisodeNumber(_firstString(item, ['episodeNumber', 'number', 'sort']));
        final match = _EpisodeMatch(id, title, number);
        first ??= match;
        if (firstMandarin == null && _isMandarinTitle(title)) firstMandarin = match;
        if (episode.isNotEmpty && title.isNotEmpty && title.contains(episode)) return match;
        if (targetNumber > 0 && number == targetNumber) return match;
        if (targetNumber > 0 && _extractNumber(title) == targetNumber) return match;
      }
      if (episode.isEmpty) return first;
      return allowMovieFallback ? (firstMandarin ?? first) : null;
    } catch (_) {}
    return null;
  }

  static List<Map<dynamic, dynamic>>? _findEpisodeList(Map<dynamic, dynamic> object) {
    final episodes = object['episodes'];
    if (episodes is List) return episodes.cast<Map<dynamic, dynamic>>();
    final bangumi = object['bangumi'];
    if (bangumi is Map) {
      final eps = bangumi['episodes'];
      if (eps is List) return eps.cast<Map<dynamic, dynamic>>();
    }
    final animes = object['animes'] ?? object['anime'] ?? object['data'];
    if (animes is List) {
      for (final anime in animes) {
        if (anime is! Map) continue;
        final eps = anime['episodes'];
        if (eps is List && eps.isNotEmpty) return eps.cast<Map<dynamic, dynamic>>();
      }
    }
    return null;
  }

  static _EpisodeMatch? _findMovieFallback(String body, String episode) {
    try {
      final obj = jsonDecode(body) as Map<String, dynamic>;
      final animes = obj['animes'] ?? obj['anime'] ?? obj['data'];
      if (animes is! List) return null;
      final preferCantonese = episode.contains('粤语');
      _EpisodeMatch? firstMovie;
      for (final anime in animes) {
        if (anime is! Map) continue;
        if (!_isMovieType(anime)) continue;
        final episodes = anime['episodes'];
        if (episodes is! List) continue;
        for (final ep in episodes) {
          if (ep is! Map) continue;
          final id = _firstString(ep, ['episodeId', 'id']);
          if (id.isEmpty) continue;
          final title = _firstString(ep, ['episodeTitle', 'title', 'name']);
          final match = _EpisodeMatch(
              id, title, _parseEpisodeNumber(_firstString(ep, ['episodeNumber', 'number', 'sort'])));
          firstMovie ??= match;
          final preferred = preferCantonese ? title.contains('粤语') : _isMandarinTitle(title);
          if (preferred) return match;
        }
      }
      return firstMovie;
    } catch (_) {}
    return null;
  }

  static bool _isMovieType(Map<dynamic, dynamic> object) {
    final type = (object['type'] ?? object['typeDescription'] ?? '').toString();
    if (type == '电影') return true;
    final bangumi = object['bangumi'];
    if (bangumi is Map) {
      if ((bangumi['type'] ?? '').toString() == '电影') return true;
    }
    final animes = object['animes'] ?? object['anime'] ?? object['data'];
    if (animes is List) {
      for (final anime in animes) {
        if (anime is Map && (anime['type'] ?? '').toString() == '电影') return true;
      }
    }
    return false;
  }

  static bool _isMandarinTitle(String title) =>
      title.isNotEmpty && (title.contains('国语') || title.contains('普通话'));

  static int _parseEpisodeNumber(String value) {
    if (value.isEmpty) return -1;
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed.toInt();
    return _extractNumber(value);
  }

  static int _extractNumber(String text) {
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return -1;
    return int.tryParse(digits) ?? -1;
  }

  static String _firstString(Map<dynamic, dynamic> object, List<String> keys) {
    for (final key in keys) {
      final value = (object[key] ?? '').toString();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  // ---------------- comment JSON → bilibili XML ----------------

  /// 将内置接口的 comment JSON ({comments: [{p, m}]}) 转为 bilibili XML.
  static String commentJsonToXml(String body) {
    if (body.trim().isEmpty) return '';
    try {
      final obj = jsonDecode(body) as Map<String, dynamic>;
      var comments = obj['comments'] ?? obj['data'];
      if (comments is! List || comments.isEmpty) return '';
      final sb = StringBuffer('<i>');
      for (final item in comments) {
        if (item is! Map) continue;
        var param = (item['p'] ?? '').toString();
        var text = (item['m'] ?? '').toString();
        if (text.isEmpty) text = (item['text'] ?? '').toString();
        if (param.isEmpty || text.isEmpty) continue;
        sb.write('<d p="${_escapeXml(_normalizeDanmakuParam(param))}">${_escapeXml(text)}</d>');
      }
      sb.write('</i>');
      return sb.toString();
    } catch (_) {
      return '';
    }
  }

  /// 兼容部分接口把 color 放在 size 位 (或 color 非法) 的情况.
  static String _normalizeDanmakuParam(String param) {
    final values = param.split(',');
    if (values.length < 4) return param;
    final time = values[0];
    final type = values[1];
    var size = values[2];
    var color = values[3];
    if (_isColorValue(size)) {
      color = size;
      size = '25';
    } else if (!_isColorValue(color)) {
      color = '16777215';
    }
    return '$time,$type,$size,${_normalizeColor(color)}';
  }

  static bool _isColorValue(String value) {
    final text = value.trim();
    if (text.isEmpty) return false;
    if (text.startsWith('#')) return true;
    if (text.startsWith('0x') || text.startsWith('0X')) return true;
    final color = int.tryParse(text);
    if (color == null) return false;
    return color >= 0 && color <= 0x00ffffff;
  }

  static String _normalizeColor(String color) {
    if (color.isEmpty) return '16777215';
    final text = color.trim();
    try {
      if (text.startsWith('#')) {
        return int.parse(text.substring(1), radix: 16).toString();
      }
      if (text.startsWith('0x') || text.startsWith('0X')) {
        return int.parse(text.substring(2), radix: 16).toString();
      }
    } catch (_) {}
    return text;
  }

  static String _escapeXml(String text) {
    if (text.isEmpty) return '';
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;')
        .replaceAll('>', '&gt;')
        .replaceAll('<', '&lt;');
  }
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}

class _EpisodeMatch {
  final String id;
  final String title;
  final int number;
  _EpisodeMatch(this.id, this.title, this.number);
}
