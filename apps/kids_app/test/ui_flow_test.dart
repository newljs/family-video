import 'dart:convert';
import 'dart:io';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kids_app/app_home.dart';
import 'package:kids_app/downloads.dart';
import 'package:kids_app/pages.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'connected_feed_test.dart' show FakePlayer;

class MemoryDownloads extends Downloads {
  final List<dynamic> entries;
  int removals = 0;
  MemoryDownloads(super.api, this.entries);
  @override
  Future<List<dynamic>> list() async => List.of(entries);
  @override
  Future<void> remove(Map<String, dynamic> video) async {
    removals++;
    entries.removeWhere((e) => e['id'] == video['id']);
  }
}

class CountingPlayer extends FakePlayer {
  CountingPlayer() : super(const Size(1080, 1920));
  int created = 0;
  final paused = <int>[];
  final played = <int>[];
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      ++created;
  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    paused.add(playerId);
  }
}

Future<void> fonts(WidgetTester tester) async => tester.runAsync(() async {
  final icons = FontLoader('MaterialIcons');
  icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  final file = File('C:/Windows/Fonts/msyh.ttc');
  if (await file.exists()) {
    final loader = FontLoader('Preview');
    loader.addFont(
      Future.value(ByteData.sublistView(await file.readAsBytes())),
    );
    await loader.load();
  }
});
Future<void> shot(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  final out = Directory('${Directory.current.parent.parent.path}/runtime/ui')
    ..createSync(recursive: true);
  await expectLater(
    find.byKey(const Key('preview')),
    matchesGoldenFile(Uri.file('${out.path}/$name.png')),
  );
}

void main() {
  testWidgets('connection page remains usable with larger text and keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await fonts(tester);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Preview'),
          home: const KidsHome(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Image decoding uses the engine queue; finish it before capturing branding.
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('assets/branding/douyin_icon.png'),
        tester.element(find.byType(KidsHome)),
      );
    });
    await tester.pumpAndSettle();
    await shot(tester, 'v05-kids-connection');
    await tester.enterText(find.byType(TextField), 'invalid');
    await tester.ensureVisible(find.text('进入放映室'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入放映室'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入服务器地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final address = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(1.4),
            viewInsets: EdgeInsets.only(bottom: 280),
          ),
          child: KidsConnectionPage(
            address: address,
            busy: false,
            onConnect: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    address.dispose();
  });
  testWidgets(
    'cached search, preview audio, atomic refresh and cache confirmation work',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final oldPlatform = VideoPlayerPlatform.instance;
      final player = CountingPlayer();
      VideoPlayerPlatform.instance = player;
      addTearDown(() => VideoPlayerPlatform.instance = oldPlatform);
      SharedPreferences.setMockInitialValues({'server': 'http://home:8765'});
      FlutterSecureStorage.setMockInitialValues({});
      await fonts(tester);
      var failRefresh = false;
      final remote = {
        'id': 'remote',
        'title': '远程精选：认识太阳系',
        'media_url': '/video',
        'duration': 132,
      };
      final cached = {
        'id': 'cached',
        'title': '离线 ABC 小实验',
        'local_path': '/cache/video.mp4',
        'duration': 63,
      };
      final api = FamilyApi(
        client: MockClient((r) async {
          if (failRefresh && r.url.path == '/api/collections') {
            return http.Response('{"detail":"temporary failure"}', 500);
          }
          final body = switch (r.url.path) {
            '/health' => {
              'access_mode': 'open_lan',
              'content_mode': 'direct',
              'library_mode': 'managed',
            },
            '/api/videos' => failRefresh ? [] : [remote],
            '/api/collections' => [
              {
                'id': 'science',
                'title': '小小科学家',
                'videos': [remote],
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
      final downloads = MemoryDownloads(api, [cached]);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('preview'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'Preview',
            ),
            home: KidsHome(api: api, downloads: downloads),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索精选'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pumpAndSettle();
      expect(find.text('离线 ABC 小实验'), findsOneWidget);
      await tester.tap(find.text('离线 ABC 小实验'));
      await tester.pumpAndSettle();
      expect(player.paused, contains(1));
      expect(player.created, 2);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(player.played.where((id) => id == 1).length, greaterThan(1));
      // A manually paused homepage must remain paused after a preview.
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pumpAndSettle();
      final playsBeforePreview = player.played.where((id) => id == 1).length;
      await tester.tap(find.byTooltip('搜索精选'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线 ABC 小实验'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(player.played.where((id) => id == 1).length, playsBeforePreview);
      await tester.tap(find.byTooltip('我的合集'));
      await tester.pumpAndSettle();
      await shot(tester, 'v05-kids-collections');
      await tester.tap(find.text('我'));
      await tester.pumpAndSettle();
      await shot(tester, 'v05-kids-profile');
      failRefresh = true;
      await tester.tap(find.text('刷新内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('合集').last);
      await tester.pumpAndSettle();
      expect(find.text('小小科学家'), findsOneWidget);
      await tester.tap(find.text('首页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索精选'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '太阳系');
      await tester.pumpAndSettle();
      expect(find.text('远程精选：认识太阳系'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '找不到的标题');
      await tester.pumpAndSettle();
      expect(find.text('没有找到相关视频'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.download_rounded).last);
      await tester.pumpAndSettle();
      await shot(tester, 'v05-kids-offline');
      await tester.tap(find.byTooltip('删除缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      expect(downloads.removals, 0);
      await tester.tap(find.byTooltip('删除缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除缓存'));
      await tester.pumpAndSettle();
      expect(downloads.removals, 1);
      expect(find.text('还没有缓存的视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
