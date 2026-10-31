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
import 'package:kids_app/pages.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeDownloads extends Downloads {
  FakeDownloads(super.api);
  @override
  Future<List<dynamic>> list() async => <dynamic>[];
}

class FakePlayer extends VideoPlayerPlatform {
  final pauses = <StackTrace>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 1;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) async* {
    yield VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 90),
      size: const Size(1080, 1920),
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
  Future<void> pause(int playerId) async {
    pauses.add(StackTrace.current);
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}

String today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

final ordinary = [
  {
    'id': 'v1',
    'title': '普通视频一',
    'media_url': '/media/v1/video',
    'local_path': '/tmp/v1.mp4',
  },
  {
    'id': 'v2',
    'title': '普通视频二',
    'media_url': '/media/v2/video',
    'local_path': '/tmp/v2.mp4',
  },
];
final designated = [
  {
    'id': 'd1',
    'title': '睡前故事一',
    'media_url': '/media/d1/video',
    'local_path': '/tmp/d1.mp4',
  },
  {
    'id': 'd2',
    'title': '睡前故事二',
    'media_url': '/media/d2/video',
    'local_path': '/tmp/d2.mp4',
  },
];

FamilyApi apiWith(String afterLimitId) => FamilyApi(
  client: MockClient((r) async {
    final body = switch (r.url.path) {
      '/health' => {
        'access_mode': 'open_lan',
        'content_mode': 'direct',
        'library_mode': 'managed',
      },
      // 目录故意返回未过滤的全量数据：验证安静模式由客户端本地切换。
      '/api/videos' => ordinary,
      '/api/collections' => [
        {'id': 'c1', 'title': '睡前合集', 'videos': designated},
      ],
      '/api/settings/time-limit' => {
        'limit_minutes': 10,
        'watched_ms_today': 10 * 60000,
        'day': today(),
        'after_limit_collection_id': afterLimitId,
        'exhausted': true,
      },
      _ => <String, dynamic>{},
    };
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }),
)..server = 'http://home:8765';

void main() {
  final savedPlatform = VideoPlayerPlatform.instance;
  setUp(() {
    VideoPlayerPlatform.instance = FakePlayer();
    SharedPreferences.setMockInitialValues({'server': 'http://home:8765'});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => VideoPlayerPlatform.instance = savedPlatform);

  testWidgets('额度用完后推荐流安静收缩为指定合集，无任何提示', (tester) async {
    final api = apiWith('c1');
    await tester.pumpWidget(
      MaterialApp(home: KidsHome(api: api, downloads: FakeDownloads(api))),
    );
    await tester.pumpAndSettle();
    // 服务端返回的仍是全量目录，但预算耗尽后本地列表只剩指定合集。
    final feed = tester.widget<FeedView>(find.byType(FeedView));
    expect(feed.items.map((v) => '${v['id']}').toList(), ['d1', 'd2']);
    expect(find.text('睡前故事一'), findsOneWidget);
    expect(find.text('普通视频一'), findsNothing);
  });

  testWidgets('额度用完且未指定合集时，推荐流看起来只是没有内容了', (tester) async {
    final api = apiWith('');
    await tester.pumpWidget(
      MaterialApp(home: KidsHome(api: api, downloads: FakeDownloads(api))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FeedView), findsNothing);
    expect(find.byType(KidsEmptyState), findsOneWidget);
    expect(find.text('今天的时间看完啦'), findsNothing);
  });

  test('已看完的视频不进入推荐流', () {
    final items = [
      {'id': 'unseen', 'completed_count': 0},
      {'id': 'seen', 'completed_count': 1},
      {'id': 'old-server', 'plays': 2},
    ];
    expect(unwatchedFeedItems(items).map((v) => '${v['id']}').toList(), [
      'unseen',
      'old-server',
    ]);
  });

  test('预览页在额度用完后只保留当前视频和指定合集', () {
    final initial = [...ordinary, ...designated];
    final shrunk = previewFeedItems(
      initial: initial,
      currentId: 'v2',
      quietPool: designated,
      exhausted: true,
    );
    expect(shrunk.map((v) => '${v['id']}').toList(), ['v2', 'd1', 'd2']);
    expect(
      previewFeedItems(
        initial: initial,
        currentId: 'v2',
        quietPool: designated,
        exhausted: false,
      ).length,
      4,
    );
  });
}
