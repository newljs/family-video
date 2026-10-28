import 'package:flutter_test/flutter_test.dart';
import 'package:kids_app/watch_sampler.dart';

void main() {
  test('2x playback charges wall time while seeks and pauses do not count', () {
    final sampler = WatchSampler();
    final start = DateTime(2026, 10, 26);
    Duration sample(
      int ms,
      int position, {
      bool playing = true,
      bool buffering = false,
    }) => sampler.sample(
      at: start.add(Duration(milliseconds: ms)),
      position: Duration(milliseconds: position),
      playing: playing,
      buffering: buffering,
      speed: 2,
    );
    expect(sample(0, 0), Duration.zero);
    expect(sample(1000, 2000), const Duration(seconds: 1));
    expect(sample(1100, 60000), Duration.zero); // seek ahead
    expect(sample(2100, 62000, playing: false), const Duration(seconds: 1));
    expect(sample(3100, 62000), Duration.zero); // paused interval
    expect(sample(4100, 64000, buffering: true), const Duration(seconds: 1));
    expect(sample(5100, 64000), Duration.zero); // stalled interval
    sampler.reset();
    expect(sample(6100, 1000), Duration.zero);
  });
}
