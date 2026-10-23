import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine_channel.dart';

/// 配置线路 (对应原版 "配置地址" 列表中的一行, 来自 {"urls":[...]} 集合配置).
class ConfigLine {
  final String name;
  final String url;
  const ConfigLine(this.name, this.url);

  Map<String, String> toMap() => {'name': name, 'url': url};

  static ConfigLine? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final name = ((raw['name'] as String?) ?? '').trim();
    final url = ((raw['url'] as String?) ?? '').trim();
    if (url.isEmpty) return null;
    return ConfigLine(name.isEmpty ? url : name, url);
  }
}

/// 配置导入/解析过程中的可预期错误, 带上可读原因.
class ConfigException implements Exception {
  final String message;
  const ConfigException(this.message);
  @override
  String toString() => message;
}

class Site {
  final String key;
  final String name;
  final int type;
  final String api;
  final String ext;
  final String jar;

  const Site({
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    required this.ext,
    required this.jar,
  });

  /// 引擎 (SpiderLoader) 实际支持的源: type 0/4 = jar/csp, type 3 = js 或 csp_.
  /// 与原版 ApiConfig.getCSP 一致: 不按 type 卡死, 只要 api 非空即可路由.
  /// type 1 (xml 聚合) 与 .py 源引擎不支持, 不算可用源.
  bool get isRealSource =>
      (type == 0 || type == 3 || type == 4) && api.isNotEmpty && !api.contains('.py');

  /// 需要主 jar (config.spider) 才能工作的 csp_ 源之外的源 (自带 jar 或 js).
  bool get needsMainJar => jar.isEmpty && !(api.endsWith('.js') || api.contains('.js?'));

  String get displayName => name.isEmpty ? key : name;

