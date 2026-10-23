import 'dart:math';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 弹幕设置 (移植自 NovaTV DanmuHelper + HawkConfig):
///   open          弹幕总开关            (默认 true)
///   maxLine       弹幕行数 1~30         (默认 3)
///   speed         滚动速度倍率           (默认 1.5)
///   alpha         透明度 0.1~1.0        (默认 0.9)
///   sizeScale     字号缩放 0.4x~2.4x    (默认 1.2)
///   lineSpacingPx 行间距 0~32px         (默认 8)
///   topMarginPx   顶部边距 0~300px      (默认 40)
///   randomColor   随机颜色              (默认 false)
///   customApi     自定义弹幕搜索接口      (默认空)
///   useDefaultApi 强制使用内置接口        (默认 false)
class DanmuSettings {
  DanmuSettings._();
  static final DanmuSettings instance = DanmuSettings._();

  static const String _kOpen = 'danmu_open';
  static const String _kMaxLine = 'danmu_max_line';
  static const String _kSpeed = 'danmu_speed';
  static const String _kAlpha = 'danmu_alpha';
  static const String _kSizeScale = 'danmu_size_scale';
  static const String _kLineSpacingPx = 'danmu_line_spacing_px';
  static const String _kTopMarginPx = 'danmu_top_margin_px';
  static const String _kRandomColor = 'danmu_random_color';
  static const String _kCustomApi = 'danmu_api';
  static const String _kUseDefaultApi = 'danmu_api_use_default';

  /// canvas_danmaku 的基础字号 (对应 DanmakuFlameMaster 的默认 25px 的缩小版,
  /// 最终字号 = baseFontSize * sizeScale).
  static const double baseFontSize = 16;

  /// 滚动弹幕基准时长 (秒): 最终 duration = baseDuration / speed.
  static const double baseDuration = 8;

  /// 随机颜色调色板 (与 NovaTV 一致).
  static const List<int> palette = [
    0xFFFFFFFF, // #ffffff
    0xFF70F3FF,
    0xFF44CEF6,
    0xFF3EEDE7,
    0xFF00E079,
    0xFF2EDFA3,
    0xFFBCE672,
    0xFFFFF143,
    0xFFFFA631,
    0xFFFF7500,
    0xFFFF4E20,
    0xFFFF2D51,
    0xFFEF7A82,
    0xFFFF0097,
    0xFFB0A4E3,
    0xFF4B5CC4,
  ];

  final _random = Random();

  bool _open = true;
  int _maxLine = 3;
  double _speed = 1.5;
  double _alpha = 0.9;
  double _sizeScale = 1.2;
  int _lineSpacingPx = 8;
  int _topMarginPx = 40;
  bool _randomColor = false;
  String _customApi = '';
  bool _useDefaultApi = false;
  bool _loaded = false;

