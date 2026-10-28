import 'dart:async';
import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kids_app/watch_stats.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'legacy server retains events until event receipts are supported',
    () async {
      var upgraded = false;
      var posts = 0;
      final api = FamilyApi(
        client: MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response(
              upgraded ? '{"watch_protocol":"events_v1"}' : '{}',
              200,
            );
          }
          posts++;
          return http.Response('{}', 200);
        }),
      )..server = 'http://legacy:8765';
      final reporter = WatchReporter(api);
      reporter.record('v1', watched: const Duration(seconds: 1));
      await reporter.flush();
      expect(posts, 0);
      upgraded = true;
      await reporter.flush();
      expect(posts, 1);
      await reporter.close(send: false);
    },
  );

  test(
    'offline backlog drains in batches of 50 and survives restart with stable IDs',
    () async {
      var offline = true;
      final requests = <List<dynamic>>[];
      final api = FamilyApi(
        client: MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{"watch_protocol":"events_v1"}', 200);
          }
          final reports = (jsonDecode(request.body) as Map)['reports'] as List;
          requests.add(reports);
          if (offline) throw http.ClientException('offline');
          return http.Response('{}', 200);
        }),
      )..server = 'http://backlog:8765';
      final first = WatchReporter(api);
      for (var i = 0; i < 121; i++) {
        first.record('v$i', watched: const Duration(seconds: 1));
      }
      await first.flush();
      final failed = jsonEncode(requests.single);
      await first.close(send: false);
      offline = false;
      final restored = WatchReporter(api);
      await restored.flush();
      expect(requests.map((batch) => batch.length), [50, 50, 50, 21]);
      expect(jsonEncode(requests[1]), failed);
      await restored.close(send: false);
      expect(
        jsonDecode(
          (await SharedPreferences.getInstance()).getString(
            'watch_outbox_v1_${api.server}',
          )!,
        ),
        isEmpty,
      );
    },
  );

  test(
    'samples recorded during a request do not mutate its retry payload',
    () async {
      final inFlight = Completer<void>();
      final started = Completer<void>();
      final attempts = <List<dynamic>>[];
      final api = FamilyApi(
        client: MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{"watch_protocol":"events_v1"}', 200);
          }
          attempts.add((jsonDecode(request.body) as Map)['reports'] as List);
          if (attempts.length == 1) {
            started.complete();
            await inFlight.future;
            throw http.ClientException('response lost');
          }
          return http.Response('{}', 200);
        }),
      )..server = 'http://inflight:8765';
      final reporter = WatchReporter(api);
      reporter.record('v1', watched: const Duration(seconds: 3));
      final flush = reporter.flush();
      await started.future;
      reporter.record('v1', watched: const Duration(seconds: 2));
      inFlight.complete();
      await flush;
      await reporter.flush();
      expect(attempts[1].first, attempts[0].first);
      expect(attempts[1][1]['event_id'], isNot(attempts[1][0]['event_id']));
      expect(attempts[1][1]['watched_ms'], 2000);
      await reporter.close(send: false);
    },
  );

  test(
    'two playback pages share one outbox and preserve the viewing day',
    () async {
      final reports = <dynamic>[];
      final api = FamilyApi(
        client: MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{"watch_protocol":"events_v1"}', 200);
          }
          reports.addAll((jsonDecode(request.body) as Map)['reports'] as List);
          return http.Response('{}', 200);
        }),
      )..server = 'http://shared:8765';
      var now = DateTime(2026, 10, 25, 23, 59);
      final first = WatchReporter(api, now: () => now);
      final second = WatchReporter(api, now: () => now);
      first.record('v1', watched: const Duration(seconds: 2));
      now = DateTime(2026, 10, 26);
      second.record('v1', watched: const Duration(seconds: 3));
      await Future.wait([first.flush(), second.flush()]);
      expect(reports.map((e) => e['day']), ['2026-10-25', '2026-10-26']);
      expect(reports.map((e) => e['watched_ms']), [2000, 3000]);
      await first.close(send: false);
      await second.close(send: false);
    },
  );

  test(
    'switching servers never sends the previous server outbox to the new one',
    () async {
      var calls = 0;
      final api = FamilyApi(
        client: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      )..server = 'http://old:8765';
      final reporter = WatchReporter(api);
      reporter.record('v1', played: true);
      api.server = 'http://new:8765';
      await reporter.flush();
      expect(calls, 0);
      await reporter.close(send: false);
    },
  );
}
