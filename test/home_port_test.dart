import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:novabox_flutter/data/douban_hot.dart';
import 'package:novabox_flutter/data/home_prefs.dart';
import 'package:novabox_flutter/data/spider_data.dart';

/// 原版首页移植的纯逻辑测试:
/// - VodItem 字段解析 (评分/年份/备注, 对照 AbsJson.AbsJsonVod.toXmlVideo)
/// - 豆瓣热播解析 (对照 UserFragment.loadHots)
/// - 图片地址 @User-Agent= 后缀拆分
/// - HomePrefs.recName 三模式命名 (对照 ModelSettingFragment.getHomeRecName)

Map<String, dynamic> _vod(Map<String, dynamic> m) => m;

void main() {
  group('VodItem 解析', () {
    test('解析评分/年份/备注 (mac-cms 风格)', () {
      final items = vodList([
        _vod({
          'vod_id': 71989,
          'vod_name': '测试影片',
          'vod_pic': 'https://img.example.com/a.jpg',
          'vod_remarks': '共30集,更新至12集',
          'vod_score': '8.6',
          'vod_year': '2022',
        }),
      ], siteKey: 'Douban');
      expect(items.length, 1);
      final v = items.first;
      expect(v.id, '71989');
      expect(v.siteKey, 'Douban');
      expect(v.name, '测试影片');
      expect(v.cover, 'https://img.example.com/a.jpg');
      expect(v.remark, '共30集,更新至12集');
      expect(v.score, '8.6');
      expect(v.year, '2022');
      expect(v.searchOnly, false);
    });

    test('vod_douban_score 兜底, 无意义值被过滤', () {
      final items = vodList([
        _vod({'vod_id': '1', 'vod_name': 'A', 'vod_douban_score': '7.2', 'vod_year': '0'}),
        _vod({'vod_id': '2', 'vod_name': 'B', 'vod_score': '0', 'vod_year': ''}),
        _vod({'vod_id': '3', 'vod_name': 'C', 'vod_score': '暂无'}),
        _vod({'vod_id': '4', 'vod_name': 'D'}),
      ]);
      expect(items[0].score, '7.2');
      expect(items[0].year, isNull); // 0 年不显示角标 (对照 GridAdapter year<=0 GONE)
      expect(items[1].score, isNull);
      expect(items[2].score, isNull);
      expect(items[3].score, isNull);
      expect(items[3].year, isNull);
      expect(items[3].remark, isNull);
    });

    test('缺 vod_name 的行被剔除', () {
      final items = vodList([
        _vod({'vod_id': '1', 'vod_pic': 'x'}),
        _vod({'vod_id': '2', 'vod_name': '有名字'}),
      ]);
      expect(items.length, 1);
      expect(items.first.name, '有名字');
    });

    test('非 List 输入返回空', () {
      expect(vodList(null), isEmpty);
      expect(vodList('not-a-list'), isEmpty);
    });
  });

  group('豆瓣热播 (UserFragment.loadHots 等价)', () {
    test('解析 data[].title/rate/cover, rate 拼"分"', () {
      final items = doubanHotList([
        {'title': '流浪地球', 'rate': '8.4', 'cover': 'https://img.douban.com/x.webp'},
        {'title': '无评分片', 'rate': '', 'cover': 'https://img.douban.com/y.webp'},
        {'title': '零分片', 'rate': '0', 'cover': 'https://img.douban.com/z.webp'},
      ]);
      expect(items.length, 3);
      expect(items[0].name, '流浪地球');
      expect(items[0].score, '8.4');
      expect(items[0].remark, '8.4 分');
      expect(items[0].cover, 'https://img.douban.com/x.webp');
      expect(items[0].searchOnly, true); // 无 vod_id → 点击走搜索
      expect(items[1].remark, isNull);
      expect(items[2].remark, isNull);
    });

    test('超过 25 条的截断在 DoubanHot._parse 内完成', () {
      // doubanHotList 本身不截断; 截断逻辑在 DoubanHot._parse (take 25).
      // 这里验证解析器对大批量数据的稳定性.
      final many = List.generate(60, (i) => {'title': '片$i', 'rate': '6.0', 'cover': 'c$i'});
      expect(doubanHotList(many).length, 60);
    });
  });

  group('图片地址后缀 (FongMi @User-Agent= 约定)', () {
    test('拆出干净 URL 与 headers', () {
      final (url, headers) = picUrlAndHeaders(
        'https://img.douban.com/x.webp@User-Agent=Mozilla/5.0@Referer=https://www.douban.com/',
      );
      expect(url, 'https://img.douban.com/x.webp');
      expect(headers['User-Agent'], 'Mozilla/5.0');
      expect(headers['Referer'], 'https://www.douban.com/');
    });

    test('普通 URL 原样返回', () {
      const u = 'https://img.example.com/a.jpg';
      final (url, headers) = picUrlAndHeaders(u);
      expect(url, u);
      expect(headers, isEmpty);
    });
  });

  group('首页列表数据命名 (getHomeRecName 等价)', () {
    test('0/1/2 → 豆瓣热播/站点推荐/观看历史', () {
      expect(HomePrefs.recName(0), '豆瓣热播');
      expect(HomePrefs.recName(1), '站点推荐');
      expect(HomePrefs.recName(2), '观看历史');
      expect(HomePrefs.recName(7), '豆瓣热播'); // 越界回落默认
    });
  });

  group('首页 Tab 组装', () {
    test('主页 + 分类 (对照 DefaultConfig.adjustSort withMy)', () {
      // homeContent 的 class 数组 → Tab 列表, 主页固定第一.
      final classes = classList([
        {'type_id': '1', 'type_name': '电影'},
        {'type_id': '2', 'type_name': '剧集'},
        {'type_name': '无 id 的项'}, // 被剔除
      ]);
      expect(classes.length, 2);
      expect(classes[0]['type_id'], '1');
      expect(classes[0]['type_name'], '电影');
    });
  });

  group('豆瓣热播 JSON 解析端到端', () {
    test('Gson 风格的 {"data":[...]} 直接喂给 doubanHotList', () {
      const body = '{"data":[{"title":"热映","rate":"9.1","cover":"https://c/1.webp"}]}';
      final map = jsonDecode(body) as Map<String, dynamic>;
      final items = doubanHotList(map['data']);
      expect(items.length, 1);
      expect(items.first.name, '热映');
      expect(items.first.remark, '9.1 分');
    });
  });
}
