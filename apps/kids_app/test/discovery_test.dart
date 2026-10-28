import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kids_app/app_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDiscovery extends LanDiscovery {
  int scans = 0;
  @override
  Stream<DiscoveredServer> scan() {
    scans++;
    return Stream.value(
      const DiscoveredServer(
        id: 'server',
        name: '家庭电脑',
        url: 'http://192.168.1.20:8765',
      ),
    );
  }
}

void main() {
  testWidgets(
    'first use selects a discovered server without typing and later starts do not scan',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final discovery = FakeDiscovery();
      final api = FamilyApi(
        client: MockClient(
          (r) async => http.Response(
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
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: KidsHome(api: api, discovery: discovery)),
      );
      await tester.pumpAndSettle();
      expect(find.text('家庭电脑'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.ensureVisible(find.text('连接'));
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getString('server'),
        'http://192.168.1.20:8765',
      );
      expect(find.text('首页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(home: KidsHome(api: api, discovery: discovery)),
      );
      await tester.pumpAndSettle();
      expect(discovery.scans, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
