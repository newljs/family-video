import 'dart:convert';
import 'dart:io';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent_app/main.dart';
import 'package:parent_app/ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> loadFonts(WidgetTester tester) async => tester.runAsync(() async {
  final icons = FontLoader('MaterialIcons');
  icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  final font = File('C:/Windows/Fonts/msyh.ttc');
  if (await font.exists()) {
    final loader = FontLoader('Preview');
    loader.addFont(
      Future.value(ByteData.sublistView(await font.readAsBytes())),
    );
    await loader.load();
  }
});
Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  final out = Directory('${Directory.current.parent.parent.path}/runtime/ui')
    ..createSync(recursive: true);
  await expectLater(
    find.byKey(const Key('preview')),
    matchesGoldenFile(Uri.file('${out.path}/$name.png')),
  );
}

void main() {
  testWidgets('parent pages expose status, task details and retry on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'server': 'http://home:8765',
      'inbox': jsonEncode([
        {'title': '奇妙的动物世界', 'text': 'https://v.douyin.com/example/'},
      ]),
    });
    FlutterSecureStorage.setMockInitialValues({});
    var retried = false;
    final api = FamilyApi(
      clientRole: 'parent',
      client: MockClient((r) async {
        if (r.url.path == '/api/tasks/failed/retry') retried = true;
        final body = switch (r.url.path) {
          '/health' => {
            'access_mode': 'open_lan',
            'content_mode': 'direct',
            'library_mode': 'managed',
          },
          '/api/videos' => [
            {'id': 'a', 'title': '一起认识奇妙的大自然', 'published': 0, 'duration': 91},
            {'id': 'b', 'title': '今天学一个有趣的小知识', 'published': 1, 'duration': 63},
          ],
          '/api/tasks' => [
            {
              'id': 'failed',
              'title': '一段很值得收藏的科学小实验',
              'state': retried ? 'completed' : 'failed',
              'kind': 'douyin',
              'error': '抖音接口或视频源拒绝访问，请稍后重试。',
            },
            {
              'id': 'done',
              'title': '一起认识奇妙的大自然',
              'state': 'completed',
              'kind': 'upload',
            },
          ],
          _ => [],
        };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await loadFonts(tester);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: parentTheme().copyWith(
            textTheme: parentTheme().textTheme.apply(fontFamily: 'Preview'),
          ),
          home: ParentHome(api: api),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'v05-parent-inbox');
    await tester.ensureVisible(find.text('查看待同步收集箱（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看待同步收集箱（1）'));
    await tester.pumpAndSettle();
    expect(find.text('同步 1 条到家庭电脑'), findsOneWidget);
    await capture(tester, 'parent-pending-inbox');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('查看导入任务列表'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('查看导入任务列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看导入任务列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '失败'));
    await tester.pumpAndSettle();
    expect(find.text('一起认识奇妙的大自然'), findsNothing);
    await tester.ensureVisible(find.text('未能完成导入'));
    await tester.tap(find.text('未能完成导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('抖音接口或视频源拒绝访问'), findsOneWidget);
    await capture(tester, 'v05-parent-tasks');
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retried, isTrue);
    expect(find.text('暂无此类任务'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频库').last);
    await tester.pumpAndSettle();
    expect(find.text('一起认识奇妙的大自然'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.textContaining('审核'), findsNothing);
    await capture(tester, 'v05-parent-library');
    await tester.tap(find.text('连接设置'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await capture(tester, 'v05-parent-connection');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'active tasks outside the first page refresh automatically until finished',
    (tester) async {
      SharedPreferences.setMockInitialValues({'server': 'http://home:8765'});
      FlutterSecureStorage.setMockInitialValues({});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var fetches = 0;
      final api = FamilyApi(
        clientRole: 'parent',
        client: MockClient((r) async {
          Object body = [];
          if (r.url.path == '/health') {
            body = {
              'access_mode': 'open_lan',
              'content_mode': 'direct',
              'library_mode': 'managed',
            };
          }
          if (r.url.path == '/api/tasks') {
            fetches++;
            body = {
              'items': [
                {
                  'id': 'task',
                  'title': '正在导入',
                  'kind': 'douyin',
                  'state': 'completed',
                },
              ],
              'total': 21,
              'active': fetches == 1 ? 1 : 0,
            };
          }
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(theme: parentTheme(), home: ParentHome(api: api)),
      );
      await tester.pumpAndSettle();
      expect(fetches, 1);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(fetches, 2);
      await tester.pump(const Duration(seconds: 16));
      expect(fetches, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'long task names and errors fit a narrow display with larger text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: parentTheme(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: TaskPanel(
                  tasks: [
                    {
                      'id': 'f',
                      'title': '很长的视频标题' * 8,
                      'kind': 'douyin',
                      'state': 'failed',
                      'error': '连接失败的详细原因。' * 20,
                    },
                  ],
                  busy: false,
                  onRetry: (_) {},
                  onCancel: (_) {},
                  onLibrary: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('未能完成导入'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'task progress uses byte counts and delayed retries stay cancellable',
    (tester) async {
      String? cancelled;
      await tester.pumpWidget(
        MaterialApp(
          theme: parentTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TaskPanel(
                tasks: [
                  {
                    'id': 'active',
                    'title': '正在下载',
                    'state': 'running',
                    'phase': 'downloading',
                    'kind': 'douyin',
                    'downloaded_bytes': 2097152,
                    'total_bytes': 4194304,
                  },
                  {
                    'id': 'waiting',
                    'title': '稍后重试',
                    'state': 'queued',
                    'phase': 'retry_wait',
                    'kind': 'douyin',
                    'auto_retries': 1,
                    'next_attempt_at':
                        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60,
                  },
                ],
                busy: false,
                onRetry: (_) {},
                onCancel: (id) {
                  cancelled = id;
                },
                onLibrary: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      expect(find.text('2.0 / 4.0 MB'), findsOneWidget);
      expect(find.textContaining('等待自动重试'), findsOneWidget);
      await tester.ensureVisible(find.text('取消任务').last);
      await tester.tap(find.text('取消任务').last);
      expect(cancelled, 'waiting');
    },
  );
}
