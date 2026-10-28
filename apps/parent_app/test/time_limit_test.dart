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
  testWidgets('家长在连接设置页查看并保存每日观看时长限制', (tester) async {
    final savedBodies = <Map<String, dynamic>>[];
    final api = FamilyApi(
      clientRole: 'parent',
      client: MockClient((r) async {
        final body = switch (r.url.path) {
          '/health' => {
            'access_mode': 'open_lan',
            'content_mode': 'direct',
            'library_mode': 'managed',
          },
          '/api/videos' || '/api/tasks' => <dynamic>[],
          '/api/collections' => [
            {'id': 'c1', 'title': '睡前合集', 'videos': <dynamic>[]},
          ],
          '/api/settings/time-limit' => () {
            if (r.method == 'PUT') {
              savedBodies.add(jsonDecode(r.body) as Map<String, dynamic>);
            }
            return {
              'limit_minutes':
                  savedBodies.isEmpty ? 30 : savedBodies.last['limit_minutes'],
              'watched_ms_today': 720000,
              'day': '2026-10-26',
              'after_limit_collection_id':
                  savedBodies.isEmpty
                      ? ''
                      : savedBodies.last['after_limit_collection_id'],
              'exhausted': false,
            };
          }(),
          _ => <String, dynamic>{},
        };
        return http.Response(
          jsonEncode(body),
          r.url.path == '/api/update/parent' ? 404 : 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    SharedPreferences.setMockInitialValues({'server': 'http://home:8765'});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: ParentHome(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接设置'));
    await tester.pumpAndSettle();

    // 服务端限额 30 分钟，今日已看 12 分钟。
    await tester.scrollUntilVisible(
      find.text('儿童观看时长'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('儿童观看时长'), findsOneWidget);
    expect(find.text('每天最多 30 分钟'), findsOneWidget);
    expect(find.text('今日已看 12 分钟，还剩 18 分钟'), findsOneWidget);

    // 关闭限制 → 保存 0；再打开 → 用上次的 30 分钟。
    await tester.ensureVisible(find.text('每日时长限制'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('不限制'), findsOneWidget);
    expect(savedBodies.last['limit_minutes'], 0);
    await tester.ensureVisible(find.text('每日时长限制'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(savedBodies.last['limit_minutes'], 30);
    expect(find.text('每天最多 30 分钟'), findsOneWidget);

    // 选择「额度用完后可看」的合集。
    await tester.ensureVisible(find.text('额度用完后可看'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不指定（用完后什么也看不到）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('睡前合集').last);
    await tester.pumpAndSettle();
    expect(savedBodies.last['after_limit_collection_id'], 'c1');
    expect(savedBodies.last['limit_minutes'], 30);
  });
}
