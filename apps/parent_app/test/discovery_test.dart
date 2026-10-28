import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDiscovery extends LanDiscovery {
  @override
  Stream<DiscoveredServer> scan() => Stream.value(
    const DiscoveredServer(
      id: 'server',
      name: '家庭电脑',
      url: 'http://192.168.1.20:8765',
    ),
  );
}

void main() {
  testWidgets(
    'first launch shows discovery and connects from a result without address entry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      var videoRequests = 0;
      final api = FamilyApi(
        clientRole: 'parent',
        client: MockClient((r) async {
          if (r.url.path == '/api/videos') videoRequests++;
          return http.Response(
            jsonEncode(
              r.url.path == '/health'
                  ? {
                    'backend': 'go',
                    'access_mode': 'open_lan',
                    'content_mode': 'direct',
                    'library_mode': 'managed',
                  }
                  : [],
            ),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: ParentHome(api: api, discovery: FakeDiscovery())),
      );
      await tester.pumpAndSettle();
      expect(find.text('家庭电脑'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getString('server'),
        'http://192.168.1.20:8765',
      );
      expect(find.text('已连接'), findsOneWidget);
      final beforeReconnect = videoRequests;
      expect(beforeReconnect, greaterThan(0));
      await tester.tap(find.text('连接设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('断开连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('断开连接'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(find.text('已连接'), findsOneWidget);
      expect(videoRequests, greaterThan(beforeReconnect));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
