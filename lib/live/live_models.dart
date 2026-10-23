import 'dart:convert';

/// 直播频道 (对照原版 com.mobile.novabox.bean.LiveChannelItem).
///
/// 一个频道可带多条播放地址 (线路): urls 中 "url$线路名" 的 $ 后半段
/// 作为线路名, 缺省为 "源N" (对照原版 loadLives 的 split("\\$", 2)).
class LiveChannelItem {
  int channelIndex = 0;

  /// 全局频道序号 (跨分组累加, 对照原版 channelNum).
  int channelNum = 0;
  String channelName = '';
  String channelLogo = '';
  String channelUa = '';
  String channelClick = '';
  String channelFormat = '';
  String channelOrigin = '';
  String channelReferer = '';
  String channelTvgId = '';
  String channelTvgName = '';
  Map<String, dynamic> channelCatchup = const {};
  Map<String, String> channelHeader = const {};
  int channelParse = 0;
  List<String> channelSourceNames = [];
  List<String> channelUrls = [];

  /// 当前线路下标.
  int sourceIndex = 0;

  int get sourceNum => channelUrls.length;

  bool get hasCatchup => channelCatchup.isNotEmpty;

  String get url => channelUrls[sourceIndex];

  String get sourceName =>
      sourceIndex >= 0 && sourceIndex < channelSourceNames.length
          ? channelSourceNames[sourceIndex]
          : '';

  void preSource() {
    sourceIndex--;
    if (sourceIndex < 0) sourceIndex = sourceNum - 1;
  }

  void nextSource() {
    sourceIndex++;
    if (sourceIndex >= sourceNum) sourceIndex = 0;
  }

  /// 播放请求头: 频道自身 header + ua/origin/referer (对照原版 getHeaders()).
  Map<String, String> getHeaders() {
    final headers = <String, String>{...channelHeader};
    if (channelUa.isNotEmpty) headers['User-Agent'] = channelUa;
    if (channelOrigin.isNotEmpty) headers['Origin'] = channelOrigin;
    if (channelReferer.isNotEmpty) headers['Referer'] = channelReferer;
    return headers;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': channelName,
        'urls': channelUrls,
        'logo': channelLogo,
        'ua': channelUa,
        'origin': channelOrigin,
        'referer': channelReferer,
        'tvg-id': channelTvgId,
        'tvg-name': channelTvgName,
      };
}

/// 直播分组 (对照原版 com.mobile.novabox.bean.LiveChannelGroup).
///
/// 分组名中的 "_" 后半段是分组密码 (对照原版 loadLives:
/// groupName.split("_", 2) → [0]=名称, [1]=密码).
class LiveChannelGroup {
  int groupIndex = 0;
  String groupName = '';
  String groupPassword = '';
  List<LiveChannelItem> channels = [];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'group': groupPassword.isEmpty ? groupName : '${groupName}_$groupPassword',
        'channels': channels.map((e) => e.toJson()).toList(),
      };
}

/// 把归一化分组数组序列化为 JSON 文本 (仅测试/调试用).
String liveGroupsToJson(List<LiveChannelGroup> groups) =>
    jsonEncode(groups.map((e) => e.toJson()).toList());
