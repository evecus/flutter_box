import 'dart:convert';

import '../config/config.dart';
import '../engine/engine_channel.dart';
import 'spider_data.dart';

const String kDefaultHttpUa = 'okhttp/4.12.0';

class PlayInfo {
  final String url;
  final Map<String, String> headers;

  const PlayInfo(this.url, this.headers);
}

/// M2: full play chain resolution for js/jar sources.
///  - direct url
///  - proxy://do=js&... (js spider own proxy, muxed through local server)
///  - parse == 1 + jx fallback
///  - headers from spider playerContent (UA / Referer / etc.)
class PlayResolver {
  static Future<PlayInfo?> resolve(Site site, String flag, String id) async {
    try {
      final json = await SpiderData.play(site.key, flag, id);
      if (json.isEmpty) return null;
      var url = (json['url'] as String?) ?? '';

      final proxyAddress = await EngineChannel.proxyUrl(true);
      final serverAddress = proxyAddress.contains('/proxy')
          ? proxyAddress.substring(0, proxyAddress.indexOf('/proxy'))
          : '';

      // js spider own proxy pass-through (proxy://do=js&...)
      // 原版 DefaultConfig.checkReplaceProxy: proxy:// → http://127.0.0.1:9978/proxy?
      // 引擎未就绪时 serverAddress 为空, 此时拼出来的是相对地址必然转圈, 直接判失败.
      if (url.startsWith('proxy://')) {
        if (serverAddress.isEmpty) return null;
        url = '$serverAddress/proxy?${url.substring('proxy://'.length)}';
      }

      // parse@jx chain
      if (!url.startsWith('http')) {
        final jx = (json['jx'] as String?) ?? '';
        final parse = json['parse'];
        if (jx.startsWith('http') && (parse == 1 || parse == true)) {
          url = jx;
        } else if (serverAddress.isNotEmpty && url.isNotEmpty) {
          // relative / pseudo-protocol url -> js own proxy
          url = '$serverAddress/proxy?do=js&siteType=${site.type}'
              '&siteKey=${Uri.encodeComponent(site.key)}'
              '&url=${Uri.encodeComponent(url)}';
        }
      }

      if (!url.startsWith('http')) return null;

      final headers = _headerMap(json);
      if (headers['User-Agent'] == null && headers['user-agent'] == null) {
        headers['User-Agent'] = kDefaultHttpUa;
      }
      return PlayInfo(url, headers);
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _headerMap(Map<String, dynamic> json) {
    final out = <String, String>{};
    dynamic header = json['header'];
    if (header is String && header.isNotEmpty) {
      try {
        final decoded = _decodeJson(header);
        if (decoded != null) {
          header = decoded;
        } else {
          // "k1=v1;k2=v2" blob
          for (final pair in header.split(';')) {
            final eq = pair.indexOf('=');
            if (eq > 0) out[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
          }
          return out;
        }
      } catch (_) {
        return out;
      }
    }
    if (header is Map) {
      for (final entry in header.entries) {
        final v = entry.value;
        if (v is Map && v.isNotEmpty) {
          for (final e2 in v.entries) {
            out['${e2.key}'] = '${e2.value}';
          }
        } else {
          out['${entry.key}'] = '$v';
        }
      }
    }
    return out;
  }

  static Map<String, dynamic>? _decodeJson(String text) {
    var t = text.trim();
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final parsed = jsonDecode(t.substring(start, end + 1));
      if (parsed is Map<String, dynamic>) return parsed;
    } catch (_) {}
    return null;
  }
}
