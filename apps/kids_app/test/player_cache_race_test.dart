import 'dart:async';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_app/feed.dart';
import 'package:kids_app/feed_player_cache.dart';
import 'package:kids_app/playback_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'stream_resume_test.dart' show ResumablePlayer;

class DelayedPlayer extends ResumablePlayer {
  final events = <int, StreamController<VideoEvent>>{};
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = (await super.createWithOptions(options))!;
    events[id] = StreamController<VideoEvent>.broadcast();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  void initialized(int playerId) => events[playerId]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 90),
      size: const Size(1080, 1920),
    ),
  );
  @override
  Future<void> dispose(int playerId) async {
    await super.dispose(playerId);
    await events[playerId]?.close();
  }
}

class FailingHLSPlayer extends ResumablePlayer {
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      sources[playerId - 1].uri!.contains('.m3u8')
      ? Stream.error(
          PlatformException(
            code: 'VideoError',
            message: 'test unavailable stream',
          ),
        )
      : super.videoEventsFor(playerId);
}

void main() {
  testWidgets(
    'returning during initialization shares the pending player without starting hidden audio',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final old = VideoPlayerPlatform.instance;
      final native = DelayedPlayer();
      VideoPlayerPlatform.instance = native;
      addTearDown(() => VideoPlayerPlatform.instance = old);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeedView(
              api: FamilyApi()..server = 'http://home',
              items: const [
                {'id': 'a', 'title': 'A', 'media_url': '/a.mp4'},
                {'id': 'b', 'title': 'B', 'media_url': '/b.mp4'},
              ],
              favorites: const {},
              downloaded: const {},
              onLike: (_) {},
              onDownload: (_) async {},
              onCollections: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      native.initialized(1);
      await tester.pumpAndSettle();
      expect(native.playing, {1});
      await tester.drag(find.byType(PageView), const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 400));
      expect(native.sources.length, 2);
      expect(native.playing, isEmpty);
      await tester.drag(find.byType(PageView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(native.sources.length, 2);
      expect(native.playing, {1});
      native.initialized(2);
      await tester.pumpAndSettle();
      expect(native.playing, {
        1,
      }); // A delayed initialization may not autoplay B.
      await tester.drag(find.byType(PageView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(native.sources.length, 2);
      expect(native.playing, {2});
      expect(native.disposed, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(native.disposed.toSet(), {1, 2});
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'a fallback MP4 player is reused and failed sources can be recreated',
    () async {
      SharedPreferences.setMockInitialValues({});
      final old = VideoPlayerPlatform.instance;
      final native = FailingHLSPlayer();
      VideoPlayerPlatform.instance = native;
      addTearDown(() => VideoPlayerPlatform.instance = old);
      final api = FamilyApi()..server = 'http://home';
      final cache = FeedPlayerCache();
      final progress = PlaybackProgress(api.server);
      final video = {'id': 'a', 'media_url': '/a.mp4', 'stream_url': '/a.m3u8'};
      final first = cache.obtain(video, api, progress);
      await first.ready;
      expect(first.controller.dataSource, 'http://home/a.mp4');
      expect(native.sources.length, 2);
      expect(cache.obtain(video, api, progress), same(first));
      expect(native.sources.length, 2);
      first.failed = true;
      final retry = cache.obtain(video, api, progress);
      expect(first.closed, isTrue);
      await retry.ready;
      await cache.close();
      expect(native.sources.length, 4);
      expect(native.disposed.toSet(), {1, 2, 3, 4});
    },
  );
  test(
    'evicting an initializing player cancels its pending initialization',
    () async {
      SharedPreferences.setMockInitialValues({});
      final old = VideoPlayerPlatform.instance;
      final native = DelayedPlayer();
      VideoPlayerPlatform.instance = native;
      addTearDown(() => VideoPlayerPlatform.instance = old);
      final api = FamilyApi()..server = 'http://home';
      final cache = FeedPlayerCache(capacity: 1);
      final progress = PlaybackProgress(api.server);
      final a = cache.obtain({'id': 'a', 'media_url': '/a.mp4'}, api, progress);
      await Future<void>.delayed(Duration.zero);
      final b = cache.obtain({'id': 'b', 'media_url': '/b.mp4'}, api, progress);
      await expectLater(a.ready, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      native.initialized(2);
      await b.ready;
      expect(a.closed, isTrue);
      expect(native.played, isEmpty);
      await cache.close();
      expect(native.disposed.toSet(), {1, 2});
    },
  );
}
