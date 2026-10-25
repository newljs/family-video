import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_app/feed.dart';
import 'package:kids_app/feed_player_cache.dart';
import 'package:kids_app/playback_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'connected_feed_test.dart' show FakePlayer;

class ResumablePlayer extends FakePlayer {
  int next = 0;
  final sources = <DataSource>[];
  final positions = <int, Duration>{};
  final seeks = <int, Duration>{};
  final played = <int>[];
  final disposed = <int>[];
  final playing = <int>{};
  ResumablePlayer() : super(const Size(1080, 1920));
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    positions[++next] = Duration.zero;
    return next;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 90),
      size: const Size(1080, 1920),
    ),
  );
  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions[playerId] = position;
    seeks[playerId] = position;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    playing.remove(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    playing.remove(playerId);
  }

  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
    playing.add(playerId);
  }
}

void main() {
  testWidgets(
    'swiping back reuses the initialized HLS player, buffer and exact position',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final old = VideoPlayerPlatform.instance;
      final native = ResumablePlayer();
      VideoPlayerPlatform.instance = native;
      addTearDown(() => VideoPlayerPlatform.instance = old);
      final progress = PlaybackProgress('http://home');
      var downloads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeedView(
              api: FamilyApi()..server = 'http://home',
              progress: progress,
              items: const [
                {
                  'id': 'a',
                  'title': '视频A',
                  'media_url': '/a.mp4',
                  'stream_url': '/a.m3u8',
                },
                {
                  'id': 'b',
                  'title': '视频B',
                  'media_url': '/b.mp4',
                  'stream_url': '/b.m3u8',
                },
              ],
              favorites: const {},
              downloaded: const {},
              onLike: (_) {},
              onDownload: (_) async {
                downloads++;
              },
              onCollections: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(native.sources.single.uri, 'http://home/a.m3u8');
      expect(native.sources.single.formatHint, VideoFormat.hls);
      expect(native.played, contains(1));
      expect(downloads, 0);
      native.positions[1] = const Duration(seconds: 34);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.drag(find.byType(PageView), const Offset(0, -600));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump(const Duration(seconds: 1));
      expect(native.sources.last.uri, 'http://home/b.m3u8');
      native.positions[2] = const Duration(seconds: 18);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.drag(find.byType(PageView), const Offset(0, 600));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(native.sources.length, 2);
      expect(native.positions[1], const Duration(seconds: 34));
      expect(
        native.seeks,
        isEmpty,
      ); // No seek that would invalidate buffered segments.
      expect(native.played.last, 1);
      expect(native.playing, {1});
      expect(native.disposed, isEmpty);
      expect(downloads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(native.disposed.toSet(), {1, 2});
      await progress.flush();
      expect(
        await PlaybackProgress(
          'http://home',
        ).position('b', const Duration(seconds: 90)),
        const Duration(seconds: 18),
      );
    },
  );
  test(
    'LRU bounds native players and releases inactive players under memory pressure',
    () async {
      SharedPreferences.setMockInitialValues({});
      final old = VideoPlayerPlatform.instance;
      final native = ResumablePlayer();
      VideoPlayerPlatform.instance = native;
      addTearDown(() => VideoPlayerPlatform.instance = old);
      final cache = FeedPlayerCache(capacity: 2);
      final progress = PlaybackProgress('http://home');
      final api = FamilyApi()..server = 'http://home';
      Map<String, dynamic> video(String id) => {
        'id': id,
        'media_url': '/$id.mp4',
      };
      final a = cache.obtain(video('a'), api, progress);
      await a.ready;
      final b = cache.obtain(video('b'), api, progress);
      await b.ready;
      expect(cache.obtain(video('a'), api, progress), same(a));
      final c = cache.obtain(video('c'), api, progress);
      await c.ready;
      expect(b.closed, isTrue);
      expect(a.closed, isFalse);
      expect(native.sources.length, 3);
      cache.releaseInactive(c);
      expect(a.closed, isTrue);
      expect(c.closed, isFalse);
      // Refreshing the signed source must never reuse a stale native player.
      final fresh = cache.obtain(
        {'id': 'c', 'media_url': '/c.mp4?new=1'},
        api,
        progress,
      );
      await fresh.ready;
      expect(c.closed, isTrue);
      expect(
        fresh,
        same(
          cache.obtain({'id': 'c', 'media_url': '/c.mp4?new=1'}, api, progress),
        ),
      );
      await cache.close();
      expect(native.disposed.toSet(), {1, 2, 3, 4});
    },
  );
}
