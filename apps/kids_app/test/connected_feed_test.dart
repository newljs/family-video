import 'dart:convert';
import 'dart:io';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kids_app/app_home.dart';
import 'package:kids_app/downloads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeDownloads extends Downloads {
  final List<dynamic> entries;
  FakeDownloads(super.api, this.entries);
  @override
  Future<List<dynamic>> list() async => entries;
}

class FakePlayer extends VideoPlayerPlatform {
  final Size size;
  FakePlayer(this.size);
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 1;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) async* {
    yield VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 90),
      size: size,
    );
  }

  @override
  Future<void> dispose(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<Duration> getPosition(int playerId) async =>
      const Duration(seconds: 10);
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xff547969), Color(0xff172e29)]),
    ),
    child: Center(child: Icon(Icons.movie, size: 70, color: Colors.white24)),
  );
}

void main() {
  for (final viewport in [const Size(390, 844), const Size(1280, 720)]) {
    for (final source in [const Size(1080, 1920), const Size(1920, 1080)]) {
      testWidgets('complete kids page fills $viewport for video $source', (
        tester,
      ) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final platform = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = FakePlayer(source);
        addTearDown(() => VideoPlayerPlatform.instance = platform);
        SharedPreferences.setMockInitialValues({'server': 'http://home:8765'});
        FlutterSecureStorage.setMockInitialValues({});
        final cached = source.width > source.height;
        final video = {
          'id': 'local-upload',
          'title': '本地上传视频：认识大自然',
          'media_url': '/media/local-upload/video',
          if (cached) 'local_path': '/local/cache/upload.mp4',
        };
        final api = FamilyApi(
          client: MockClient(
            (r) async => http.Response(
              jsonEncode(switch (r.url.path) {
                '/health' => {
                  'access_mode': 'open_lan',
                  'content_mode': 'direct',
                  'library_mode': 'managed',
                },
                '/api/videos' => cached ? [] : [video],
                _ => [],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
        await tester.runAsync(() async {
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
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('page-preview'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                brightness: Brightness.dark,
                fontFamily: 'Preview',
              ),
              home: KidsHome(
                api: api,
                downloads: FakeDownloads(api, cached ? [video] : []),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final page = tester.getRect(find.byType(PageView));
        final player = tester.getRect(find.byType(VideoPlayer));
        expect(page.height, greaterThan(viewport.height * .8));
        expect((player.center - page.center).distance, lessThan(1));
        expect(player.width / player.height, closeTo(source.aspectRatio, .01));
        expect(
          tester.getTopLeft(find.text(video['title']!)).dy,
          greaterThan(viewport.height * .5),
        );
        expect(tester.getTopLeft(find.byTooltip('我的合集')).dy, lessThan(120));
        expect(
          tester.getBottomRight(find.byType(VideoProgressIndicator)).dy,
          closeTo(page.bottom, 1),
        );
        if (const bool.fromEnvironment('CAPTURE_UI')) {
          final out = Directory(
            '${Directory.current.parent.parent.path}/runtime/ui',
          )..createSync(recursive: true);
          await expectLater(
            find.byKey(const Key('page-preview')),
            matchesGoldenFile(
              Uri.file(
                '${out.path}/kids-page-${viewport.width.toInt()}-${source.width.toInt()}.png',
              ),
            ),
          );
        }
        // Also cover switching tabs: the feed must retain full height on return.
        await tester.tap(find.text('我'));
        await tester.pumpAndSettle();
        expect(find.text('我的放映室'), findsOneWidget);
        await tester.tap(find.text('首页'));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(PageView)).height,
          closeTo(page.height, 1),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }
}