  bool get open => _open;
  int get maxLine => _maxLine;
  double get speed => _speed;
  double get alpha => _alpha;
  double get sizeScale => _sizeScale;
  int get lineSpacingPx => _lineSpacingPx;
  int get topMarginPx => _topMarginPx;
  bool get randomColor => _randomColor;
  String get customApi => _customApi;
  bool get useDefaultApi => _useDefaultApi;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _open = prefs.getBool(_kOpen) ?? true;
    _maxLine = _clampInt(prefs.getInt(_kMaxLine) ?? 3, 1, 30);
    _speed = prefs.getDouble(_kSpeed) ?? 1.5;
    _alpha = _clampDouble(prefs.getDouble(_kAlpha) ?? 0.9, 0.1, 1.0);
    _sizeScale = _clampDouble(prefs.getDouble(_kSizeScale) ?? 1.2, 0.4, 2.4);
    _lineSpacingPx = _clampInt(prefs.getInt(_kLineSpacingPx) ?? 8, 0, 32);
    _topMarginPx = _clampInt(prefs.getInt(_kTopMarginPx) ?? 40, 0, 300);
    _randomColor = prefs.getBool(_kRandomColor) ?? false;
    _customApi = prefs.getString(_kCustomApi) ?? '';
    _useDefaultApi = prefs.getBool(_kUseDefaultApi) ?? false;
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOpen, _open);
    await prefs.setInt(_kMaxLine, _maxLine);
    await prefs.setDouble(_kSpeed, _speed);
    await prefs.setDouble(_kAlpha, _alpha);
    await prefs.setDouble(_kSizeScale, _sizeScale);
    await prefs.setInt(_kLineSpacingPx, _lineSpacingPx);
    await prefs.setInt(_kTopMarginPx, _topMarginPx);
    await prefs.setBool(_kRandomColor, _randomColor);
    await prefs.setString(_kCustomApi, _customApi);
    await prefs.setBool(_kUseDefaultApi, _useDefaultApi);
    revision.value++;
  }

  bool get loaded => _loaded;

  /// 设置变更版本号: 每次保存自增, 播放页据此重建弹幕区域 (行数/边距变化).
  final revision = ValueNotifier<int>(0);

  Future<void> setOpen(bool v) async {
    _open = v;
    await _save();
  }

  Future<void> setMaxLine(int v) async {
    _maxLine = _clampInt(v, 1, 30);
    await _save();
  }

  Future<void> setSpeed(double v) async {
    _speed = _round1(_clampDouble(v, 0.5, 3.0));
    await _save();
  }

  Future<void> setAlpha(double v) async {
    _alpha = _round1(_clampDouble(v, 0.1, 1.0));
    await _save();
  }

  Future<void> setSizeScale(double v) async {
    _sizeScale = _round1(_clampDouble(v, 0.4, 2.4));
    await _save();
  }

  Future<void> setLineSpacingPx(int v) async {
    _lineSpacingPx = _clampInt(v, 0, 32);
    await _save();
  }

  Future<void> setTopMarginPx(int v) async {
    _topMarginPx = _clampInt(v, 0, 300);
    await _save();
  }

  Future<void> setRandomColor(bool v) async {
    _randomColor = v;
    await _save();
  }

  Future<void> setCustomApi(String api) async {
    _useDefaultApi = false;
    _customApi = api.trim();
    await _save();
  }

  Future<void> setUseDefault(bool useDefault) async {
    _useDefaultApi = useDefault;
    if (useDefault) _customApi = '';
    await _save();
  }

  int pickRandomColor() => palette[_random.nextInt(palette.length)];

  /// 当前生效字号 (px).
  double get fontSize => baseFontSize * _sizeScale;

  /// 当前生效行高系数: 基础 1.0 + 行间距折算 (行间距/字号).
  double get lineHeight {
    final fs = fontSize;
    return 1.0 + (_lineSpacingPx / (fs > 0 ? fs : 1));
  }

  /// 弹幕轨道总高度 = 行数 × 字号 × 行高 (播放页用 SizedBox 约束弹幕容器高度,
  /// canvas_danmaku 会按容器高度自动计算轨道数).
  double get trackHeightPx => _maxLine * fontSize * lineHeight;

  /// 滚动弹幕时长 (秒): 与 NovaTV 语义一致 — 速度倍率越大越慢
  /// (对照 DanmakuFlameMaster setScrollSpeedFactor: 2.4=超慢, 1.5=适中, 1.0=快).
  double get durationSeconds {
    final v = baseDuration * (_speed > 0 ? _speed : 1) / 1.5;
    return v.clamp(2.0, 30.0).toDouble();
  }

  /// 按当前设置构造 canvas_danmaku 的 DanmakuOption.
  DanmakuOption buildOption() {
    return DanmakuOption(
      fontSize: fontSize,
      lineHeight: lineHeight,
      duration: durationSeconds,
      staticDuration: 5,
      opacity: _alpha,
      area: 1.0,
      massiveMode: false,
      safeArea: false,
      strokeWidth: 1.5,
      hideTop: false,
      hideBottom: false,
      hideScroll: false,
      hideSpecial: false,
    );
  }

  static int _clampInt(int v, int min, int max) => v.clamp(min, max).toInt();

  static double _clampDouble(double v, double min, double max) => v.clamp(min, max).toDouble();

  /// 四舍五入到 1 位小数, 避免连续 +/-0.1 步长后出现浮点误差 (如 1.2000001).
  static double _round1(double v) => (v * 10).roundToDouble() / 10;
}
