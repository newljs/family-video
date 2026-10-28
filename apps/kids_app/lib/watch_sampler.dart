import 'dart:math';

/// Count elapsed viewing time, excluding seek jumps, pauses and buffering.
/// At 2x speed, two seconds of media consume one second of viewing allowance.
class WatchSampler {
  DateTime? _at;
  Duration _position = Duration.zero;
  bool _playing = false;
  double _speed = 1;

  void reset() {
    _at = null;
    _playing = false;
  }

  Duration sample({
    required DateTime at,
    required Duration position,
    required bool playing,
    required bool buffering,
    double speed = 1,
  }) {
    final elapsed = _at == null ? 0 : at.difference(_at!).inMilliseconds;
    final advanced = (position - _position).inMilliseconds;
    var watched = 0;
    if (_playing &&
        elapsed > 0 &&
        elapsed <= 5000 &&
        advanced > 0 &&
        advanced <= elapsed * _speed + 1500) {
      watched = min(elapsed, (advanced / _speed).round());
    }
    _at = at;
    _position = position;
    _playing = playing && !buffering;
    _speed = speed > 0 ? speed : 1;
    return Duration(milliseconds: watched);
  }
}
