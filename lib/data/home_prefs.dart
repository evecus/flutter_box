import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 原版 HawkConfig 的首页相关键:
///   HOME_API ("home_api") - 当前首页源 key (ApiConfig.setSourceBean 持久化)
///   HOME_REC ("home_rec") - 首页列表数据来源:
///     0 = 豆瓣热播 (UserFragment.setDouBanData, 直连豆瓣抓取)
///     1 = 站点推荐 (homeContent 的 list)
///     2 = 观看历史 (本地 Room 记录, 本实现对应 History)
class HomePrefs {
  static const _keyApi = 'home_api';
  static const _keyRec = 'home_rec';

  /// 首页列表数据模式变化时发出通知, 首页据此重载"主页" Tab.
  static final ValueNotifier<int> recNotifier = ValueNotifier<int>(0);

  static int _rec = 0;
  static String _api = '';
  static bool _loaded = false;

  static int get homeRec => _rec;
  static String get homeApi => _api;

  /// 原版 getHomeRecName: 0/1/2 -> 豆瓣热播/站点推荐/观看历史.
  static String recName(int mode) {
    switch (mode) {
      case 1:
        return '站点推荐';
      case 2:
        return '观看历史';
      default:
        return '豆瓣热播';
    }
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _api = prefs.getString(_keyApi) ?? '';
    _rec = prefs.getInt(_keyRec) ?? 0;
    recNotifier.value = _rec;
    _loaded = true;
  }

  static void initFromCache() {
    if (!_loaded) _loaded = true;
  }

  /// 设置首页源 (原版 ApiConfig.setSourceBean 写 Hawk HOME_API).
  static Future<void> setHomeApi(String key) async {
    _api = key;
    final prefs = await SharedPreferences.getInstance();
    if (key.isEmpty) {
      await prefs.remove(_keyApi);
    } else {
      await prefs.setString(_keyApi, key);
    }
  }

  /// 切换首页列表数据来源 (原版 ModelSettingFragment 的 llHomeRec).
  static Future<void> setHomeRec(int mode) async {
    if (mode < 0 || mode > 2) mode = 0;
    _rec = mode;
    recNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyRec, mode);
  }
}
