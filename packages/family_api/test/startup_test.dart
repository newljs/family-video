import 'dart:async';
import 'package:family_api/family_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HangingBodyClient extends http.BaseClient {
  final body = StreamController<List<int>>();
  bool aborted = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    (request as http.AbortableRequest).abortTrigger!.then((_) {
      aborted = true;
      body.addError(http.RequestAbortedException(request.url));
      unawaited(body.close());
    });
    return http.StreamedResponse(body.stream, 200);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'catalog snapshots are scoped by server and role and ignore broken JSON',
    () async {
      final cache = StartupCache('http://home', 'child');
      await cache.write('videos', [
        {'id': 'v1', 'title': 'cached'},
      ]);
      await cache.write('last_video', 'v1');
      expect((await cache.readList('videos')).single['id'], 'v1');
      expect(await cache.readText('last_video'), 'v1');
      expect(
        await StartupCache('http://other', 'child').readList('videos'),
        isEmpty,
      );
      expect(
        await StartupCache('http://home', 'parent').readList('videos'),
        isEmpty,
      );
      await (await SharedPreferences.getInstance()).setString(
        cache.key('videos'),
        '{broken',
      );
      expect(await cache.readList('videos'), isEmpty);
    },
  );

  test(
    'health check is reused for five minutes but new addresses are checked',
    () async {
      var calls = 0;
      final api = FamilyApi(
        client: MockClient((r) async {
          calls++;
          return http.Response(
            '{"access_mode":"open_lan","content_mode":"direct","library_mode":"managed"}',
            200,
          );
        }),
      )..server = 'http://home';
      await api.checkServer();
      await api.checkServer();
      expect(calls, 1);
      api.server = 'http://other';
      await api.checkServer();
      expect(calls, 2);
      await api.checkServer(force: true);
      expect(calls, 3);
    },
  );

  test(
    'a response body that stalls is aborted at the request deadline',
    () async {
      final client = HangingBodyClient();
      final api = FamilyApi(client: client)..server = 'http://home';
      await expectLater(
        api.requestWithTimeout(
          'GET',
          '/api/videos',
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.aborted, isTrue);
    },
  );

  test(
    'concurrent refreshes coalesce and reset ignores an older in-flight result',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final sync = BackgroundSync(() async {
        calls++;
        await gate.future;
      });
      final first = sync.run();
      expect(identical(first, sync.run()), isTrue);
      expect(calls, 1);
      sync.reset();
      await sync.run(action: () async {});
      expect(sync.online, isTrue);
      gate.completeError(StateError('old server failed'));
      await first;
      expect(sync.online, isTrue);
      expect(sync.error, isNull);
      sync.dispose();
    },
  );

  testWidgets('retry backs off and stops while inactive or disposed', (
    tester,
  ) async {
    var calls = 0;
    final sync = BackgroundSync(() async {
      calls++;
      throw StateError('offline');
    });
    await sync.run();
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 2);
    sync.setActive(false);
    await tester.pump(const Duration(seconds: 60));
    expect(calls, 2);
    sync.setActive(true);
    await sync.run();
    expect(calls, 3);
    sync.dispose();
    await tester.pump(const Duration(seconds: 60));
    expect(calls, 3);
  });
}
