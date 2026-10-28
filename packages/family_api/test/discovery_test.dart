import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const validHealth =
    '{"backend":"go","access_mode":"open_lan","content_mode":"direct","library_mode":"managed"}';

class FakeDiscovery extends LanDiscovery {
  FakeDiscovery(this.servers);
  final List<DiscoveredServer> servers;
  @override
  Stream<DiscoveredServer> scan() => Stream.fromIterable(servers);
}

Future<RawDatagramSocket> responder() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  socket.writeEventsEnabled = false;
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final packet = socket.receive();
    if (packet == null) return;
    final request = jsonDecode(utf8.decode(packet.data)) as Map;
    final reply = {
      'service': 'family-video',
      'kind': 'server',
      'protocol': 1,
      'nonce': request['nonce'],
      'instance_id': 'a' * 32,
      'http_port': 34567,
      'name': '家庭电脑',
      'version': '0.9.2',
      'url': 'http://8.8.8.8:1234',
    };
    socket.send(
      utf8.encode(jsonEncode({...reply, 'nonce': 'wrong'})),
      packet.address,
      packet.port,
    );
    socket.send(utf8.encode(jsonEncode(reply)), packet.address, packet.port);
    socket.send(utf8.encode(jsonEncode(reply)), packet.address, packet.port);
  });
  addTearDown(socket.close);
  return socket;
}

void main() {
  test(
    'UDP discovery validates nonce, derives source address and verifies HTTP before deduplication',
    () async {
      final socket = await responder();
      var probes = 0;
      final discovery = LanDiscovery(
        port: socket.port,
        duration: const Duration(milliseconds: 500),
        localAddresses: () async => [InternetAddress.loopbackIPv4],
        targets: [InternetAddress.loopbackIPv4],
        allowLoopback: true,
        clientFactory:
            () => MockClient((r) async {
              probes++;
              expect(r.url.host, '127.0.0.1');
              expect(r.url.port, 34567);
              expect(r.url.path, '/health');
              return http.Response(validHealth, 200);
            }),
      );
      final results = await discovery.scan().toList();
      expect(results.single.url, 'http://127.0.0.1:34567');
      expect(results.single.name, '家庭电脑');
      expect(probes, 1);
    },
  );

  test(
    'a UDP advertisement without a compatible HTTP service is not offered',
    () async {
      final socket = await responder();
      final discovery = LanDiscovery(
        port: socket.port,
        duration: const Duration(milliseconds: 500),
        localAddresses: () async => [InternetAddress.loopbackIPv4],
        targets: [InternetAddress.loopbackIPv4],
        allowLoopback: true,
        clientFactory:
            () =>
                MockClient((r) async => http.Response('{"status":"ok"}', 200)),
      );
      expect(await discovery.scan().toList(), isEmpty);
    },
  );

  test(
    'cancelling a scan cancels its deadline and closes owned HTTP client',
    () async {
      final socket = await responder();
      final client = CloseTrackingClient();
      final discovery = LanDiscovery(
        port: socket.port,
        duration: const Duration(seconds: 30),
        localAddresses: () async => [InternetAddress.loopbackIPv4],
        targets: [InternetAddress.loopbackIPv4],
        allowLoopback: true,
        clientFactory: () => client,
      );
      final server = await discovery.scan().first;
      expect(server.name, '家庭电脑');
      expect(client.closed, 1);
    },
  );

  test('an unanswered search finishes and releases its HTTP client', () async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(socket.close);
    final client = CloseTrackingClient();
    final discovery = LanDiscovery(
      port: socket.port,
      duration: const Duration(milliseconds: 200),
      localAddresses: () async => [InternetAddress.loopbackIPv4],
      targets: [InternetAddress.loopbackIPv4],
      allowLoopback: true,
      clientFactory: () => client,
    );
    expect(
      await discovery.scan().toList().timeout(const Duration(seconds: 2)),
      isEmpty,
    );
    expect(client.closed, 1);
  });

  testWidgets('multiple servers require selection and duplicates are hidden', (
    tester,
  ) async {
    const first = DiscoveredServer(
      id: 'one',
      name: '客厅电脑',
      url: 'http://192.168.1.2:8765',
    );
    const second = DiscoveredServer(
      id: 'two',
      name: '书房电脑',
      url: 'http://192.168.1.3:9876',
    );
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LanDiscoveryPanel(
            discovery: FakeDiscovery([first, first, second]),
            onSelect: (url) => selected = url,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('客厅电脑'), findsOneWidget);
    expect(find.text('书房电脑'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '书房电脑'),
        matching: find.text('连接'),
      ),
    );
    expect(selected, second.url);
    await tester.pumpWidget(const SizedBox());
  });
}

class CloseTrackingClient extends MockClient {
  CloseTrackingClient() : super((r) async => http.Response(validHealth, 200));
  int closed = 0;
  @override
  void close() {
    closed++;
    super.close();
  }
}
