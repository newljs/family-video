import 'dart:async';
import 'package:flutter/foundation.dart';

/// One refresh at a time, with bounded retries only while the app is active.
class BackgroundSync extends ChangeNotifier {
  BackgroundSync(this.refresh);
  final Future<void> Function() refresh;
  bool syncing = false;
  bool? online;
  Object? error;
  bool _active = true, _disposed = false;
  int _generation = 0, _failures = 0;
  Timer? _retry;
  Future<void>? _pending;
  int get generation => _generation;

  Future<void> run({Future<void> Function()? action}) {
    if (_disposed) return Future.value();
    return _pending ??= _run(action ?? refresh, _generation);
  }

  Future<void> _run(Future<void> Function() action, int generation) async {
    _retry?.cancel();
    syncing = true;
    notifyListeners();
    try {
      await action();
      if (_disposed || generation != _generation) return;
      online = true;
      error = null;
      _failures = 0;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      online = false;
      error = e;
      const delays = [5, 15, 30, 60];
      final delay = delays[_failures.clamp(0, delays.length - 1)];
      _failures++;
      if (_active) {
        _retry = Timer(Duration(seconds: delay), () => unawaited(run()));
      }
    } finally {
      if (!_disposed && generation == _generation) {
        syncing = false;
        _pending = null;
        notifyListeners();
      }
    }
  }

  void setActive(bool active) {
    _active = active;
    if (!active) {
      _retry?.cancel();
    }
  }

  void reset() {
    _generation++;
    _retry?.cancel();
    _pending = null;
    syncing = false;
    online = null;
    error = null;
    _failures = 0;
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    super.dispose();
  }
}
