import 'dart:async';
import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'cached library is usable without waiting for the server and survives timeout',
    (tester) async {
      SharedPreferences.setMockInitialValues({'server': 'http://home:8765'});
      FlutterSecureStorage.setMockInitialValues({});
      final cache = StartupCache('http://home:8765', 'parent');
      await cache.write('videos', [
        {'id': 'v1', 'title': '上次的视频库', 'duration': 60},
      ]);
      await cache.write('tab', '1');
      final gate = Completer<void>();
      final api = FamilyApi(
        clientRole: 'parent',
        client: MockClient((r) async {
          await gate.future;
          return http.Response(
            jsonEncode(
              r.url.path == '/health'
                  ? {
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
      await tester.pumpWidget(MaterialApp(home: ParentHome(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('上次的视频库'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('上次的视频库'), findsOneWidget);
      expect(find.textContaining('电脑暂时离线'), findsOneWidget);
      await tester.tap(find.text('收集箱').last);
      await tester.pumpAndSettle();
      expect(find.text('保存到收集箱'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pump();
    },
  );
}
