import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Small, server/role-scoped catalog snapshots. Media bytes remain managed by
/// the player's cache or explicit offline downloads.
class StartupCache {
  StartupCache(this.server, this.role);
  final String server;
  final String role;
  String key(String section) => 'startup_v1_${role}_${server}_$section';

  Future<List<dynamic>> readList(String section) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        key(section),
      );
      if (raw == null) return [];
      final list = jsonDecode(raw) as List;
      if (list.any((item) => item is! Map || item['id'] is! String)) return [];
      if (section == 'collections' &&
          list.any(
            (item) =>
                item['videos'] is! List ||
                (item['videos'] as List).any(
                  (video) => video is! Map || video['id'] is! String,
                ),
          )) {
        return [];
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<String?> readText(String section) async =>
      (await SharedPreferences.getInstance()).getString(key(section));

  Future<void> write(String section, Object value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        key(section),
        value is String ? value : jsonEncode(value),
      );
    } catch (_) {
      /* A failed cache write must not block fresh content. */
    }
  }
}
