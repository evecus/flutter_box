import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TV (Android TV / 电视盒子) 模式检测与手动覆盖.
///
/// 检测顺序 (对照原版 NovaTV AndroidManifest 的 leanback 声明):
///   1. 手动覆盖 (SharedPreferences 'tv_mode'): 'on' / 'off' / 'auto'(默认)
///   2. Kotlin 侧 PackageManager.hasSystemFeature("android.software.leanback")
///   3. UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION
///
/// 手机与 TV 共用同一个 APK: 运行时按 [isTV] 切换布局 (底部导航 <-> 左侧栏,
/// 小网格 <-> 大网格, 触摸交互 <-> 遥控器焦点交互).
class TvMode {
  static const _channel = MethodChannel('novabox/platform');
  static const _keyOverride = 'tv_mode';

  /// TV 状态变化时整树重建 (main.dart 的 ValueListenableBuilder 监听).
  static final ValueNotifier<bool> isTV = ValueNotifier<bool>(false);

  /// 'auto' | 'on' | 'off'
  static String override = 'auto';
  static bool _loaded = false;

  static Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      override = prefs.getString(_keyOverride) ?? 'auto';
    } catch (_) {}
    isTV.value = await _resolve();
  }

  static Future<bool> _resolve() async {
    if (override == 'on') return true;
    if (override == 'off') return false;
    return await _detect();
  }

  ///  Kotlin 侧判定: leanback feature 或 UI_MODE_TYPE_TELEVISION.
  static Future<bool> _detect() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('isTV') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 设置页手动切换: 'auto' / 'on' / 'off'.
  static Future<void> setOverride(String value) async {
    override = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyOverride, value);
    } catch (_) {}
    isTV.value = await _resolve();
  }

  static String overrideLabel(String value) {
    switch (value) {
      case 'on':
        return '强制开启';
      case 'off':
        return '强制关闭';
      default:
        return '自动检测';
    }
  }
}
