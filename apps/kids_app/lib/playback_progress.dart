import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local positions shared by recommendations, search and offline feeds.
class PlaybackProgress {
  final String server;
  late final String key = 'playback_v1_${sha256.convert(utf8.encode(server))}';
  final Map<String, int> _positions = {};
  late final Future<void> ready = _restore();
  Future<void> _writes = Future.value();
  bool _dirty = false;
  PlaybackProgress(this.server);

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString(key) ?? '{}') as Map;
      for (final entry in raw.entries) {
        if (entry.key is String && entry.value is int && entry.value >= 0) {
          _positions.putIfAbsent(entry.key, () => entry.value as int);
        }
      }
    } catch (_) {
      /* Playback remains available if device storage is unavailable. */
    }
  }

  Future<Duration> position(String id, Duration duration) async {
    await ready;
    final value = _positions[id] ?? 0;
    // A finished clip starts over, while unfinished clips retain their position.
    if (duration.inMilliseconds <= 0 ||
        value >= duration.inMilliseconds - 1200) {
      return Duration.zero;
    }
    return Duration(milliseconds: value.clamp(0, duration.inMilliseconds));
  }

  void record(String id, Duration position, Duration duration) {
    if (duration <= Duration.zero) return;
    final value = position.inMilliseconds.clamp(0, duration.inMilliseconds);
    if (_positions[id] == value) return;
    _positions.remove(id);
    _positions[id] = value;
    _dirty = true;
    while (_positions.length > 1000) {
      _positions.remove(_positions.keys.first);
    }
  }

  Future<void> flush() {
    if (!_dirty) return _writes;
    _writes = _writes
        .then((_) async {
          await ready;
          if (!_dirty) return;
          final prefs = await SharedPreferences.getInstance();
          final data = jsonEncode(_positions);
          _dirty = false;
          if (!await prefs.setString(key, data)) _dirty = true;
        })
        .catchError((Object _) {
          _dirty = true;
        });
    return _writes;
  }
}