  factory Site.fromMap(Map<String, dynamic> map, String base) {
    return Site(
      key: (map['key'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      type: map['type'] is int ? map['type'] as int : int.tryParse('${map['type']}') ?? 0,
      api: _abs((map['api'] as String?) ?? '', base),
      ext: _pickExt(map, base),
      jar: _abs(map['jar'] is String ? map['jar'] as String : '', base),
    );
  }

  static String _abs(String path, String base) {
    final t = path.trim();
    if (t.isEmpty || t.startsWith('http')) return t;
    if (base.isEmpty || !base.startsWith('http')) return t;
    final uri = Uri.parse(base);
    final root = '${uri.scheme}://${uri.host}';
    final dir = base.substring(0, base.lastIndexOf('/') + 1);
    final p = t.replaceAll(RegExp(r'\r|\n'), '');
    if (p.startsWith('//')) return '${uri.scheme}:$p';
    if (p.startsWith('/')) return root + p;
    if (p.startsWith('./')) return dir + p.substring(2);
    return dir + p;
  }

  /// ext 可以是: 空 / 对象 / 数组 / url 字符串 / md5。只有像远程路径的才补全。
  static String _pickExt(Map<String, dynamic> map, String base) {
    final ext = map['ext'];
    if (ext == null) return '';
    if (ext is Map || ext is List) return jsonEncode(ext);
    if (ext is! String) return '$ext';
    final s = ext.trim();
    if (s.isEmpty || s.startsWith('{') || s.startsWith('[')) return s;
    final isMd5 = RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(s);
    if (isMd5 || (!s.contains('/') && !s.startsWith('./') && !s.startsWith('../'))) return s;
    return _abs(s, base);
  }

  Map<String, String> toMap() => {
        'key': key,
        'name': displayName,
        'type': '$type',
        'api': api,
        'ext': ext,
        'jar': jar,
      };
}

/// 解析器 (对照原版 ParseBean). parse=1 的播放地址走它解析出真实流地址.
/// type 0 = WebView 嗅探; 1 = json 接口 (GET url+encode(播放地址) → {"url":...});
/// 2/3 = jar 内置 Json/Mix 解析器 (flutter_box 未加载解析 jar, 暂不可用).
class ParseBean {
  final String name;
  final String url;
  final int type;
  final String ext;

  const ParseBean({required this.name, required this.url, required this.type, this.ext = ''});

  static ParseBean? fromMap(dynamic raw, String base) {
    if (raw is! Map) return null;
    final u = ((raw['url'] as String?) ?? '').trim();
    if (u.isEmpty) return null;
    final t = raw['type'];
    return ParseBean(
      name: ((raw['name'] as String?) ?? '').trim(),
      url: Site._abs(u, base),
      type: t is int ? t : int.tryParse('$t') ?? 0,
      ext: '${raw['ext'] ?? ''}',
    );
  }
}

class Config {
  static const _prefKey = 'configUrl';
  static const _prefLinesKey = 'configLines';

  /// The currently applied config, shared across pages (首页 / 收藏 / 历史 / 换源).
  static Config? loaded;

  /// Fired whenever a config is applied (or cleared), so pages can reload.
  static final ValueNotifier<Config?> changeNotifier = ValueNotifier<Config?>(null);

  static void markLoaded(Config? config) {
    loaded = config;
    changeNotifier.value = config;
  }

  /// 拉取并应用一个配置 (URL 或直接粘贴的 JSON 文本).
  /// 设置页"更换配置/导入"与首页"线路"切换共用同一链路, 避免两处逻辑漂移.
  /// 返回 (是否成功, 面向用户的消息); 成功后 Config.loaded 已更新.
  static Future<(bool ok, String msg)> applyInput(
    String input, {
    List<ConfigLine> keepLines = const [],
  }) async {
    final text = input.trim();
    if (text.isEmpty) {
      await saveUrl('');
      await saveLines(const [], '');
      markLoaded(null);
      return (false, '配置已清除');
    }
    final config = Config(text);
    try {
      await config.fetch();
      if (config.sites.isEmpty) return (false, '配置中没有可用源');
      if (keepLines.isNotEmpty && config.lines.isEmpty) {
        config.lines = keepLines;
        config.lineSource = config.url;
      }
      final ok = await config.apply();
      if (!ok) {
        if (config.jarError.isNotEmpty) {
          return (false, '${config.jarError}\ncsp 源不可用');
        }
        return (false, '引擎初始化失败');
      }
      await saveUrl(config.url);
      await saveLines(config.lines, config.lineSource);
      markLoaded(config);
      final count = config.sites.where((s) => s.isRealSource).length;
      final lineTip = config.lines.isNotEmpty ? ', ${config.lines.length} 条线路' : '';
      final jarTip = config.jarError.isNotEmpty ? '\n${config.jarError} (已跳过)' : '';
      return (true, '成功, 已应用 $count 个源$lineTip$jarTip');
    } on ConfigException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, '载入失败: $e');
    }
  }

  String url;
  String base = '';
  final List<Site> sites = [];
  String spiderRaw = '';

  /// 主 jar 加载失败的可读原因 (空 = 未尝试或成功). 供设置页展示,
  /// 避免把"引擎整体失败"误报成"jar 失败".
  String jarError = '';

  /// 集合配置 ({"urls":[...]}) 的线路列表; 当前生效的是 [url] 对应那条.
  List<ConfigLine> lines = const [];
  String lineSource = '';

  /// 配置里的 parses 解析器列表 (原版 ApiConfig.parses). play=1 且 jx 为空时,
  /// 播放页取第一个 type 1 (json 接口) 解析器兜底.
  List<ParseBean> parses = const [];

  Config(this.url);

