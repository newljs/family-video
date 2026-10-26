import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_app/feed.dart';
import 'package:kids_app/time_budget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakePlayer extends VideoPlayerPlatform {
  int playCalls = 0, pauseCalls = 0;
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
  Future<void> play(int playerId) async => playCalls++;
  @override
  Future<void> pause(int playerId) async => pauseCalls++;
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

TimeBudget budgetWith(int limitMinutes, int watchedMs) {
  final budget = TimeBudget(FamilyApi());
  budget.apply({
    'limit_minutes': limitMinutes,
    'watched_ms_today': watchedMs,
    'day': today(),
  });
  return budget;
}

Widget harness(TimeBudget budget) => MaterialApp(
  home: Scaffold(
    body: FeedView(
      api: FamilyApi(),
      items: [
        {
          'id': 'v1',
          'title': '认识大自然',
          'media_url': '/media/v1/video',
          'local_path': '/tmp/cache/v1.mp4',
        },
      ],
      favorites: const {},
      downloaded: const {},
      onLike: (_) {},
      onDownload: (_) async {},
      onCollections: () {},
      budget: budget,
    ),
  ),
);

void main() {
  final savedPlatform = VideoPlayerPlatform.instance;
  late FakePlayer platform;
  setUp(() {
    platform = FakePlayer();
    VideoPlayerPlatform.instance = platform;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => VideoPlayerPlatform.instance = savedPlatform);

  testWidgets('限额内正常自动播放，顶部显示剩余时长角标', (tester) async {
    await tester.pumpWidget(harness(budgetWith(10, 0)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
    expect(platform.playCalls, greaterThanOrEqualTo(1));
    expect(find.text('还能看 10 分钟'), findsOneWidget);
    expect(find.byType(VideoPlayer), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('额度用完进入安静模式：不暂停、无提示、角标隐藏', (tester) async {
    final budget = budgetWith(10, 9 * 60000);
    await tester.pumpWidget(harness(budget));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
    expect(platform.playCalls, greaterThanOrEqualTo(1));
    // 初始化阶段控制器自身可能同步一次暂停，与预算无关；记录基线。
    final pausesBefore = platform.pauseCalls;
    budget.spend(60000);
    await tester.pump();
    // 无感知：额度用完不触发任何额外暂停，也没有超时提示。
    expect(platform.pauseCalls, pausesBefore);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.text('今天的时间看完啦\n明天再来看吧'), findsNothing);
    expect(find.byType(RemainingBadge), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('未设置限额时不显示角标，也不阻止播放', (tester) async {
    await tester.pumpWidget(harness(budgetWith(0, 0)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
    expect(platform.playCalls, greaterThanOrEqualTo(1));
    expect(find.byType(RemainingBadge), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
