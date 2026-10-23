import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novabox_flutter/config/config.dart';

/// 真实配置夹具: 饭太硬 (http://www.饭太硬.net/tv) 的返回内容,
/// 99 个站点全部是 type:3 + csp_ 前缀 + 依赖主 jar 的现代结构.
/// 这份夹具同时验证四个修复点:
///   1. isRealSource 不再误杀 type 3 + csp_
///   2. spider 的 ;md5; 段被正确拆分 (jar URL 不把 "md5" 当地址)
///   3. 整段粘贴不走网络
///   4. lives / rules / parses 等扩展段解析不炸
String _realConfigText() =>
    File('test/fixtures/fantaihard.json').readAsStringSync();

void main() {
  group('真实配置 (饭太硬 tv.json, 99 源全 csp_)', () {
    test('直接粘贴: 99 个源全部判定可用', () async {
      final config = Config(_realConfigText());
      await config.fetch();
      expect(config.sites.length, 99);
      expect(config.sites.every((s) => s.isRealSource), true);
      // spider 字段: jar URL + ;md5; 校验值, 主 jar 加载时会拆开用
      expect(config.spiderRaw, startsWith('http'));
      expect(config.spiderRaw, contains(';md5;'));
    });

    test('sites 字段完整: key/name/type/api/ext', () async {
      final config = Config(_realConfigText());
      await config.fetch();
      final first = config.sites.first;
      expect(first.key, isNotEmpty);
      expect(first.name, isNotEmpty);
      expect(first.type, 3);
      expect(first.api, startsWith('csp_'));
      // ext 含 URL 的站点 ext 非空
      expect(config.sites.any((s) => s.ext.isNotEmpty), true);
    });

    test('整体 base64 包裹的同一份配置解析结果一致', () async {
      final text = _realConfigText();
      final b64 = base64.encode(utf8.encode(text));
      final config = Config(b64);
      await config.fetch();
      expect(config.sites.length, 99);
      expect(config.sites.every((s) => s.isRealSource), true);
    });

    test('lives/rules/parses 等扩展段不影响点播源导入', () async {
      final config = Config(_realConfigText());
      await config.fetch();
      expect(config.lines, isEmpty); // 无 urls 集合, 无线路列表
      expect(config.url, startsWith('{')); // 粘贴内容原样保留
    });
  });

  group('真实配置 (饭太硬线上抓包 fantaihard_live.json)', () {
    // 2026-10-20 线上响应: JPEG 尾部 base64 解出的原始配置.
    // 49 个源 (46 csp_ + 3 js), 且含一条被 // 注释掉的站点行:
    //   //{"key":"播客",...}   ← Dart jsonDecode 直接抛异常, 原版 Gson lenient 能过
    String liveText() =>
        File('test/fixtures/fantaihard_live.json').readAsStringSync();

    test('含 // 注释行的线上配置直接粘贴可解析', () async {
      expect(liveText().contains('//{"key"'), true); // 夹具确实带注释行
      final config = Config(liveText());
      await config.fetch();
      expect(config.sites.length, 49);
      expect(config.sites.every((s) => s.isRealSource), true);
    });

    test('被 // 注释掉的站点不会成为源', () async {
      final config = Config(liveText());
      await config.fetch();
      expect(config.sites.any((s) => s.key == '播客'), false);
    });

    test('lives/rules/hosts/logo/wallpaper 扩展段不炸解析', () async {
      final config = Config(liveText());
      await config.fetch();
      expect(config.lines, isEmpty);
      // 主 jar 是 .jpg 伪装 + ;md5; 校验 (meitudata)
      expect(config.spiderRaw, startsWith('https://'));
      expect(config.spiderRaw, contains(';md5;'));
    });

    test('URL 导入: image/x-ms-bmp 容器全链路 (JPEG + 8位** + base64)', () async {
      final raw = File('test/fixtures/fantaihard_image.bin').readAsBytesSync();
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        req.response.statusCode = 200;
        // 线上真实 content-type, 无 charset (Dart http 按 latin1 解码)
        req.response.headers.contentType = ContentType('image', 'x-ms-bmp');
        req.response.add(raw);
        await req.response.close();
      });
      final config = Config('http://127.0.0.1:${server.port}/tv');
      await config.fetch();
      expect(config.sites.length, 49);
      await server.close(force: true);
    });
  });
}
