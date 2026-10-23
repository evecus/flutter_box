import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novabox_flutter/config/config.dart';

/// 本地 HTTP 服务器, 模拟各种 TVBox 配置响应.
class _MockServer {
  final HttpServer server;
  final Map<String, String> routes;
  final Map<String, List<int>> rawRoutes;
  final ContentType rawContentType;

  _MockServer._(this.server, this.routes,
      [this.rawRoutes = const {}, ContentType? rawContentType])
      : rawContentType = rawContentType ?? ContentType('application', 'octet-stream');

  static Future<_MockServer> start(Map<String, String> routes) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final mock = _MockServer._(server, routes);
    server.listen((req) async {
      final body = routes[req.uri.path];
      if (body == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
      await req.response.close();
    });
    return mock;
  }

  /// 二进制响应 (image/x-ms-bmp 等无 charset 的 content-type),
  /// 用于模拟饭太硬线上 "JPEG + 尾部 base64 配置" 的真实响应.
  /// 不传 contentType 时按 application/octet-stream 处理.
  static Future<_MockServer> startRaw(Map<String, List<int>> routes,
      {ContentType? contentType}) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final mock = _MockServer._(server, {}, routes, contentType);
    server.listen((req) async {
      final body = routes[req.uri.path];
      if (body == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = mock.rawContentType;
      req.response.add(body);
      await req.response.close();
    });
    return mock;
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  Future<void> close() => server.close(force: true);
}

const _sitesJson = '''
{
  "spider": "http://example.com/spider.jar;md5;0123456789abcdef0123456789abcdef",
  "sites": [
    {"key": "csp1", "name": "豆瓣", "type": 3, "api": "csp_NewDouBanGuard"},
    {"key": "js1", "name": "泥巴", "type": 3, "api": "https://example.com/niba.js"},
    {"key": "xml1", "name": "XML 源", "type": 1, "api": "http://example.com/x.xml"},
    {"key": "py1", "name": "PY 源", "type": 3, "api": "http://example.com/a.py"}
  ]
}
''';

void main() {
  group('Site.isRealSource', () {
    Site site(Map<String, dynamic> map) =>
        Site.fromMap(map.cast<String, dynamic>(), '');

    test('type 3 + csp_ 算可用源 (旧实现会误杀)', () {
      expect(site({'key': 'a', 'type': 3, 'api': 'csp_XXX'}).isRealSource, true);
      expect(site({'key': 'a', 'type': '3', 'api': 'csp_XXX'}).isRealSource, true);
    });

    test('type 0/4 + csp_ 与 type 3 + .js 算可用源', () {
      expect(site({'key': 'a', 'type': 0, 'api': 'csp_X'}).isRealSource, true);
      expect(site({'key': 'a', 'type': 4, 'api': 'csp_X'}).isRealSource, true);
      expect(site({'key': 'a', 'type': 3, 'api': 'https://x.com/a.js'}).isRealSource, true);
    });

    test('type 1 (xml) 与 .py 源不算可用源', () {
      expect(site({'key': 'a', 'type': 1, 'api': 'http://x/a.xml'}).isRealSource, false);
      expect(site({'key': 'a', 'type': 3, 'api': 'http://x/a.py'}).isRealSource, false);
      expect(site({'key': 'a', 'type': 3, 'api': ''}).isRealSource, false);
    });

    test('name 缺省回退 key', () {
      expect(site({'key': 'k', 'type': 3, 'api': 'csp_X'}).displayName, 'k');
    });
  });

  group('Config.fetch', () {
    test('直接粘贴 JSON 文本 (不走网络)', () async {
      final config = Config(_sitesJson);
      await config.fetch();
      expect(config.sites.length, 4);
      expect(config.spiderRaw.startsWith('http://example.com/spider.jar'), true);
      final real = config.sites.where((s) => s.isRealSource).toList();
      expect(real.length, 2); // 排除 xml 与 py
      expect(real.map((s) => s.key).toSet(), {'csp1', 'js1'});
    });

    test('远程普通配置', () async {
      final s = await _MockServer.start({'/tv.json': _sitesJson});
      final config = Config(s.url('/tv.json'));
      await config.fetch();
      expect(config.sites.length, 4);
      expect(config.url, s.url('/tv.json'));
      await s.close();
    });

    test('{"urls":[...]} 多线路集合: 自动切第一条并保留线路列表', () async {
      final s = await _MockServer.start({
        '/repo.json': '{}', // 稍后用真实端口重写
        '/a.json': _sitesJson,
        '/b.json': '{"sites":[{"key":"only","name":"B源","type":3,"api":"csp_B"}]}',
      });
      final port = s.server.port;
      s.routes['/repo.json'] = jsonEncode({
        'urls': [
          {'name': '线路A', 'url': 'http://127.0.0.1:$port/a.json'},
          {'name': '线路B', 'url': 'http://127.0.0.1:$port/b.json'},
          {'name': '无地址'},
        ]
      });
      final config = Config(s.url('/repo.json'));
      await config.fetch();
      expect(config.lines.length, 2);
      expect(config.lines.first.name, '线路A');
      expect(config.lines.first.url, 'http://127.0.0.1:$port/a.json');
      expect(config.url, 'http://127.0.0.1:$port/a.json');
      expect(config.sites.length, 4); // 第一条线路的内容
      expect(config.lineSource, s.url('/repo.json'));
      await s.close();
    });

    test('{"url": "..."} 单线包装跳转', () async {
      final s = await _MockServer.start({
        '/wrap.json': '{}',
        '/inner.json': _sitesJson,
      });
      s.routes['/wrap.json'] = jsonEncode({'url': s.url('/inner.json')});
      final config = Config(s.url('/wrap.json'));
      await config.fetch();
      expect(config.sites.length, 4);
      expect(config.url, s.url('/inner.json'));
      await s.close();
    });

    test('整体 base64 编码的配置', () async {
      final s = await _MockServer.start({
        '/b64.json': base64.encode(utf8.encode(_sitesJson)),
      });
      final config = Config(s.url('/b64.json'));
      await config.fetch();
      expect(config.sites.length, 4);
      await s.close();
    });

    test('8位** 标记 + base64 的加密配置', () async {
      final s = await _MockServer.start({
        '/enc.json': 'a1b2c3d4**${base64.encode(utf8.encode(_sitesJson))}',
      });
      final config = Config(s.url('/enc.json'));
      await config.fetch();
      expect(config.sites.length, 4);
      await s.close();
    });

    test('不可解析内容抛 ConfigException', () async {
      final s = await _MockServer.start({'/bad.json': '<html>not a config</html>'});
      final config = Config(s.url('/bad.json'));
      await expectLater(config.fetch(), throwsA(isA<ConfigException>()));
      await s.close();
    });

    test('拉取失败抛 ConfigException', () async {
      final config = Config('http://127.0.0.1:1/nothing.json');
      await expectLater(config.fetch(), throwsA(isA<ConfigException>()));
    });
  });

  group('// 注释配置 (饭太硬线上格式)', () {
    // 原版 Gson lenient 会跳过 // 注释; Dart jsonDecode 严格会抛异常.
    // 线上配置用 // 注释掉个别站点行, 直接解析会报"内容不是有效的 TVBox 配置".
    const _commentedJson = '''
{
  "spider": "http://example.com/spider.jar;md5;0123456789abcdef0123456789abcdef",
  "sites": [
    {"key": "a1", "name": "正常源", "type": 3, "api": "csp_A"},
    //{"key": "b1", "name": "被注释掉的源", "type": 3, "api": "csp_B"},
    {"key": "c1", "name": "另一个源", "type": 3, "api": "csp_C"}, // 行尾注释
    {"key": "d1", "name": "带URL", "type": 3, "api": "csp_D", "ext": "https://x.com/e.json"}
  ]
}
''';

    test('整行 // 注释与行尾注释都能解析', () async {
      final config = Config(_commentedJson);
      await config.fetch();
      expect(config.sites.length, 3);
      expect(config.sites.map((s) => s.key).toSet(), {'a1', 'c1', 'd1'});
    });

    test('字符串内的 // (http://) 不被当成注释', () async {
      final config = Config(_commentedJson);
      await config.fetch();
      final d1 = config.sites.firstWhere((s) => s.key == 'd1');
      expect(d1.ext, 'https://x.com/e.json');
    });

    test('stripJsonComments: 保留字符串内 //, 剥离注释', () {
      expect(
        Config.stripJsonComments('{"a":"http://x.com"}'),
        '{"a":"http://x.com"}',
      );
      expect(
        Config.stripJsonComments('{\n//comment\n"a":1, // tail\n"b":2}'),
        '{\n\n"a":1, \n"b":2}',
      );
      expect(
        Config.stripJsonComments('{"a":"含//转义与\\"引号"}'),
        '{"a":"含//转义与\\"引号"}',
      );
      // 无注释文本原样返回 (同一对象语义, 快速路径不进入重试)
      const plain = '{"a":1}';
      expect(Config.stripJsonComments(plain), same(plain));
    });

    test('饭太硬线上抓包: JPEG 图片尾部藏 base64 配置 (真实响应字节)', () async {
      final raw = File('test/fixtures/fantaihard_image.bin').readAsBytesSync();
      final s = await _MockServer.startRaw({
        '/tv': raw,
      }, contentType: ContentType('image', 'x-ms-bmp'));
      final config = Config(s.url('/tv'));
      await config.fetch();
      expect(config.sites.length, greaterThan(0));
      // 线上配置的 spider 也是 img+ 之外的伪装 jar (.jpg URL)
      expect(config.spiderRaw, startsWith('http'));
      await s.close();
    });
  });

  group('URL 规范化', () {
    test('缺省补 http://', () {
      expect(Config.normalizeUrl('www.example.com/tv'), 'http://www.example.com/tv');
      expect(Config.normalizeUrl('https://a.com/b'), 'https://a.com/b');
    });

    test('保留 ;pk; 密钥', () {
      expect(Config.normalizeUrl('a.com/tv;pk;mykey'), 'http://a.com/tv;pk;mykey');
      expect(Config.pkKeyOf('http://a.com/tv;pk;mykey'), 'mykey');
      expect(Config.pkKeyOf('http://a.com/tv'), null);
    });
  });

  group('spiderJarUrl (主 jar 地址提取)', () {
    test('标准 url;md5;校验值', () {
      expect(
        Config.spiderJarUrl(
            'http://a.com/spider.jar;md5;0123456789abcdef0123456789abcdef', ''),
        'http://a.com/spider.jar',
      );
    });

    test('.jpg 等伪装后缀的 jar 不能误杀 (实测 9280.kstore.vip 配置)', () {
      // 该 URL 实际内容是带 classes.dex 的 APK, md5 校验一致.
      expect(
        Config.spiderJarUrl(
            'http://oss4liview.moji.com/thd_file/2026/10/20/a665.jpg;md5;12e821fd4c608270b019feb736c469dd',
            ''),
        'http://oss4liview.moji.com/thd_file/2026/10/20/a665.jpg',
      );
    });

    test('多段 url1;url2 取第一段', () {
      expect(Config.spiderJarUrl('http://a.com/1.jar;http://b.com/2.jar', ''),
          'http://a.com/1.jar');
    });

    test('相对路径按 base 补全', () {
      expect(Config.spiderJarUrl('./spider.jar', 'http://a.com/dir/tv.json'),
          'http://a.com/dir/spider.jar');
    });

    test('空/非 http 返回空串', () {
      expect(Config.spiderJarUrl('', ''), '');
      expect(Config.spiderJarUrl('md5', ''), '');
      expect(Config.spiderJarUrl('0123456789abcdef0123456789abcdef', ''), '');
    });

    test('img+ 前缀: 剥离标记后取地址 (原版 isJarInImg)', () {
      expect(
        Config.spiderJarUrl(
            'img+http://a.com/pic.jpg;md5;0123456789abcdef0123456789abcdef', ''),
        'http://a.com/pic.jpg',
      );
      expect(
        Config.spiderJarInImg(
            'img+http://a.com/pic.jpg;md5;0123456789abcdef0123456789abcdef'),
        true,
      );
      expect(
        Config.spiderJarInImg(
            'http://oss4liview.moji.com/x.jpg;md5;12e821fd4c608270b019feb736c469dd'),
        false,
      );
    });
  });

  group('spiderJarMd5 (主 jar md5 提取)', () {
    test('url;md5;<32hex> 取校验值', () {
      expect(
        Config.spiderJarMd5(
            'http://a.com/x.jar;md5;12e821fd4c608270b019feb736c469dd'),
        '12e821fd4c608270b019feb736c469dd',
      );
    });

    test('大写 md5 归一为小写', () {
      expect(
        Config.spiderJarMd5('http://a.com/x.jar;md5;12E821FD4C608270B019FEB736C469DD'),
        '12e821fd4c608270b019feb736c469dd',
      );
    });

    test('无 md5 段 / 非法段返回 null', () {
      expect(Config.spiderJarMd5('http://a.com/x.jar'), null);
      expect(Config.spiderJarMd5('http://a.com/x.jar;md5;'), null);
      expect(Config.spiderJarMd5('http://a.com/x.jar;md5;nothex'), null);
    });
  });

  group('extractJarFromImage (img+ jar 藏图片)', () {
    test('8位** 标记后 base64 提取, 剥离图片垃圾尾巴', () {
      final jarBytes = <int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3]; // PK 头
      final b64 = base64.encode(jarBytes);
      // 垃圾尾巴用非 base64 字母表字符 (@# 等会被剥掉; 字母表内垃圾无法区分)
      final body = <int>[...utf8.encode('FAKEJPEGDATA\xff\xd9AB12cd34**$b64@@##')];
      expect(Config.extractJarFromImage(body), jarBytes);
    });

    test('无标记返回 null', () {
      expect(Config.extractJarFromImage(utf8.encode('no marker here')), null);
    });

    test('饭太硬线上图片容器: 提取结果等于线上解码配置', () {
      final raw = File('test/fixtures/fantaihard_image.bin').readAsBytesSync();
      final extracted = Config.extractJarFromImage(raw)!;
      final live = File('test/fixtures/fantaihard_live.json').readAsBytesSync();
      // 线上真实响应是 CRLF, fixture 存档时规范成了 LF; 比较前统一行尾.
      final got = utf8.decode(extracted).replaceAll('\r\n', '\n');
      final want = utf8.decode(live);
      expect(got, want);
      // 饭太硬配置带 // 注释行, 剥离后应是合法 JSON (证明提取的是真配置).
      final cleaned = Config.stripJsonComments(got);
      expect(jsonDecode(cleaned), isA<Map<String, dynamic>>());
    });
  });

  group('md5Hex (jar md5 校验用)', () {
    test('RFC 1321 标准向量', () {
      expect(Config.md5Hex(utf8.encode('')), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(Config.md5Hex(utf8.encode('a')), '0cc175b9c0f1b6a831c399e269772661');
      expect(Config.md5Hex(utf8.encode('abc')), '900150983cd24fb0d6963f7d28e17f72');
      expect(
        Config.md5Hex(utf8.encode('message digest')),
        'f96b697d7cb7938d525a2f31aaf161d0',
      );
      expect(
        Config.md5Hex(utf8.encode('abcdefghijklmnopqrstuvwxyz')),
        'c3fcd3d76192e4007dfb496cca67e13b',
      );
    });

    test('跨块数据 (超过 64 字节)', () {
      expect(
        Config.md5Hex(utf8.encode('The quick brown fox jumps over the lazy dog')),
        '9e107d9d372bb6826bd81d3542a419d6',
      );
    });
  });
}
