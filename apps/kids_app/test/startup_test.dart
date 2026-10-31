import 'dart:async';
import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kids_app/app_home.dart';
import 'package:kids_app/downloads.dart';
import 'package:kids_app/feed.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'connected_feed_test.dart' show FakePlayer;

class EmptyDownloads extends Downloads {
  EmptyDownloads(super.api);
  @override
  Future<List<dynamic>> list() async => [];
}

class CountingPlayer extends FakePlayer {
  CountingPlayer() : super(const Size(1080, 1920));
  int created = 0;
  int plays = 0;
  final List<String?> urls = [];
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    urls.add(options.dataSource.uri);
    return ++created;
  }

  @override
  Future<void> play(int playerId) async {
    plays++;
  }
}

const home = 'http://home:8765';
const health = {
  'access_mode': 'open_lan',
  'content_mode': 'direct',
  'library_mode': 'managed',
};
final cached = {
  'id': 'v1',
  'title': '上次的视频',
  'media_url': '/media/v1/video?sig=expired',
};
final fresh = {
  'id': 'v1',
  'title': '更新后的视频',
  'media_url': '/media/v1/video?sig=fresh',
};
http.Response response(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> seedCache({bool exhausted = false}) async {
  SharedPreferences.setMockInitialValues({'server': home});
  FlutterSecureStorage.setMockInitialValues({});
  final cache = StartupCache(home, 'child');
  await cache.write('videos', [cached]);
  await cache.write('last_video', 'v1');
  await cache.write('collections', [
    {
      'id': 'c1',
      'title': '保存的合集',
      'videos': [
        {
          'id': 'safe',
          'title': '额度内保留的故事',
          'media_url': '/media/safe/video?sig=old',
        },
      ],
    },
  ]);
  if (exhausted) {
    final now = DateTime.now();
    final day =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    await (await SharedPreferences.getInstance()).setString(
      'time_budget_$home',
      jsonEncode({
        'day': day,
        'limit_minutes': 1,
        'watched_ms': 60000,
        'after_limit_collection_id': 'c1',
      }),
    );
  }
}

void main() {
  testWidgets(
    'without a snapshot an offline server shows an empty home with working navigation',
    (tester) async {
      SharedPreferences.setMockInitialValues({'server': home});
      FlutterSecureStorage.setMockInitialValues({});
      final gate = Completer<void>();
      final api = FamilyApi(
        client: MockClient((r) async {
          await gate.future;
          return response(r.url.path == '/health' ? health : []);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: KidsHome(api: api, downloads: EmptyDownloads(api))),
      );
      await tester.pumpAndSettle();
      // 目录刷新为 30 秒截止 + 一次自动重试（约 60.4 秒），离线错误态在
      // 两轮尝试都失败后才出现。
      await tester.pump(const Duration(seconds: 62));
      await tester.pumpAndSettle();
      expect(find.text('暂时连接不上家庭电脑'), findsOneWidget);
      expect(find.text('首页'), findsOneWidget);
      expect(find.text('进入放映室'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'cached home and navigation appear while all server requests are pending',
    (tester) async {
      await seedCache();
      final gate = Completer<void>();
      final api = FamilyApi(
        client: MockClient((r) async {
          await gate.future;
          return response(r.url.path == '/health' ? health : []);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: KidsHome(api: api, downloads: EmptyDownloads(api))),
      );
      await tester.pumpAndSettle();
      expect(find.text('上次的视频'), findsOneWidget);
      expect(find.text('进入放映室'), findsNothing);
      expect(
        find.byType(VideoPlayer),
        findsNothing,
      ); // Expired URLs are not opened.
      await tester.tap(find.text('合集').last);
      await tester.pumpAndSettle();
      expect(find.text('保存的合集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'saved allowance filters cached videos before the first visible home',
    (tester) async {
      await seedCache(exhausted: true);
      final gate = Completer<void>();
      final api = FamilyApi(
        client: MockClient((r) async {
          await gate.future;
          return response(r.url.path == '/health' ? health : []);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: KidsHome(api: api, downloads: EmptyDownloads(api))),
      );
      await tester.pumpAndSettle();
      expect(find.text('上次的视频'), findsNothing);
      expect(find.text('额度内保留的故事'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'fresh videos play before slow collections and later sync keeps the player',
    (tester) async {
      await seedCache();
      final previous = VideoPlayerPlatform.instance;
      final player = CountingPlayer();
      VideoPlayerPlatform.instance = player;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final videos = Completer<http.Response>();
      final collections = Completer<http.Response>();
      var refreshed = false;
      final api = FamilyApi(
        client: MockClient((r) async {
          if (r.url.path == '/health') return response(health);
          if (r.url.path == '/api/videos') {
            return refreshed
                ? response([
                  {
                    'id': 'new',
                    'title': '新视频',
                    'media_url': '/media/new/video?sig=fresh',
                    'plays': 0,
                  },
                  {
                    ...fresh,
                    'plays': 1,
                    'media_url': '/media/v1/video?sig=rotated&expires=12345',
                  },
                ])
                : videos.future;
          }
          if (r.url.path == '/api/collections') return collections.future;
          return response({});
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: KidsHome(api: api, downloads: EmptyDownloads(api))),
      );
      await tester.pumpAndSettle();
      expect(player.created, 0);
      videos.complete(response([fresh]));
      await tester.pumpAndSettle();
      expect(find.byType(FeedView), findsOneWidget);
      expect(player.created, 1);
      expect(player.urls.single, contains('sig=fresh'));
      collections.complete(response([]));
      await tester.pumpAndSettle();
      expect(player.created, 1);
      final plays = player.plays;
      refreshed = true;
      await tester.widget<FeedView>(find.byType(FeedView)).onLoadLatest!();
      await tester.pumpAndSettle();
      expect(player.created, 1);
      expect(
        player.plays,
        plays,
      ); // A rotated authorization doesn't restart playback.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'latest refresh exits after one deadline and retries without restart',
    (tester) async {
      await seedCache();
      final previous = VideoPlayerPlatform.instance;
      final player = CountingPlayer();
      VideoPlayerPlatform.instance = player;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      var stalled = false;
      final gate = Completer<void>();
      final api = FamilyApi(
        client: MockClient((r) async {
          if (r.url.path == '/health') return response(health);
          if (stalled &&
              (r.url.path == '/api/videos' ||
                  r.url.path == '/api/collections')) {
            await gate.future;
          }
          if (r.url.path == '/api/videos') return response([fresh]);
          if (r.url.path == '/api/collections') return response([]);
          return response({});
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: KidsHome(api: api, downloads: EmptyDownloads(api))),
      );
      await tester.pumpAndSettle();
      final dynamic feed = tester.state(find.byType(FeedView));

      stalled = true;
      unawaited(feed.loadLatest());
      await tester.pump();
      expect(find.byType(LoadingLatestBadge), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(find.byType(LoadingLatestBadge), findsNothing);

      stalled = false;
      unawaited(feed.loadLatest());
      await tester.pumpAndSettle();
      expect(find.byType(LoadingLatestBadge), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pump();
    },
  );
}
