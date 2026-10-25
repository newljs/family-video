import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_app/playback_disk_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('cache cleanup is explicit and refreshes displayed disk usage', (
    tester,
  ) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlaybackDiskCache.channel, (call) async {
          calls.add(call.method);
          return {
            'bytes': call.method == 'clear' ? 0 : 100 * 1024 * 1024,
            'limitBytes': 2 * 1024 * 1024 * 1024,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlaybackDiskCache.channel, null),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlaybackCachePanel())),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('100.0 MB / 2.0 GB'), findsOneWidget);
    await tester.tap(find.text('清理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(calls, ['stats']);
    await tester.tap(find.text('清理'));
    await tester.pumpAndSettle();
    expect(find.textContaining('离线视频会保留'), findsOneWidget);
    await tester.tap(find.text('清理播放缓存'));
    await tester.pumpAndSettle();
    expect(calls, ['stats', 'clear']);
    expect(find.textContaining('0.0 MB / 2.0 GB'), findsOneWidget);
  });
  testWidgets(
    'unavailable cache statistics never prevent the profile from displaying',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            PlaybackDiskCache.channel,
            (_) async => throw PlatformException(code: 'cache_unavailable'),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(PlaybackDiskCache.channel, null),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PlaybackCachePanel())),
      );
      await tester.pumpAndSettle();
      expect(find.text('播放缓存'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '清理'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
