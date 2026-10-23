import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/config.dart';

class FavoriteItem {
  final String siteKey;
  final String siteName;
  final String vodId;
  final String name;
  final String cover;

  const FavoriteItem({
    required this.siteKey,
    required this.siteName,
    required this.vodId,
    required this.name,
    required this.cover,
  });

  factory FavoriteItem.fromMap(Map<String, dynamic> map) => FavoriteItem(
        siteKey: map['siteKey'] as String? ?? '',
        siteName: map['siteName'] as String? ?? '',
        vodId: map['vodId'] as String? ?? '',
        name: map['name'] as String? ?? '',
        cover: map['cover'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'siteKey': siteKey,
        'siteName': siteName,
        'vodId': vodId,
        'name': name,
        'cover': cover,
      };
}

/// M3: favorites, shared_preferences backed.
class Favorites {
  static const _prefKey = 'favorites';

  static Future<List<FavoriteItem>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr.whereType<Map<String, dynamic>>().map((m) => FavoriteItem.fromMap(m)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveAll(List<FavoriteItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(items.map((e) => e.toMap()).toList()));
  }

  static Future<bool> isFav(String siteKey, String vodId) async {
    final items = await list();
    return items.any((i) => i.siteKey == siteKey && i.vodId == vodId);
  }

  static Future<void> toggle(FavoriteItem item) async {
    final items = await list();
    final remain = items.where((i) => !(i.siteKey == item.siteKey && i.vodId == item.vodId));
    if (remain.length == items.length) {
      // Not in favorites -> add in front.
      items.insert(0, item);
    } else {
      items..clear()..addAll(remain);
    }
    await saveAll(items);
  }

  static Future<void> remove(String siteKey, String vodId) async {
    final items = await list();
    items.removeWhere((i) => i.siteKey == siteKey && i.vodId == vodId);
    await saveAll(items);
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
