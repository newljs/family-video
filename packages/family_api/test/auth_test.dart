import 'package:family_api/family_api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'server': 'http://old-server:8765',
    });
    FlutterSecureStorage.setMockInitialValues({'token': 'legacy-cache-id'});
  });
  test(
    'parent connects by address without transmitting old credentials',
    () async {
      final api = FamilyApi(
        clientRole: 'parent',
        client: MockClient((r) async {
          expect(r.url.path, '/health');
          expect(r.headers['X-Family-Client'], 'parent');
          expect(r.headers.containsKey('Authorization'), isFalse);
          return http.Response(
            '{"access_mode":"open_lan","content_mode":"direct","library_mode":"managed"}',
            200,
          );
        }),
      );
      await api.restore();
      await api.save(' http://old-server:8765/ ');
      expect(api.token, 'legacy-cache-id');
      expect(api.server, 'http://old-server:8765');
      final restored = FamilyApi();
      await restored.restore();
      expect(restored.server, api.server);
      expect(restored.token, 'legacy-cache-id');
    },
  );
  test(
    'old backend is explained and a failed connection preserves saved address',
    () async {
      final api = FamilyApi(
        client: MockClient((r) async => http.Response('{"status":"ok"}', 200)),
      );
      await api.restore();
      await expectLater(
        api.save('http://new-server:8765'),
        throwsA(
          isA<FamilyApiException>().having(
            (e) => e.message,
            'message',
            contains('更新'),
          ),
        ),
      );
      expect(api.server, 'http://old-server:8765');
      final restored = FamilyApi();
      await restored.restore();
      expect(restored.server, api.server);
    },
  );
  test('disconnect and reconnect preserve the offline cache namespace', () async {
    final api = FamilyApi(
      client: MockClient((r) async {
        expect(r.headers['X-Family-Client'], 'child');
        expect(r.headers.containsKey('Authorization'), isFalse);
        return http.Response(
          '{"access_mode":"open_lan","content_mode":"direct","library_mode":"managed"}',
          200,
        );
      }),
    );
    await api.restore();
    await api.logout();
    final disconnected = FamilyApi();
    await disconnected.restore();
    expect(disconnected.server, isEmpty);
    await api.save('http://old-server:8765');
    expect(api.token, 'legacy-cache-id');
  });
  test('invalid URL is rejected before any network request', () async {
    final api = FamilyApi(
      client: MockClient((r) async => throw StateError('unexpected request')),
    );
    await expectLater(
      api.save('not-a-server'),
      throwsA(isA<FamilyApiException>()),
    );
  });
  test(
    'an old review server cannot masquerade as direct visibility mode',
    () async {
      final api = FamilyApi(
        client: MockClient(
          (r) async => http.Response('{"access_mode":"open_lan"}', 200),
        ),
      );
      await api.restore();
      await expectLater(
        api.save('http://new-server:8765'),
        throwsA(
          isA<FamilyApiException>().having(
            (e) => e.message,
            'message',
            contains('0.7'),
          ),
        ),
      );
      expect(api.server, 'http://old-server:8765');
    },
  );
}