  static Future<String> loadUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKey) ?? '';
  }

  static Future<void> saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, url);
  }

  static Future<void> saveLines(List<ConfigLine> lines, String source) async {
    final prefs = await SharedPreferences.getInstance();
    if (lines.isEmpty || source.isEmpty) {
      await prefs.remove(_prefLinesKey);
      return;
    }
    await prefs.setString(
      _prefLinesKey,
      jsonEncode({'source': source, 'lines': lines.map((e) => e.toMap()).toList()}),
    );
  }

  /// 恢复上次保存的线路列表 (原版 HawkConfig.API_LINE_LIST 的等价物).
  static Future<List<ConfigLine>> loadLines() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefLinesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final map = jsonDecode(raw);
      if (map is Map && map['lines'] is List) {
        return (map['lines'] as List)
            .map(ConfigLine.fromMap)
            .whereType<ConfigLine>()
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  /// 原版 ApiConfig.configUrl: 缺省补 http://, 保留 ;pk; 密钥供解密使用.
  static String normalizeUrl(String input) {
    var u = input.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.contains(';pk;')) {
      final idx = u.indexOf(';pk;');
      final head = normalizeUrl(u.substring(0, idx));
      return '$head;pk;${u.substring(idx + 4).trim()}';
    }
    return 'http://$u';
  }

  static String? pkKeyOf(String input) {
    final idx = input.indexOf(';pk;');
    if (idx < 0) return null;
    final key = input.substring(idx + 4).trim();
    return key.isEmpty ? null : key;
  }

  /// 拉取并解析配置. 支持:
  /// - 远程 URL (自动补 http://) / 直接粘贴的 JSON 文本
  /// - {"urls":[...]} 多线路集合 (原版 switchApiCollectionIfNeeded: 自动切到第一条)
  /// - {"url":"..."} 单线包装跳转
  /// - 加密配置: 8位** + base64 / 2423 AES-CBC / ;pk; AES-ECB (引擎侧解密)
  /// - 整体 base64 / @ 拼接多段 base64 / 带 // 注释的轻量 JSON
  /// 失败抛 [ConfigException], 原因可读.
  Future<void> fetch() async {
    lines = const [];
    lineSource = '';
    final pk = pkKeyOf(url);
    final engineTried = <String>{};
    // 先按原始输入分流 (对照原版 configUrl: 非 http 一律补 http://;
    // 但粘贴的配置内容是文本, 不能补 scheme 再去请求):
    //   - '{'/'[' 开头 → JSON 文本
    //   - 纯 base64 长串 (无 '.'/空格, 字符集受限) → 整体 base64 配置
    //   - 其余 (含裸域名 www.xxx.net/tv) → 按原版补 http:// 走网络
    final raw = url.trim();
    final isPasted = raw.startsWith('{') ||
        raw.startsWith('[') ||
        (raw.length > 100 &&
            !raw.contains('.') &&
            !RegExp(r'\s').hasMatch(raw) &&
            RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(raw));
    var current = isPasted ? raw : normalizeUrl(raw);
    // 直接粘贴的文本不走网络; 集合/跳转目标一定是 http 地址.
    var body = isPasted ? raw : await _fetchBody(current);
    if (body == null && !isPasted) {
      // Dart http 失败 (非 ASCII 域名/证书/被墙): 引擎侧 OkHttp 兜底, 支持 IDN 中文域名.
      body = await EngineChannel.getText(current);
      if (body.isEmpty) body = null;
      engineTried.add(current);
    }
    for (var hop = 0; hop < 6; hop++) {
      if (body == null) {
        throw ConfigException('拉取配置失败: $current\n(网络错误或地址无效)');
      }
      var text = await _decodeConfigText(body, pk);
      var map = _decodeMap(text);
      if (map == null && current.startsWith('http') && engineTried.add(current)) {
        // Dart http 拿到了内容但解析不了 (IDN 域名被路由到错误页面/反爬/编码):
        // 用引擎 OkHttp 按原版 UA 再拉一次.
        final alt = await EngineChannel.getText(current);
        if (alt.isNotEmpty) {
          text = await _decodeConfigText(alt, pk);
          map = _decodeMap(text);
        }
      }
      if (map == null) {
        throw ConfigException('配置解析失败: $current\n(内容不是有效的 TVBox 配置)');
      }
      final sitesRaw = map['sites'];
      if (sitesRaw is List && sitesRaw.isNotEmpty) {
        spiderRaw = (map['spider'] as String?) ?? '';
        _parseSites(sitesRaw);
        // parses 解析器 (与 sites 同级; 缺省为空列表)
        final parsesRaw = map['parses'];
        if (parsesRaw is List) {
          final parsed = <ParseBean>[];
          for (final item in parsesRaw) {
            final bean = ParseBean.fromMap(item, base);
            if (bean != null) parsed.add(bean);
          }
          parses = parsed;
        }
        url = current;
        return;
      }
      // 多线路集合: 自动切第一条, 同时保留列表供设置页切换.
      final urlsRaw = map['urls'];
      if (urlsRaw is List && urlsRaw.isNotEmpty) {
        final parsed = <ConfigLine>[];
        for (final item in urlsRaw) {
          if (item is Map) {
            final name = ((item['name'] as String?) ?? '').trim();
            var u = ((item['url'] as String?) ?? '').trim();
            if (u.isEmpty) u = ((item['api'] as String?) ?? '').trim();
            if (u.isNotEmpty) parsed.add(ConfigLine(name.isEmpty ? u : name, normalizeUrl(u)));
          } else if (item is String && item.trim().isNotEmpty) {
            parsed.add(ConfigLine(item.trim(), normalizeUrl(item.trim())));
          }
        }
        if (parsed.isEmpty) throw const ConfigException('配置解析失败: urls 线路集合为空');
        lines = parsed;
        lineSource = current;
        current = parsed.first.url;
        body = await _fetchBody(current);
        if (body == null) {
          body = await EngineChannel.getText(current);
          if (body.isEmpty) body = null;
          engineTried.add(current);
        }
        continue;
      }
      // 单线包装: {"url": "http://..."}
      final redirect = (map['url'] as String?) ?? '';
      if (redirect.startsWith('http')) {
        current = redirect;
        body = await _fetchBody(current);
        if (body == null) {
          body = await EngineChannel.getText(current);
          if (body.isEmpty) body = null;
          engineTried.add(current);
        }
        continue;
      }
      throw const ConfigException('配置中没有可用源 (sites 为空)');
    }
    throw const ConfigException('配置跳转层级过多, 已终止 (超过 6 层)');
  }

  Future<String?> _get(String url, {bool setBase = true}) async {
    try {
      final res =
          await http.get(Uri.parse(url.trim()), headers: {'user-agent': 'okhttp/4.12.0'});
      if (res.statusCode != 200 || res.body.isEmpty) return null;
      if (setBase && url.trim().startsWith('http')) base = url.trim();
      return res.body;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetchBody(String u) async {
    base = u.trim();
    return await _get(u, setBase: false);
  }

  /// 原版 ApiConfig.FindResult: 加密配置解密 (Dart 做 base64 部分, AES 走引擎).
  Future<String> _decodeConfigText(String body, String? pk) async {
    var text = body;
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.trim();
    if (_startsWithJson(text)) return text;
    // 8 位随机字符 + ** 标记, 之后是 base64
    final m = RegExp(r'[A-Za-z0-9]{8}\*\*').firstMatch(text);
    if (m != null) {
      final decoded = _tryBase64(text.substring(m.end).replaceAll(RegExp(r'\s'), ''));
      if (decoded != null) text = decoded.trim();
    }
    final t = text.trim();
    // 2423 开头 = AES-CBC; 带 ;pk; 密钥 = AES-ECB
    if (t.startsWith('2423') || (pk != null && !_startsWithJson(t))) {
      final dec = await EngineChannel.decrypt(t, pk ?? '');
      if (dec.isNotEmpty) text = dec;
    }
    return text;
  }

  bool _startsWithJson(String text) {
    final t = text.trimLeft();
    return t.startsWith('{') || t.startsWith('[');
  }

  /// TVBox 风格的多层解析: 整体 base64 / @ 拼接的多个 base64 / 带注释的轻量 JSON.
  String extractConfig(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return trimmed;
    final packed = trimmed.replaceAll(RegExp(r'\s'), '');
    for (final piece in packed.split('@')) {
      if (piece.length < 24) continue;
      final decoded = _tryBase64(piece);
      if (decoded != null) {
        final map = _decodeMap(clean(decoded));
        if (map != null) return decoded;
      }
    }
    try {
      final decoded = _tryBase64(packed);
      if (decoded != null) {
        final map = _decodeMap(clean(decoded));
        if (map != null) return decoded;
      }
    } catch (_) {}
    return trimmed;
  }

  String? _tryBase64(String s) {
    var t = s.replaceAll('-', '+').replaceAll('_', '/');
    while (t.length % 4 != 0) {
      t += '=';
    }
    try {
      final d = utf8.decode(base64.decode(t), allowMalformed: true);
      if (d.startsWith('{') || d.startsWith('[')) return d;
    } catch (_) {}
    return null;
  }

  String clean(String body) {
    var text = body;
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.trim();
    if (text.startsWith('{') || text.startsWith('[')) return text;
    // TVBox style plain config: strip // comments but keep protocol URLs.
    final lines = <String>[];
    for (final line in text.split('\n')) {
      if (line.trimLeft().startsWith('//')) continue;
      lines.add(line.replaceAll(RegExp(r'(?<![:/\w])//.*$'), ''));
    }
    return lines.join('\n');
  }

  /// 剥离 JSON 中的 // 注释 (整行注释与行尾注释).
  /// 原版 ApiConfig.FindResult/parseJson 走 Gson, lenient 模式下 // 注释会被跳过;
  /// Dart jsonDecode 是严格解析, 遇到注释行直接抛 FormatException.
  /// 线上配置 (如饭太硬) 会用 // 注释掉个别站点行:
  ///   {"key":...},
  ///   //{"key":"播客","name":"🦊播客┃多线","type":3,...},
  ///   {"key":...},
  /// 字符串字面量内的 // (http:// 等) 必须保留, 所以按字符串状态扫描而非纯正则.
  static String stripJsonComments(String text) {
    if (!text.contains('//')) return text;
    final buf = StringBuffer();
    var inString = false;
    var escaped = false;
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (inString) {
        buf.write(c);
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        i++;
        continue;
      }
      if (c == '"') {
        inString = true;
        buf.write(c);
        i++;
        continue;
      }
      if (c == '/' && i + 1 < text.length && text[i + 1] == '/') {
        // 行注释: 跳到行尾 (保留换行符, 行号结构不塌)
        while (i < text.length && text[i] != '\n') {
          i++;
        }
        continue;
      }
      buf.write(c);
      i++;
    }
    return buf.toString();
  }

  Map<String, dynamic>? _decodeMap(String text) {
    final direct = _decodeMapOnce(text);
    if (direct != null) return direct;
    // jsonDecode 失败且文本含 //: 按原版 Gson lenient 语义剥离注释后重试一次
    // (注释行会让整份有效配置被判"内容不是有效的 TVBox 配置").
    if (!text.contains('//')) return null;
    final stripped = stripJsonComments(text);
    if (stripped == text) return null;
    return _decodeMapOnce(stripped);
  }

  Map<String, dynamic>? _decodeMapOnce(String text) {
    try {
      final t = text.startsWith('{') || text.startsWith('[') ? text : clean(extractConfig(text));
      final element = jsonDecode(t);
      if (element is Map<String, dynamic>) {
        final sites = element['sites'];
        if (sites is List && sites.isNotEmpty) return element;
        final urls = element['urls'];
        if (urls is List && urls.isNotEmpty) return element;
        final u = (element['url'] as String?) ?? '';
        if (u.isNotEmpty) return {'url': u};
        return null;
      }
      if (element is List) {
        for (final item in element) {
          if (item is Map<String, dynamic>) {
            final sites = item['sites'];
            if (sites is List && sites.isNotEmpty) return item;
            if (item['spider'] is String && (item['spider'] as String).isNotEmpty) return item;
          }
        }
        for (final item in element) {
          if (item is Map<String, dynamic>) {
            final u = (item['url'] as String?) ?? '';
            if (u.isNotEmpty) return {'url': u};
          }
        }
        return null;
      }
    } catch (_) {}
    return null;
  }

  void _parseSites(dynamic raw) {
    final found = <Site>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic> && ((item['key'] as String?)?.isNotEmpty == true)) {
          try {
            found.add(Site.fromMap(item, base));
          } catch (_) {}
        }
      }
    }
    sites..clear()..addAll(found);
  }

  /// Load the main jar and push sites to the Android engine.
  Future<bool> apply() async {
    var jarOk = true;
    if (spiderRaw.isNotEmpty) jarOk = await _loadSpiderJar(spiderRaw);
    final realSites = sites.where((s) => s.isRealSource).map((e) => e.toMap()).toList();
    if (realSites.isEmpty) return false;
    final loaded = await EngineChannel.loadSites(realSites);
    // jar 加载失败时, 只要存在不依赖主 jar 的源 (自带 jar 的 csp 或 js), 仍然可用.
    return loaded && (jarOk || realSites.any((e) => !_needsMainJar(e)));
  }

  static bool _needsMainJar(Map<String, String> site) {
    final api = site['api'] ?? '';
    final jar = site['jar'] ?? '';
    return jar.isEmpty && !(api.endsWith('.js') || api.contains('.js?'));
  }

  /// 从 spider 字段提取主 jar 地址.
  /// raw 形如 "url;md5;xxx" / "url1;url2" / "img+url;md5;xxx" / "./spider.jar".
  /// 注意: 不能按扩展名过滤——现代配置常把 jar 伪装成 .jpg 等后缀
  /// (实测 9280.kstore.vip 的 spider 就是 .jpg URL, 实际内容是带
  /// classes.dex 的 APK, md5 校验一致), 按 ".jar" 过滤会全部误杀.
  /// img+ 前缀 (对照原版 loadJar 的 isJarInImg): jar 藏在图片里,
  /// 响应体是图片 + 8位随机** + base64, 下载后要再提取.
  static String spiderJarUrl(String raw, String base) {
    String? jarUrl;
    for (final part in raw.split(';')) {
      var t = part.trim();
      if (t.isEmpty) continue;
      if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(t)) continue; // md5 段
      if (t.toLowerCase() == 'md5') continue; // 分隔符段
      if (t.startsWith(spiderJarInImgPrefix)) t = t.substring(4); // img+
      jarUrl ??= _absPath(t, base);
      if (jarUrl.startsWith('http')) break;
    }
    final url = jarUrl ?? '';
    if (url.isEmpty || !url.startsWith('http')) return '';
    return url;
  }

  /// 原版 loadJar 的 img+ 前缀常量: 标记 spider 是"图片里藏 jar".
  static const spiderJarInImgPrefix = 'img+';

  /// spider 字段是否带 img+ 前缀 (jar 藏在图片里, 需 getImgJar 提取).
  static bool spiderJarInImg(String raw) =>
      raw.trim().startsWith(spiderJarInImgPrefix);

  /// 从 spider 字段提取 md5 校验值 ("url;md5;<32hex>"), 没有则返回 null.
  static String? spiderJarMd5(String raw) {
    final idx = raw.indexOf(';md5;');
    if (idx < 0) return null;
    final rest = raw.substring(idx + 5).trim();
    if (rest.isEmpty) return null;
    final tok = rest.split(';').first.trim();
    return RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(tok) ? tok.toLowerCase() : null;
  }

  Future<bool> _loadSpiderJar(String raw) async {
    jarError = '';
    final url = spiderJarUrl(raw, base);
    if (url.isEmpty) {
      jarError = 'spider 字段无可加载的 jar 地址';
      return false;
    }
    final expectMd5 = spiderJarMd5(raw);
    final jarInImg = spiderJarInImg(raw);
    try {
      // documents 目录: path_provider 全平台全版本支持
      // (getApplicationSupportDirectory 在旧版 Android 端不可用).
      final support = (await getApplicationDocumentsDirectory()).path;
      final file = File('$support/main_${_md5(url)}.jar');
      // 最多两轮: 下载 (Dart http → 引擎 OkHttp 兜底) → 校验, 失败重拉一次
      // (对照原版 loadJar 的 LOAD_JAR_MAX_RETRY=1 retryLoad).
      var ok = false;
      String? dlErr;
      for (var attempt = 0; attempt < 2 && !ok; attempt++) {
        // 无论哪一轮, 写文件前先删旧文件: 上次成功加载后 jar 被 Kotlin 侧
        // 置为只读 (Android 14+ DCL 要求), writeAsBytes 写在只读文件上会失败.
        if (file.existsSync()) file.deleteSync();
        try {
          final res = await http
              .get(Uri.parse(url), headers: {'user-agent': 'okhttp/4.12.0'})
              .timeout(const Duration(seconds: 60));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            final bytes =
                jarInImg ? extractJarFromImage(res.bodyBytes) : res.bodyBytes;
            if (bytes == null || bytes.isEmpty) {
              dlErr = jarInImg ? 'img+ 图片中未找到有效 jar' : '响应体为空';
            } else {
              await file.writeAsBytes(bytes, flush: true);
              ok = true;
            }
          } else {
            dlErr = 'HTTP ${res.statusCode}';
          }
        } catch (e) {
          dlErr = '$e';
        }
        if (!ok) {
          // Dart http 失败 (中文域名/超时等): 走引擎 OkHttp 下载, 它支持 IDN.
          try {
            if (await EngineChannel.download(url, file.path)) {
              ok = true;
              if (jarInImg) {
                // 引擎下载的是原始图片字节, img+ 场景要提取后再写回.
                final bytes = extractJarFromImage(await file.readAsBytes());
                if (bytes == null || bytes.isEmpty) {
                  ok = false;
                  dlErr = 'img+ 图片中未找到有效 jar';
                } else {
                  await file.writeAsBytes(bytes, flush: true);
                }
              }
            }
          } catch (e) {
            dlErr = '引擎下载失败: $e';
          }
        }
        // 配置带了 md5 就校验 (原版 loadJar 对缓存做同样校验): 运营商劫持 /
        // CDN 错误页会返回 200 + HTML, 不校验的话错误内容会被当 jar 加载.
        if (ok && expectMd5 != null) {
          final got = md5Hex(await file.readAsBytes());
          if (got != expectMd5) {
            ok = false;
            dlErr = 'md5 校验失败 (期望 $expectMd5, 实际 $got)';
          }
        }
      }
      if (!ok || !file.existsSync() || file.lengthSync() == 0) {
        jarError = 'jar 下载失败: $url${dlErr == null ? '' : ' ($dlErr)'}';
        return false;
      }
      // 内容魔数预检: 合法 jar 是 zip (PK) 或裸 dex. 不预检的话 HTML 错误页
      // 会进 DexClassLoader, 报出误导性的"DexClassLoader 失败".
      if (!_isValidJarFile(file)) {
        jarError = 'jar 内容无效 (非 APK/dex): $url';
        return false;
      }
      final loadErr = await EngineChannel.loadMainJar(file.path);
      if (loadErr.isNotEmpty) {
        jarError = '引擎加载 jar 失败: $url ($loadErr)';
        return false;
      }
      return true;
    } catch (e) {
      // 典型: 存储目录不可用 / 插件未注册.
      jarError = 'jar 加载异常: $e';
      return false;
    }
  }

  /// 原版 getImgJar: img+ 的 spider 响应是图片, jar 是 EOI 之后
  /// "8位随机字符** + base64" 的那一段, 提取出来才是真正的 jar.
  static List<int>? extractJarFromImage(List<int> body) {
    final text = latin1.decode(body, allowInvalid: true);
    final m = RegExp(r'[A-Za-z0-9]{8}\*\*').firstMatch(text);
    if (m == null) return null;
    var b64 = text.substring(m.end).replaceAll(RegExp(r'\s'), '');
    // 只保留 base64 字母表 (Android Base64.DEFAULT 之外原版也没有此宽容度,
    // 但图片尾巴可能带垃圾字符, 剥掉才能解出完整 dex).
    b64 = b64.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    // 长度下限只排掉短垃圾 (真实 dex/jar 的 base64 远长于此);
    // 内容是否合法由加载前的 PK/dex 魔数预检负责.
    if (b64.length < 12) return null;
    try {
      return base64.decode(b64);
    } catch (_) {
      return null;
    }
  }

  /// 有效 jar 文件: zip/apk (PK) 或裸 dex (dex\n), 前 4 字节判定.
  static bool _isValidJarFile(File file) {
    try {
      final raf = file.openSync();
      try {
        final head = raf.readSync(4);
        if (head.length < 4) return false;
        if (head[0] == 0x50 && head[1] == 0x4b) return true; // PK (zip/apk)
        if (head[0] == 0x64 && head[1] == 0x65 && head[2] == 0x78) {
          return true; // dex
        }
        return false;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// 纯 Dart MD5 (RFC 1321), 用于校验配置下发的 jar md5, 不引三方依赖.
  /// 测试向量: '' → d41d8cd98f00b204e9800998ecf8427e,
  /// 'abc' → 900150983cd24fb0d6963f7d28e17f72.
  static String md5Hex(List<int> message) {
    const k = <int>[
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, //
      0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501, //
      0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, //
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, //
      0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, //
      0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8, //
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, //
      0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, //
      0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, //
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, //
      0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, //
      0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, //
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, //
      0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1, //
      0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, //
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];
    const s = <int>[
      7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

    int rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xFFFFFFFF;

    // padding: 原始数据 + 0x80 + 0x00... + 8 字节 little-endian 位长
    final bitLen = message.length * 8;
    final padded = <int>[...message, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    for (var i = 0; i < 8; i++) {
      padded.add((bitLen >>> (8 * i)) & 0xFF);
    }

    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      final m = List<int>.filled(16, 0);
      for (var j = 0; j < 16; j++) {
        m[j] = padded[chunk + j * 4] |
            (padded[chunk + j * 4 + 1] << 8) |
            (padded[chunk + j * 4 + 2] << 16) |
            (padded[chunk + j * 4 + 3] << 24);
      }
      var a = a0, b = b0, c = c0, d = d0;
      for (var i = 0; i < 64; i++) {
        int f, g;
        if (i < 16) {
          f = (b & c) | ((~b & 0xFFFFFFFF) & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | ((~d & 0xFFFFFFFF) & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | ((~d & 0xFFFFFFFF)));
          g = (7 * i) % 16;
        }
        f = (f + a + k[i] + m[g]) & 0xFFFFFFFF;
        a = d;
        d = c;
        c = b;
        b = (b + rotl(f, s[i])) & 0xFFFFFFFF;
      }
      a0 = (a0 + a) & 0xFFFFFFFF;
      b0 = (b0 + b) & 0xFFFFFFFF;
      c0 = (c0 + c) & 0xFFFFFFFF;
      d0 = (d0 + d) & 0xFFFFFFFF;
    }

    String le(int v) {
      var out = '';
      for (var i = 0; i < 4; i++) {
        out += ((v >>> (8 * i)) & 0xFF).toRadixString(16).padLeft(2, '0');
      }
      return out;
    }

    return '${le(a0)}${le(b0)}${le(c0)}${le(d0)}';
  }

  static String _md5(String s) {
    // 仅用于生成稳定文件名, 不需要密码学强度.
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static String _absPath(String path, String base) {
    final t = path.trim().replaceAll(RegExp(r'\r|\n'), '');
    if (t.startsWith('http')) return t;
    if (base.isEmpty || !base.startsWith('http')) return t;
    return Site._abs(t, base);
  }
}
