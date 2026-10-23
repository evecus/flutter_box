import 'dart:convert';

/// 直播源文本解析, 对照原版 com.mobile.novabox.util.live.TxtSubscribe.
///
/// 输入三种格式, 统一归一化为同一结构:
/// ```json
/// [{"group": "分组名", "channels": [{"name": "CCTV1", "urls": ["http://..."]}]}]
/// ```
/// - JSON 数组: 原样归一化 (兼容 channels/channel 字段, 同名频道自动合并线路)
/// - M3U: `#EXTM3U` 开头, `#EXTINF` 属性行 (group-title/tvg-*/http-user-agent/catchup 等)
/// - TXT: `分组名,#genre#` 定义分组, `频道名,url1#url2` 定义频道
///
/// 全局设置行 (ua/parse/click/header/format/origin/referer/#EXTHTTP:/#EXTVLCOPT:/#KODIPROP:)
/// 会被合并进其后所有频道 (对照原版 mergeMeta 语义).
class TxtSubscribe {
  TxtSubscribe._();

  static const String defaultGroupName = '直播';
  static const String _legacyDefaultGroupName = 'Ungrouped';

  // 频道名: 取最后一个逗号后的内容 (对照原版 NAME_PATTERN ".*,(.+?)$").
  static final RegExp _namePattern = RegExp(r'.*,(.+?)$');
  static final RegExp _groupPattern = RegExp(r'group-title="(.*?)"');
  static final RegExp _tvgChnoPattern = RegExp(r'tvg-chno="(.*?)"');
  static final RegExp _tvgLogoPattern = RegExp(r'tvg-logo="(.*?)"');
  static final RegExp _tvgNamePattern = RegExp(r'tvg-name="(.*?)"');
  static final RegExp _tvgUrlPattern = RegExp(r'tvg-url="(.*?)"');
  static final RegExp _tvgIdPattern = RegExp(r'tvg-id="(.*?)"');
  static final RegExp _httpUserAgentPattern = RegExp(r'http-user-agent="(.*?)"');
  static final RegExp _catchupPattern = RegExp(r'catchup="(.*?)"');
  static final RegExp _catchupSourcePattern = RegExp(r'catchup-source="(.*?)"');
  static final RegExp _catchupReplacePattern = RegExp(r'catchup-replace="(.*?)"');

  /// 解析直播源文本为归一化分组数组.
  ///
  /// 依次尝试: JSON 数组 → M3U (`#EXTM3U`) → TXT (`#genre#).
  static List<Map<String, dynamic>> parseToJsonArray(String? str) {
    if (str == null) return <Map<String, dynamic>>[];
    str = str.trim();
    if (str.isEmpty) return <Map<String, dynamic>>[];
    try {
      final dynamic element = jsonDecode(str);
      if (element is List) return _normalizeJsonArray(element);
    } catch (_) {}
    if (str.startsWith('#EXTM3U')) return _parseM3uToJsonArray(str);
    return _parseTxtToJsonArray(str);
  }

  static List<Map<String, dynamic>> _normalizeJsonArray(List<dynamic> groups) {
    final result = <Map<String, dynamic>>[];
    for (final groupElement in groups) {
      final Map<String, dynamic> groupObj = _asObject(groupElement);
      final outGroup = <String, dynamic>{};
      var groupName = _safeJsonString(groupObj, 'group', '');
      if (groupName.isEmpty) {
        groupName = _safeJsonString(groupObj, 'name', defaultGroupName);
      }
      outGroup['group'] = normalizeGroupName(groupName);
      List<dynamic>? channels;
      final dynamic channelsValue = groupObj['channels'];
      if (channelsValue is List) {
        channels = channelsValue;
      } else {
        final dynamic channelValue = groupObj['channel'];
        if (channelValue is List) channels = channelValue;
      }
      if (channels != null) {
        for (final channelElement in channels) {
          final Map<String, dynamic> channelObj = _asObject(channelElement);
          final outChannel = <String, dynamic>{};
          _copyIfExists(channelObj, outChannel, 'name');
          _copyIfExists(channelObj, outChannel, 'urls');
          _copyIfExists(channelObj, outChannel, 'logo');
          _copyIfExists(channelObj, outChannel, 'epg');
          _copyIfExists(channelObj, outChannel, 'ua');
          _copyIfExists(channelObj, outChannel, 'click');
          _copyIfExists(channelObj, outChannel, 'format');
          _copyIfExists(channelObj, outChannel, 'origin');
          _copyIfExists(channelObj, outChannel, 'referer');
          _copyIfExists(channelObj, outChannel, 'tvg-id');
          _copyIfExists(channelObj, outChannel, 'tvg-name');
          _copyIfExists(channelObj, outChannel, 'tvg-chno');
          _copyIfExists(channelObj, outChannel, 'parse');
          _copyIfExists(channelObj, outChannel, 'header');
          _copyIfExists(channelObj, outChannel, 'catchup');
          _copyIfExists(channelObj, outChannel, 'catchup-source');
          _copyIfExists(channelObj, outChannel, 'catchup-replace');
          _addChannel(outGroup, outChannel);
        }
      }
      outGroup['channels'] ??= <dynamic>[];
      result.add(outGroup);
    }
    return result;
  }

