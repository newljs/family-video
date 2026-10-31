import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:parent_app/main.dart';
import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'sync from secondary page includes entries beyond the visible page',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'server': 'http://home:8765',
        'inbox': jsonEncode(
          List.generate(
            41,
            (i) => {'title': '视频 $i', 'text': 'https://example.test/$i'},
          ),
        ),
      });
      FlutterSecureStorage.setMockInitialValues({});
      final imported = <String>[];
      final api = FamilyApi(
        clientRole: 'parent',
        client: MockClient((r) async {
          if (r.url.path == '/api/imports') {
            imported.add(jsonDecode(r.body)['text'] as String);
          }
          final Object body =
              r.url.path == '/health'
                  ? {
                    'access_mode': 'open_lan',
                    'content_mode': 'direct',
                    'library_mode': 'managed',
                  }
                  : [];
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await tester.pumpWidget(MaterialApp(home: ParentHome(api: api)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('查看待同步收集箱（41）'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看待同步收集箱（41）'));
      await tester.pumpAndSettle();
      expect(find.text('41 条待同步 · 已显示 20 条'), findsOneWidget);
      await tester.tap(find.text('同步 41 条到家庭电脑'));
      await tester.pumpAndSettle();
      expect(imported.length, 41);
      expect(imported.toSet().length, 41);
      expect(find.text('同步 0 条到家庭电脑'), findsOneWidget);
      expect(find.text('还没有等待同步的内容'), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString('inbox'), '[]');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'offline collection persists and can be removed without a server',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: ParentHome()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收集箱').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '恐龙小知识');
      await tester.enterText(
        find.byType(TextField).last,
        'https://v.douyin.com/test/',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存到收集箱'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到收集箱'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看待同步收集箱（1）'));
      await tester.tap(find.text('查看待同步收集箱（1）'));
      await tester.pumpAndSettle();
      expect(find.text('同步 1 条到家庭电脑'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('inbox'), contains('恐龙小知识'));
      await tester.ensureVisible(find.byTooltip('移出收集箱'));
      await tester.tap(find.byTooltip('移出收集箱'));
      await tester.pumpAndSettle();
      expect(prefs.getString('inbox'), '[]');
    },
  );
  testWidgets('malformed inbox item is skipped and later items still sync', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'server': 'http://home:8765',
      'inbox': jsonEncode([
        {'title': '坏数据', 'text': 'not-a-link'},
        {'title': '好数据', 'text': 'https://v.douyin.com/good/'},
      ]),
    });
    FlutterSecureStorage.setMockInitialValues({});
    final imported = <String>[];
    final api = FamilyApi(
      clientRole: 'parent',
      client: MockClient((r) async {
        if (r.url.path == '/api/imports') {
          final text = jsonDecode(r.body)['text'] as String;
          if (text == 'not-a-link') {
            return http.Response(jsonEncode({'detail': 'invalid link'}), 400);
          }
          imported.add(text);
          return http.Response(
            jsonEncode({'id': 't1', 'state': 'queued'}),
            200,
          );
        }
        final Object body = switch (r.url.path) {
          '/health' => {
            'access_mode': 'open_lan',
            'content_mode': 'direct',
            'library_mode': 'managed',
          },
          '/api/settings/time-limit' => {
            'limit_minutes': 0,
            'watched_ms_today': 0,
            'day': '2026-10-30',
            'after_limit_collection_id': '',
            'exhausted': false,
          },
          '/api/videos' || '/api/tasks' || '/api/collections' => [],
          _ => <String, dynamic>{},
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: ParentHome(api: api)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('查看待同步收集箱（2）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看待同步收集箱（2）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步 2 条到家庭电脑'));
    await tester.pumpAndSettle();
    expect(imported, ['https://v.douyin.com/good/']);
    expect((await SharedPreferences.getInstance()).getString('inbox'), '[]');
    expect(find.textContaining('已跳过 1 条'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
