import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_app/playback_progress.dart';
import 'package:kids_app/recommendations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'positions persist per video and server and completed clips restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = PlaybackProgress('http://home');
      await first.ready;
      first.record(
        'a',
        const Duration(seconds: 34),
        const Duration(seconds: 90),
      );
      first.record(
        'b',
        const Duration(seconds: 18),
        const Duration(seconds: 60),
      );
      await first.flush();
      final restored = PlaybackProgress('http://home');
      expect(
        await restored.position('a', const Duration(seconds: 90)),
        const Duration(seconds: 34),
      );
      expect(
        await restored.position('b', const Duration(seconds: 60)),
        const Duration(seconds: 18),
      );
      expect(
        await PlaybackProgress(
          'http://other',
        ).position('a', const Duration(seconds: 90)),
        Duration.zero,
      );
      restored.record(
        'a',
        const Duration(seconds: 90),
        const Duration(seconds: 90),
      );
      expect(
        await restored.position('a', const Duration(seconds: 90)),
        Duration.zero,
      );
      // An old position cannot seek past the end of a replaced/shorter file.
      expect(
        await restored.position('b', const Duration(seconds: 10)),
        Duration.zero,
      );
    },
  );
  test(
    'random recommendations remain stable on refresh and leave source order untouched',
    () {
      final source = List.generate(
        12,
        (i) => {'id': '$i', 'title': 'video $i'},
      );
      final order = RecommendationOrder(random: Random(42));
      final first = order.arrange(source).map((v) => v['id']).toList();
      expect(first.toSet(), source.map((v) => v['id']).toSet());
      expect(first, isNot(orderedEquals(source.map((v) => v['id']))));
      expect(
        order.arrange(source.reversed.toList()).map((v) => v['id']),
        orderedEquals(first),
      );
      expect(source.first['id'], '0');
      final second = RecommendationOrder(random: Random(13));
      expect(
        second.arrange(source).map((v) => v['id']),
        isNot(orderedEquals(first)),
      );
      final remaining = source.where((v) => v['id'] != '3').toList()
        ..add({'id': 'new'});
      expect(
        order.arrange(remaining).map((v) => v['id']),
        orderedEquals([...first.where((id) => id != '3'), 'new']),
      );
    },
  );
}
