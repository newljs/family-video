import 'package:family_api/family_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('GET retries once after a transient connection error', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) throw http.ClientException('reset', request.url);
      return http.Response('{"ok":true}', 200);
    });
    final api = FamilyApi(client: client)..server = 'http://127.0.0.1:1';
    final result = await api.request('GET', '/health');
    expect(calls, 2);
    expect(result, {'ok': true});
  });

  test('write requests are never retried', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      throw http.ClientException('reset', request.url);
    });
    final api = FamilyApi(client: client)..server = 'http://127.0.0.1:1';
    await expectLater(
      api.request('POST', '/api/watch', {'reports': <Object>[]}),
      throwsA(isA<http.ClientException>()),
    );
    expect(calls, 1);
  });
}
