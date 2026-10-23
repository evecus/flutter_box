import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// M2: per site+vod playback position, kept in shared_preferences.
/// Key: "wp_#<siteKey>#<vodId>" -> {"site","vod","vodName","ep","pos","dur","t"}
class WatchProgress {
  static const int _maxEntries = 300;

  static String _key(String siteKey, String vodId) => 'wp_#$siteKey#$vodId';

  static Future<Map<String, dynamic>?> load(String siteKey, String vodId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(siteKey, vodId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  static Future<void> save(
    String siteKey,
    String vodId,
    String vodName,
    String ep,
    int posMs,
    int durMs,
  ) async {
    if (durMs <= 0 || posMs <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString('wp_last_sweep') ?? '';

      // Sweep occasionally to cap storage size.
      if (last.isEmpty ||
          DateTime.now().millisecondsSinceEpoch - (int.tryParse(last) ?? 0) > 86400000) {
        await _sweep(prefs);
        await prefs.setString('wp_last_sweep', '${DateTime.now().millisecondsSinceEpoch}');
      }
      await prefs.setString(
        _key(siteKey, vodId),
        jsonEncode({
          'site': siteKey,
          'vod': vodId,
          'vodName': vodName,
          'ep': ep,
          'pos': posMs,
          'dur': durMs,
          't': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  static Future<void> clear(String siteKey, String vodId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(siteKey, vodId));
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('wp_#')).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  static Future<void> _sweep(SharedPreferences prefs) async {
    final keys = prefs.getKeys().where((k) => k.startsWith('wp_#')).toList();
    if (keys.length <= _maxEntries) return;
    final entries = <MapEntry<String, int>>[];
    for (final key in keys) {
      try {
        final obj = jsonDecode(prefs.getString(key) ?? '{}');
        entries.add(MapEntry(key, (obj['t'] as int?) ?? 0));
      } catch (_) {
        entries.add(MapEntry(key, 0));
      }
    }
    entries.sort((a, b) => a.value - b.value);
    for (final entry in entries.take(entries.length - _maxEntries)) {
      await prefs.remove(entry.key);
    }
  }
}
