import 'dart:convert';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart' show Color;
import 'package:http/http.dart' as http;

import 'danmaku_settings.dart';

/// bilibili XML 弹幕条目 (播放时间 + 内容).
class ParsedDanmaku {
  final int timeMs;
  final DanmakuContentItem<Object?> item;

  ParsedDanmaku(this.timeMs, this.item);
}

/// 弹幕解析器 (移植自 NovaTV Parser + Danmu):
///   - source 支持 http(s) 地址与内联 XML (gzip/zlib 自动解压)
///   - <d p="time,type,size,color">text</d> → DanmakuContentItem
///   - type: 1/2/3/6 滚动, 4 底部, 5 顶部, 7/8 特殊弹幕
class DanmakuParser {
  DanmakuParser._();

  static final _danmuReg = RegExp(r'<d\s+p="([^"]*)"[^>]*>(.*?)</d>', dotAll: true);

  /// 解析弹幕源, 返回按时间排序的条目列表. 失败/空内容返回空列表.
  static Future<List<ParsedDanmaku>> parse(String source) async {
    if (source.trim().isEmpty) return [];
    final content = await _resolveContent(source.trim());
    if (content.isEmpty) return [];
    return _parseXml(content);
  }

  static Future<String> _resolveContent(String source) async {
    if (!source.startsWith('http')) return source;
    try {
      final resp = await http
          .get(Uri.parse(source), headers: {
            'User-Agent': 'novabox-flutter',
            'Accept-Encoding': 'gzip',
          })
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return '';
      return _decode(resp.bodyBytes);
    } catch (_) {
      return '';
    }
  }

  static String _decode(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      return utf8.decode(GZipCodec().decode(bytes), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0x78) {
      return utf8.decode(ZLibCodec().decode(bytes), allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static List<ParsedDanmaku> _parseXml(String xml) {
    final settings = DanmuSettings.instance;
    final result = <ParsedDanmaku>[];
    for (final match in _danmuReg.allMatches(xml)) {
      final param = match.group(1) ?? '';
      final rawText = match.group(2) ?? '';
      if (param.isEmpty || rawText.isEmpty) continue;
      final values = param.split(',');
      if (values.length < 4) continue;
      final timeSec = double.tryParse(values[0]) ?? 0;
      final type = int.tryParse(values[1]) ?? 1;
      final colorValue = int.tryParse(values[3]) ?? 0xFFFFFF;
      final text = _decodeXml(rawText);
      if (text.isEmpty) continue;
      final timeMs = (timeSec * 1000).round();
      Color color = Color(0xFF000000 | (colorValue & 0xFFFFFF));
      if (settings.randomColor) {
        color = Color(settings.pickRandomColor());
      }
      final DanmakuContentItem<Object?> item;
      if ((type == 7 || type == 8) && text.startsWith('[') && text.endsWith(']')) {
        final special = _parseSpecial(text, color, settings.fontSize);
        if (special == null) continue;
        item = special;
      } else {
        final itemType = switch (type) {
          4 => DanmakuItemType.bottom,
          5 => DanmakuItemType.top,
          _ => DanmakuItemType.scroll,
        };
        item = DanmakuContentItem<Object?>(text, color: color, type: itemType);
      }
      result.add(ParsedDanmaku(timeMs, item));
    }
    result.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return result;
  }

  /// 特殊弹幕 (高级弹幕): text 为 JSON 数组, 复用 canvas_danmaku 的 fromList.
  static SpecialDanmakuContentItem<Object?>? _parseSpecial(
      String text, Color color, double fontSize) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) return null;
      // fromList 会访问 list[7]~list[13], 不足则补齐, 避免 RangeError.
      final list = List<dynamic>.from(decoded);
      while (list.length < 15) {
        list.add('');
      }
      return SpecialDanmakuContentItem<Object?>.fromList(
        color,
        fontSize,
        list,
        videoX: 1920,
        videoY: 1080,
      );
    } catch (_) {
      return null;
    }
  }

  static String _decodeXml(String text) {
    if (text.isEmpty) return '';
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&gt;', '>')
        .replaceAll('&lt;', '<');
  }
}
