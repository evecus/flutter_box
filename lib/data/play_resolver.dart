import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/config.dart';
import '../engine/engine_channel.dart';
import 'spider_data.dart';

const String kDefaultHttpUa = 'okhttp/4.12.0';

class PlayInfo {
  final String url;
  final Map<String, String> headers;

  const PlayInfo(this.url, this.headers);
}

/// 播放链路解析结果的原因码: resolve 返回 null 时告诉播放页卡在哪一步,
/// 错误信息才能可读 (原版 PlayActivity 按 parse/jx/嗅探分支给不同提示).
enum PlayFail {
  /// playerContent 返回空 / 异常
  empty,
  /// 播放地址是网页地址且 parse=1, 需要解析但配置里没有可用的 jx/parses
  needParse,
  /// 本地代理服务不可用 (proxy:// 改写缺 serverAddress)
  noProxy,
}

class PlayResult {
  final PlayInfo? info;
  final PlayFail? fail;

  const PlayResult(this.info, this.fail);
}

/// M2: full play chain resolution for js/jar sources.
///  - direct url
///  - proxy://do=js&... (js spider own proxy, muxed through local server)
///  - normalize (对照原版 SourceViewModel.normalizePlayerResult):
///      * url 为数组 "[...]" → 取首元素
///      * video:// 前缀剥离 + parse=1
///      * proxy:// 改写本地代理 + parse=0
///      * // 开头补 https:
///  - parse == 1 + jx fallback (原版 PlayActivity.doParse):
///      * jx 有值 → GET jx + URLEncoder.encode(url) → 返回 json 的 url 字段
///      * jx 空 → 配置 parses 里第一个 type 1 解析器兜底
///  - headers from spider playerContent (UA / Referer / etc.)
class PlayResolver {
  static Future<PlayResult> resolve(Site site, String flag, String id) async {
    try {
      final json = await SpiderData.play(site.key, flag, id);
      if (json.isEmpty) return const PlayResult(null, PlayFail.empty);
      // 排障日志: 爬虫 playerContent 原始返回 (转圈问题定位的关键一环)
      debugPrint('echo-play playerContent key=${site.key} flag=$flag -> $json');

      // 1. normalize (对照原版 normalizePlayerResult)
      var url = _firstUrl(json['url']);
      var parse = json['parse'] == 1 || json['parse'] == true || json['parse'] == '1';
      if (url.startsWith('video://')) {
        url = url.substring('video://'.length);
        parse = true;
      }
      if (url.startsWith('//')) url = 'https:$url';

      final proxyAddress = await EngineChannel.proxyUrl(true);
      final serverAddress = proxyAddress.contains('/proxy')
          ? proxyAddress.substring(0, proxyAddress.indexOf('/proxy'))
          : '';

      // proxy:// → 本地代理 (瓜子等 jar 源的真实拉流入口), 必定是可直接播放的流
      if (url.startsWith('proxy://')) {
        if (serverAddress.isEmpty) return const PlayResult(null, PlayFail.noProxy);
        url = '$serverAddress/proxy?${url.substring('proxy://'.length)}';
        parse = false;
      }

      // 2. parse=1 (网页地址) → 解析链; 或 url 非 http (伪协议) → js 自己的代理
      if (parse || !url.startsWith('http')) {
        final jx = (json['jx'] as String?) ?? '';
        if (jx.startsWith('http')) {
          final parsed = await _jxParse(jx, url.isNotEmpty ? url : id);
          if (parsed != null) {
            url = parsed;
            parse = false;
          }
        } else if (url.isNotEmpty && serverAddress.isNotEmpty && !url.startsWith('http')) {
          // relative / pseudo-protocol url -> js own proxy
          url = '$serverAddress/proxy?do=js&siteType=${site.type}'
              '&siteKey=${Uri.encodeComponent(site.key)}'
              '&url=${Uri.encodeComponent(url)}';
          parse = false;
        }
      }

      // 3. 仍是网页地址且 parse=1 → 配置里的 parses 兜底 (原版 initParse 取第一个)
      if (parse && url.startsWith('http')) {
        final cfg = Config.loaded;
        final jx = cfg?.parses
                .where((p) => p.type == 1 && p.url.startsWith('http'))
                .map((p) => p.url)
                .firstWhere((_) => true, orElse: () => '') ??
            '';
        if (jx.isNotEmpty) {
          final parsed = await _jxParse(jx, url);
          if (parsed != null) {
            url = parsed;
            parse = false;
          }
        }
      }

      if (parse || !url.startsWith('http')) {
        return const PlayResult(null, PlayFail.needParse);
      }

      final headers = _headerMap(json);
      if (headers['User-Agent'] == null && headers['user-agent'] == null) {
        headers['User-Agent'] = kDefaultHttpUa;
      }
      return PlayResult(PlayInfo(url, headers), null);
    } catch (e) {
      debugPrint('echo-play resolve error key=${site.key}: $e');
      return const PlayResult(null, PlayFail.empty);
    }
  }

  /// 原版 normalizePlayerResult: url 字段可能是 "[...]" 数组文本或多线路数组,
  /// 一律取首元素.
  static String _firstUrl(dynamic raw) {
    if (raw is List) {
      for (final item in raw) {
        final s = '$item'.trim();
        if (s.isNotEmpty) return s;
      }
      return '';
    }
    if (raw is! String) return '';
    final t = raw.trim();
    if (t.startsWith('[') && t.endsWith(']')) {
      try {
        final decoded = jsonDecode(t);
        if (decoded is List) {
          for (final item in decoded) {
            final s = '$item'.trim();
            if (s.isNotEmpty) return s;
          }
        }
      } catch (_) {}
      // 解析失败的数组文本按普通字符串继续走 (可能是形如 "[xxx]" 的伪协议)
    }
    return t;
  }

  /// 原版 doParse type 1 (json jx): GET jxUrl + URLEncoder.encode(playUrl),
  /// 响应 json 的 url 字段即真实播放地址.
  static Future<String?> _jxParse(String jx, String playUrl) async {
    try {
      final target = '$jx${Uri.encodeComponent(playUrl)}';
      debugPrint('echo-play jx-parse GET $target');
      final res = await http
          .get(Uri.parse(target), headers: {'user-agent': kDefaultHttpUa})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final map = jsonDecode(utf8.decode(res.bodyBytes));
      if (map is Map) {
        final u = (map['url'] as String?) ?? '';
        if (u.startsWith('http')) return u;
      }
      return null;
    } catch (e) {
      debugPrint('echo-play jx-parse error: $e');
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
