import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/config.dart';

class HistoryItem {
  final String siteKey;
  final String siteName;
  final String vodId;
  final String name;
  final String cover;
  final String ep;
  final String url;
  final int pos;
  final int dur;
  final int ts;

  const HistoryItem({
    required this.siteKey,
    required this.siteName,
    required this.vodId,
    required this.name,
    required this.cover,
    required this.ep,
    required this.url,
    required this.pos,
    required this.dur,
    required this.ts,
  });

  factory HistoryItem.fromMap(Map<String, dynamic> map) => HistoryItem(
        siteKey: map['siteKey'] as String? ?? '',
        siteName: map['siteName'] as String? ?? '',
        vodId: map['vodId'] as String? ?? '',
        name: map['name'] as String? ?? '',
        cover: map['cover'] as String? ?? '',
        ep: map['ep'] as String? ?? '',
        url: map['url'] as String? ?? '',
        pos: (map['pos'] as int?) ?? 0,
        dur: (map['dur'] as int?) ?? 0,
        ts: (map['ts'] as int?) ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'siteKey': siteKey,
        'siteName': siteName,
        'vodId': vodId,
        'name': name,
        'cover': cover,
        'ep': ep,
        'url': url,
        'pos': pos,
        'dur': dur,
        'ts': ts,
      };
}

/// M3: watch history, shared_preferences backed, capped entries.
class History {
  static const _prefKey = 'history';
  static const int _maxEntries = 50;

  static Future<List<HistoryItem>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr.whereType<Map<String, dynamic>>().map((m) => HistoryItem.fromMap(m)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveAll(List<HistoryItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(items.map((e) => e.toMap()).toList()));
  }

  static Future<void> record(
    String siteKey,
    String siteName,
    String vodId,
    String name,
    String cover,
    String ep,
    String url,
    int pos,
    int dur,
  ) async {
    try {
      final items = await list();
      final entry = HistoryItem(
        siteKey: siteKey,
        siteName: siteName,
        vodId: vodId,
        name: name,
        cover: cover,
        ep: ep,
        url: url,
        pos: pos,
        dur: dur,
        ts: DateTime.now().millisecondsSinceEpoch,
      );
      items.removeWhere((i) => i.siteKey == siteKey && i.vodId == vodId);
      items.insert(0, entry);
      if (items.length > _maxEntries) items.removeRange(_maxEntries, items.length);
      await saveAll(items);
    } catch (_) {}
  }

  static Future<void> remove(String siteKey, String vodId) async {
    final items = await list();
    items.removeWhere((i) => i.siteKey == siteKey && i.vodId == vodId);
    await saveAll(items);
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }

  static Site? siteOf(String siteKey) {
    final loaded = Config.loaded;
    if (loaded == null) return null;
    for (final site in loaded.sites) {
      if (site.key == siteKey) return site;
    }
    return null;
  }
}
