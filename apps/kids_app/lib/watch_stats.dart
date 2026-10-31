import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:family_api/family_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _day(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';

String _eventId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Playback pages for one server share a durable outbox. Once sent, events
/// remain immutable, including after a timeout or application restart.
class _WatchOutbox {
  _WatchOutbox(this.server) {
    ready = _restore().catchError((Object error) {
      restoreError = error;
    });
  }
  final String server;
  final List<Map<String, dynamic>> events = [];
  final Map<String, Map<String, dynamic>> open = {};
  final Set<WatchReporter> owners = {};
  late final Future<void> ready;
  Object? restoreError;
  Future<void> writes = Future.value();
  Future<void>? sending;
  Timer? saveTimer;
  String get key => 'watch_outbox_v1_$server';

  Future<void> _restore() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return;
    final saved =
        (jsonDecode(raw) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    // Restored events may already have reached the server. Never merge them.
    events.insertAll(0, saved);
  }

  void record(
    String id,
    String day,
    Duration watched,
    bool played,
    bool completed,
  ) {
    final event = open.putIfAbsent('$day/$id', () {
      final item = <String, dynamic>{
        'event_id': _eventId(),
        'day': day,
        'video_id': id,
        'watched_ms': 0,
        'played': false,
        'completed': false,
      };
      events.add(item);
      return item;
    });
    event['watched_ms'] =
        (event['watched_ms'] as int) + max(0, watched.inMilliseconds);
    event['played'] = event['played'] == true || played;
    event['completed'] = event['completed'] == true || completed;
    // Fixed delay rather than trailing debounce: continuous playback saves too.
    saveTimer ??= Timer(const Duration(milliseconds: 500), () {
      saveTimer = null;
      unawaited(persist().catchError((Object _) {}));
    });
  }

  Future<void> persist() async {
    if (server.isEmpty) return;
    await ready;
    if (restoreError != null) {
      throw StateError('Could not restore watch outbox');
    }
    final snapshot = jsonEncode(events);
    final next = writes.catchError((Object _) {}).then((_) async {
      final ok = await (await SharedPreferences.getInstance()).setString(
        key,
        snapshot,
      );
      if (!ok) throw StateError('Could not persist watch outbox');
    });
    writes = next;
    await next;
  }

  Future<void> flush(FamilyApi api) =>
      sending ??= _send(api).whenComplete(() => sending = null);

  Future<void> _send(FamilyApi api) async {
    try {
      await ready;
      if (restoreError != null) return;
      if (server.isEmpty || api.server != server) return;
      if (events.isEmpty) return;
      final health = await api.request('GET', '/health');
      // Legacy servers ignore event IDs. Keep the queue until an idempotent
      // server is available rather than risking duplicate allowance charges.
      if (health is! Map || health['watch_protocol'] != 'events_v1') return;
      if (api.server != server) return;
      final pending = List<Map<String, dynamic>>.from(events);
      open.clear(); // New samples get new IDs while this batch is in flight.
      await persist(); // Never transmit an event before it is durable.
      for (var offset = 0; offset < pending.length; offset += 50) {
        if (api.server != server) return;
        final batch = pending.sublist(offset, min(offset + 50, pending.length));
        final response = await api.request('POST', '/api/watch', {
          'reports': batch,
        });
        final ids = batch.map((e) => e['event_id']).toSet();
        events.removeWhere((e) => ids.contains(e['event_id']));
        await persist();
        if (response is Map) {
          for (final owner in List<WatchReporter>.from(owners)) {
            owner.onSync?.call(response);
          }
        }
      }
    } catch (_) {
      // Keep the same event IDs and payloads for the next attempt.
    }
  }
}

class WatchReporter {
  WatchReporter(this.api, {this.onSync, DateTime Function()? now})
    : _now = now ?? DateTime.now,
      _outbox = _outboxes.putIfAbsent(
        api.server,
        () => _WatchOutbox(api.server),
      ) {
    _outbox.owners.add(this);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => flush());
  }
  static final Map<String, _WatchOutbox> _outboxes = {};
  final FamilyApi api;
  final void Function(Map<dynamic, dynamic>)? onSync;
  final DateTime Function() _now;
  final _WatchOutbox _outbox;
  Timer? _timer;
  bool _closed = false;
  String? _serverDay;

  /// 服务端返回的日期才是额度与安静模式的基准；设备日期只在首次同步前兜底。
  void setServerDay(String? day) {
    if (day != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
      _serverDay = day;
    }
  }

  void record(
    String videoId, {
    Duration watched = Duration.zero,
    bool played = false,
    bool completed = false,
  }) {
    if (_closed || videoId.isEmpty || _outbox.server.isEmpty) return;
    if (watched <= Duration.zero && !played && !completed) return;
    _outbox.record(
      videoId,
      _serverDay ?? _day(_now()),
      watched,
      played,
      completed,
    );
  }

  Future<void> flush() => _outbox.flush(api);
  Future<void> persist() => _outbox.persist();

  Future<void> close({bool send = true}) async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _outbox.owners.remove(this);
    if (send) await flush();
    try {
      await persist();
    } finally {
      if (_outbox.owners.isEmpty) {
        _outbox.saveTimer?.cancel();
        if (identical(_outboxes[_outbox.server], _outbox)) {
          _outboxes.remove(_outbox.server);
        }
      }
    }
  }

  void dispose() => unawaited(close().catchError((Object _) {}));
}