  static void _copyIfExists(
      Map<String, dynamic> src, Map<String, dynamic> dst, String key) {
    if (src.containsKey(key)) dst[key] = src[key];
  }

  static List<Map<String, dynamic>> _parseM3uToJsonArray(String str) {
    final result = <Map<String, dynamic>>[];
    try {
      final lines = str.replaceAll('\r\n', '\n').replaceAll('\r', '').split('\n');
      Map<String, dynamic>? currentGroup;
      Map<String, dynamic>? pendingChannel;
      var pendingMeta = <String, dynamic>{};
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#EXTM3U')) {
          _mergeMeta(pendingMeta, _buildMeta(line));
          continue;
        }
        if (_isSetting(line)) {
          _mergeMeta(pendingMeta, _buildSetting(line));
          continue;
        }
        if (line.startsWith('#EXTINF') || line.contains('#EXTINF')) {
          final groupName = normalizeGroupName(_get(line, _groupPattern));
          currentGroup = _findOrCreateGroup(result, groupName);
          pendingChannel = <String, dynamic>{};
          pendingChannel['name'] = _get(line, _namePattern);
          _mergeMeta(pendingChannel, _buildMeta(line));
          _mergeMeta(pendingChannel, pendingMeta);
          pendingMeta = <String, dynamic>{};
          continue;
        }
        if (line.startsWith('#')) continue;
        currentGroup ??= _findOrCreateGroup(result, defaultGroupName);
        pendingChannel ??= <String, dynamic>{};
        // "url|header" 形式: | 后半段为请求头 (对照原版 split("\\|", 2)).
        final parts = _split2(line, '|');
        final url = parts[0].trim();
        if (!_isUrl(url)) continue;
        if (parts.length > 1) _mergeMeta(pendingMeta, _parseHeaderString(parts[1]));
        _mergeMeta(pendingChannel, pendingMeta);
        List<dynamic> urls = pendingChannel['urls'] is List
            ? (pendingChannel['urls'] as List)
            : <dynamic>[];
        if (!_containsUrl(urls, url)) urls.add(url);
        pendingChannel['urls'] = urls;
        _addChannel(currentGroup, pendingChannel);
        pendingChannel = null;
        pendingMeta = <String, dynamic>{};
      }
    } catch (_) {}
    return result;
  }

  static List<Map<String, dynamic>> _parseTxtToJsonArray(String str) {
    final result = <Map<String, dynamic>>[];
    try {
      final lines = str.replaceAll('\r\n', '\n').replaceAll('\r', '').split('\n');
      Map<String, dynamic>? currentGroup;
      var pendingMeta = <String, dynamic>{};
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#')) {
          if (_isSetting(line)) _mergeMeta(pendingMeta, _buildSetting(line));
          continue;
        }
        if (line.contains('#genre#')) {
          // "分组名_密码,#genre#" 的 _ 后半段为分组密码 (loadLives 时再拆).
          final groupName = _split2(line, ',')[0].trim();
          currentGroup = _findOrCreateGroup(result, groupName);
          pendingMeta = <String, dynamic>{};
          continue;
        }
        final split = _split2(line, ',');
        if (split.length < 2) continue;
        currentGroup ??= _findOrCreateGroup(result, defaultGroupName);
        final channel = <String, dynamic>{};
        channel['name'] = split[0].trim();
        _mergeMeta(channel, pendingMeta);
        final urls = <dynamic>[];
        for (final part in split[1].trim().split('#')) {
          final url = part.trim();
          if (_isUrl(url) && !urls.contains(url)) urls.add(url);
        }
        if (urls.isEmpty) continue;
        channel['urls'] = urls;
        _addChannel(currentGroup, channel);
        pendingMeta = <String, dynamic>{};
      }
    } catch (_) {}
    return result;
  }

  static Map<String, dynamic> _parseHeaderString(String text) {
    final wrapper = <String, dynamic>{};
    final obj = <String, dynamic>{};
    for (final param in text.split('&')) {
      if (!param.contains('=')) continue;
      final a = _split2(param, '=');
      obj[a[0].trim().replaceAll('"', '')] = a[1].trim().replaceAll('"', '');
    }
    if (obj.isNotEmpty) wrapper['header'] = obj;
    return wrapper;
  }

  static Map<String, dynamic> _findOrCreateGroup(
      List<Map<String, dynamic>> result, String name) {
    name = normalizeGroupName(name);
    for (final group in result) {
      if (name == group['group']) return group;
    }
    final group = <String, dynamic>{
      'group': name,
      'channels': <dynamic>[],
    };
    result.add(group);
    return group;
  }

  /// 空分组名 / 旧版 "Ungrouped" 归一为默认分组 "直播".
  static String normalizeGroupName(String? name) {
    if (name == null) return defaultGroupName;
    name = name.trim();
    if (name.isEmpty ||
        name.toLowerCase() == _legacyDefaultGroupName.toLowerCase()) {
      return defaultGroupName;
    }
    return name;
  }

  static void _addChannel(
      Map<String, dynamic> group, Map<String, dynamic> channel) {
    List<dynamic> channels = group['channels'] is List
        ? (group['channels'] as List)
        : <dynamic>[];
    final name = _safeJsonString(channel, 'name', '');
    Map<String, dynamic>? exists;
    if (name.isNotEmpty) exists = _findChannel(channels, name);
    if (exists == null) {
      channels.add(channel);
    } else {
      // 同名频道: 合并线路并补齐缺失字段 (对照原版 mergeChannel).
      _mergeChannel(exists, channel);
    }
    group['channels'] = channels;
  }

  static Map<String, dynamic>? _findChannel(List<dynamic> channels, String name) {
    for (final element in channels) {
      if (element is! Map) continue;
      final channel = element.cast<String, dynamic>();
      if (name == _safeJsonString(channel, 'name', '')) return channel;
    }
    return null;
  }

  static void _mergeChannel(
      Map<String, dynamic> dst, Map<String, dynamic> src) {
    _mergeUrls(dst, src);
    for (final entry in src.entries) {
      final key = entry.key;
      if (key == 'urls') continue;
      if (!dst.containsKey(key) || _isEmptyValue(dst[key])) {
        dst[key] = entry.value;
      }
    }
  }

  static void _mergeUrls(Map<String, dynamic> dst, Map<String, dynamic> src) {
    final srcUrls = src['urls'];
    if (srcUrls is! List) return;
    List<dynamic> dstUrls = dst['urls'] is List
        ? (dst['urls'] as List)
        : <dynamic>[];
    for (final element in srcUrls) {
      if (element is! String && element is! num && element is! bool) continue;
      final url = _jsonElementToString(element).trim();
      if (_isUrl(url) && !_containsUrl(dstUrls, url)) dstUrls.add(url);
    }
    dst['urls'] = dstUrls;
  }

  static bool _isEmptyValue(dynamic element) {
    if (element == null) return true;
    if (element is String) return element.trim().isEmpty;
    if (element is num || element is bool) return false;
    if (element is List) return element.isEmpty;
    if (element is Map) return element.isEmpty;
    return false;
  }

  static bool _containsUrl(List<dynamic> urls, String url) {
    for (final element in urls) {
      if (url == _jsonElementToString(element)) return true;
    }
    return false;
  }

  static void _mergeMeta(Map<String, dynamic> dst, Map<String, dynamic> src) {
    for (final entry in src.entries) {
      dst[entry.key] = entry.value;
    }
  }

  static Map<String, dynamic> _buildMeta(String line) {
    final obj = <String, dynamic>{};
    _put(obj, 'logo', _get(line, _tvgLogoPattern));
    _put(obj, 'epg', _get(line, _tvgUrlPattern));
    _put(obj, 'tvg-id', _get(line, _tvgIdPattern));
    _put(obj, 'tvg-name', _get(line, _tvgNamePattern));
    _put(obj, 'tvg-chno', _get(line, _tvgChnoPattern));
    _put(obj, 'ua', _get(line, _httpUserAgentPattern));
    final catchup = _get(line, _catchupPattern);
    final source = _get(line, _catchupSourcePattern);
    final replace = _get(line, _catchupReplacePattern);
    if (catchup.isNotEmpty || source.isNotEmpty || replace.isNotEmpty) {
      final catchupObj = <String, dynamic>{};
      _put(catchupObj, 'type', catchup);
      _put(catchupObj, 'source', source);
      _put(catchupObj, 'replace', replace);
      obj['catchup'] = catchupObj;
    }
    return obj;
  }

  static Map<String, dynamic> _buildSetting(String line) {
    final obj = <String, dynamic>{};
    if (line.startsWith('ua')) _put(obj, 'ua', _getValue(line, 'ua'));
    if (line.startsWith('parse')) _put(obj, 'parse', _getValue(line, 'parse'));
    if (line.startsWith('click')) _put(obj, 'click', _getValue(line, 'click'));
    if (line.startsWith('header')) {
      final value = _getValue(line, 'header');
      if (value.isNotEmpty) {
        try {
          final dynamic parsed = jsonDecode(value);
          if (parsed is Map) obj['header'] = parsed;
        } catch (_) {}
      }
    }
    if (line.startsWith('format')) _put(obj, 'format', _getValue(line, 'format'));
    if (line.startsWith('origin')) _put(obj, 'origin', _getValue(line, 'origin'));
    if (line.startsWith('referer')) {
      _put(obj, 'referer', _getValue(line, 'referer'));
    }
    if (line.startsWith('#EXTHTTP:')) {
      try {
        final dynamic parsed =
            jsonDecode(line.substring('#EXTHTTP:'.length).trim());
        if (parsed is Map) obj['header'] = parsed;
      } catch (_) {}
    }
    if (line.startsWith('#EXTVLCOPT:')) {
      if (line.contains('http-user-agent')) {
        _put(obj, 'ua', _getValue(line, 'http-user-agent'));
      }
      if (line.contains('http-origin')) {
        _put(obj, 'origin', _getValue(line, 'http-origin'));
      }
      if (line.contains('http-referrer')) {
        _put(obj, 'referer', _getValue(line, 'http-referrer'));
      }
    }
    if (line.startsWith('#KODIPROP:') && line.contains('manifest_type=')) {
      _put(obj, 'format', _getValue(line, 'manifest_type'));
    }
    return obj;
  }

  static bool _isSetting(String line) {
    return line.startsWith('ua') ||
        line.startsWith('parse') ||
        line.startsWith('click') ||
        line.startsWith('player') ||
        line.startsWith('header') ||
        line.startsWith('format') ||
        line.startsWith('origin') ||
        line.startsWith('referer') ||
        line.startsWith('#EXTHTTP:') ||
        line.startsWith('#EXTVLCOPT:') ||
        line.startsWith('#KODIPROP:');
  }

  static bool _isUrl(String url) {
    return url.isNotEmpty &&
        (url.startsWith('http') ||
            url.startsWith('rtp') ||
            url.startsWith('rtsp') ||
            url.startsWith('rtmp'));
  }

  static String _get(String line, RegExp pattern) {
    final match = pattern.firstMatch(line);
    if (match != null) {
      final value = match.group(1);
      if (value != null) return value.trim();
    }
    return '';
  }

  static String _getValue(String line, String key) {
    final index = line.indexOf('$key=');
    if (index < 0) return '';
    return line
        .substring(index + key.length + 1)
        .trim()
        .replaceAll('"', '');
  }

  static void _put(Map<String, dynamic> obj, String key, String value) {
    if (value.isNotEmpty) obj[key] = value;
  }

  /// 对照 DefaultConfig.safeJsonString: 对象/数组取 JSON 文本, 其余取字符串形式.
  static String _safeJsonString(
      Map<String, dynamic> obj, String key, String defaultVal) {
    try {
      if (obj.containsKey(key)) {
        final value = obj[key];
        if (value is Map || value is List) return jsonEncode(value).trim();
        return _asPrimitiveString(value).trim();
      }
      return defaultVal;
    } catch (_) {}
    return defaultVal;
  }

  static String _asPrimitiveString(dynamic value) {
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    throw StateError('not a json primitive');
  }

  static String _jsonElementToString(dynamic value) {
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    if (value is Map || value is List) return jsonEncode(value);
    return '';
  }

  static Map<String, dynamic> _asObject(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    throw StateError('not a json object');
  }

  /// 对照 Java `split(sep, 2)`: 最多切两段, 无分隔符时返回单元素列表.
  static List<String> _split2(String value, String separator) {
    final index = value.indexOf(separator);
    if (index < 0) return <String>[value];
    return <String>[
      value.substring(0, index),
      value.substring(index + separator.length),
    ];
  }
}
