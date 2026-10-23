import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine_channel.dart';
import 'live_models.dart';
import 'txt_subscribe.dart';

/// 直播数据层: 直播源地址/上次频道持久化, 拉取解析, 归一化数组转模型.
///
/// 对照原版:
/// - 拉取链路: ApiConfig.loadLiveApi (type 0 直链) + LocalServer proxy 直拉
/// - 解析: util/live/TxtSubscribe.parseToJsonArray
/// - 建模: ApiConfig.loadLives (分组/频道, 同名频道合并线路)
class LiveStore {
  LiveStore._();

  static final LiveStore instance = LiveStore._();

  static const String _prefUrlKey = 'live_url';
  static const String _prefChannelKey = 'live_channel';

  /// 缓冲超时自动换源的默认时长 (毫秒), 对照原版 LiveFragment 默认 10s.
  static const int defaultTimeoutMs = 10000;

  /// 播放出错后自动换源的延迟 (毫秒), 对照原版 3.5s.
  static const int errorRetryDelayMs = 3500;

  String _liveUrl = '';
  String get liveUrl => _liveUrl;

  String _lastChannelName = '';
  String get lastChannelName => _lastChannelName;

  bool _initialized = false;

  /// 直播源地址变化 (设置页保存后直播页重载; 页面被 IndexedStack 保活).
  final ValueNotifier<String> liveUrlChanged = ValueNotifier<String>('');

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _liveUrl = prefs.getString(_prefUrlKey) ?? '';
    _lastChannelName = prefs.getString(_prefChannelKey) ?? '';
    liveUrlChanged.value = _liveUrl;
  }

  /// 保存直播源地址 (空地址 = 清除). 返回是否发生变化.
  Future<bool> setLiveUrl(String url) async {
    final target = url.trim();
    if (target == _liveUrl) return false;
    _liveUrl = target;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefUrlKey, target);
    liveUrlChanged.value = target;
    return true;
  }

  /// 记录上次播放的频道名 (下次进入直播页自动定位).
  Future<void> setLastChannelName(String name) async {
    if (name == _lastChannelName) return;
    _lastChannelName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefChannelKey, name);
  }

  /// 非 http 开头补 http:// (对照 Config.normalizeUrl 的轻量版).
  static String normalizeUrl(String input) {
    final u = input.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    return 'http://$u';
  }

  /// 拉取并解析直播源. 返回 (是否成功, 面向用户的消息, 分组列表).
  /// Dart http 失败时用引擎 OkHttp 兜底 (支持 IDN 中文域名).
  static Future<(bool ok, String msg, List<LiveChannelGroup> groups)> fetchAndParse(
      String url) async {
    final target = normalizeUrl(url);
    if (target.isEmpty) return (false, '直播源地址为空', const <LiveChannelGroup>[]);
    var body = await _getText(target);
    if (body == null || body.isEmpty) {
      body = await EngineChannel.getText(target);
      if (body.isEmpty) body = null;
    }
    if (body == null || body.isEmpty) {
      return (false, '拉取直播源失败: $target\n(网络错误或地址无效)', const <LiveChannelGroup>[]);
    }
    final groups = loadLives(TxtSubscribe.parseToJsonArray(body));
    if (groups.isEmpty) {
      return (false, '直播源解析失败: $target\n(内容不是有效的直播列表)', const <LiveChannelGroup>[]);
    }
    final channelCount = groups.fold<int>(0, (sum, g) => sum + g.channels.length);
    return (true, '已载入 $channelCount 个频道', groups);
  }

  static Future<String?> _getText(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'user-agent': 'okhttp/4.12.0'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || res.body.isEmpty) return null;
      return res.body;
    } catch (_) {
      return null;
    }
  }

  /// 归一化分组数组 → 直播模型, 对照原版 ApiConfig.loadLives.
  ///
  /// - 分组名 "_" 前半段为名称, 后半段为分组密码
  /// - url 中 "$线路名" 的 $ 后半段为线路名, 缺省 "源N"
  /// - 同名频道合并线路 (对照 mergeLiveChannel)
  static List<LiveChannelGroup> loadLives(
      List<Map<String, dynamic>> livesArray) {
    final liveChannelGroupList = <LiveChannelGroup>[];
    var groupIndex = 0;
    var channelIndex = 0;
    var channelNum = 0;
    for (final groupElement in livesArray) {
      final liveChannelGroup = LiveChannelGroup();
      liveChannelGroup.groupIndex = groupIndex++;
      final groupObj = groupElement;
      final groupName = _safeStr(groupObj['group']).trim();
      final splitGroupName = _split2(groupName, '_');
      liveChannelGroup.groupName = splitGroupName[0];
      liveChannelGroup.groupPassword =
          splitGroupName.length > 1 ? splitGroupName[1] : '';
      channelIndex = 0;
      final channelsRaw = groupObj['channels'];
      final channels = channelsRaw is List ? channelsRaw : const <dynamic>[];
      for (final channelElement in channels) {
        if (channelElement is! Map) continue;
        final obj = channelElement.cast<String, dynamic>();
        final liveChannelItem = LiveChannelItem();
        liveChannelItem.channelName = _safeStr(obj['name']).trim();
        liveChannelItem.channelLogo = _safeStr(obj['logo']).trim();
        liveChannelItem.channelUa = _safeStr(obj['ua']).trim();
        liveChannelItem.channelClick = _safeStr(obj['click']).trim();
        liveChannelItem.channelFormat = _safeStr(obj['format']).trim();
        liveChannelItem.channelOrigin = _safeStr(obj['origin']).trim();
        liveChannelItem.channelReferer = _safeStr(obj['referer']).trim();
        liveChannelItem.channelTvgId = _safeStr(obj['tvg-id']).trim();
        liveChannelItem.channelTvgName = _safeStr(obj['tvg-name']).trim();
        final parseRaw = obj['parse'];
        if (parseRaw is int) {
          liveChannelItem.channelParse = parseRaw;
        } else if (parseRaw is String) {
          liveChannelItem.channelParse = int.tryParse(parseRaw.trim()) ?? 0;
        }
        final catchupRaw = obj['catchup'];
        if (catchupRaw != null) {
          if (catchupRaw is Map) {
            liveChannelItem.channelCatchup = catchupRaw.cast<String, dynamic>();
          } else {
            final catchupObj = <String, dynamic>{'type': _safeStr(catchupRaw)};
            if (obj.containsKey('catchup-source')) {
              catchupObj['source'] = _safeStr(obj['catchup-source']).trim();
            }
            if (obj.containsKey('catchup-replace')) {
              catchupObj['replace'] = _safeStr(obj['catchup-replace']).trim();
            }
            liveChannelItem.channelCatchup = catchupObj;
          }
        }
        final headerRaw = obj['header'];
        if (headerRaw is Map) {
          final channelHeader = <String, String>{};
          for (final entry in headerRaw.entries) {
            channelHeader['${entry.key}'] = _safeStr(entry.value);
          }
          liveChannelItem.channelHeader = channelHeader;
        }
        // urls 单元素为对象时取其 JSON 文本 (对照 safeJsonStringList).
        final urlsRaw = obj['urls'];
        final urls = <String>[];
        if (urlsRaw is Map) {
          urls.add(_safeStr(urlsRaw));
        } else if (urlsRaw is List) {
          for (final element in urlsRaw) {
            urls.add(_safeStr(element));
          }
        }
        final sourceNames = <String>[];
        final sourceUrls = <String>[];
        var sourceIndex = 1;
        for (final url in urls) {
          final splitText = _split2(url, r'$');
          sourceUrls.add(splitText[0]);
          if (splitText.length > 1) {
            sourceNames.add(splitText[1]);
          } else {
            sourceNames.add('源$sourceIndex');
          }
          sourceIndex++;
        }
        liveChannelItem.channelSourceNames = sourceNames;
        liveChannelItem.channelUrls = sourceUrls;
        if (_mergeLiveChannel(liveChannelGroup.channels, liveChannelItem)) {
          liveChannelItem.channelIndex = channelIndex++;
          liveChannelItem.channelNum = ++channelNum;
        }
      }
      liveChannelGroupList.add(liveChannelGroup);
    }
    return liveChannelGroupList;
  }

  /// 同名频道合并线路, 返回 false 表示是重复频道 (不分配新序号).
  static bool _mergeLiveChannel(
      List<LiveChannelItem> channelItems, LiveChannelItem newItem) {
    for (final item in channelItems) {
      if (item.channelName == newItem.channelName) {
        _mergeLiveChannelUrls(item, newItem);
        return false;
      }
    }
    channelItems.add(newItem);
    return true;
  }

  /// 对照原版 mergeLiveChannelUrls: 去重追加线路, 补全缺失的线路名.
  static void _mergeLiveChannelUrls(
      LiveChannelItem oldItem, LiveChannelItem newItem) {
    final oldUrls = oldItem.channelUrls;
    final oldSourceNames = oldItem.channelSourceNames;
    while (oldSourceNames.length < oldUrls.length) {
      oldSourceNames.add('源${oldSourceNames.length + 1}');
    }
    final newUrls = newItem.channelUrls;
    final newSourceNames = newItem.channelSourceNames;
    for (var i = 0; i < newUrls.length; i++) {
      final url = newUrls[i];
      if (oldUrls.contains(url)) continue;
      oldUrls.add(url);
      if (i < newSourceNames.length) {
        oldSourceNames.add(newSourceNames[i]);
      } else {
        oldSourceNames.add('源${oldSourceNames.length + 1}');
      }
    }
  }

  /// 对照 DefaultConfig.safeJsonString 的字符串形式 (对象/数组取 JSON 文本).
  static String _safeStr(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    if (value is Map || value is List) return jsonEncode(value);
    return '';
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
