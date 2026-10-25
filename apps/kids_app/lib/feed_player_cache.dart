import 'dart:async';
import 'dart:io';
import 'package:family_api/family_api.dart';
import 'package:video_player/video_player.dart';
import 'playback_progress.dart';

/// Retain a small number of native players, including their buffers and exact
/// positions. Only FeedView may play them; a cached player never starts itself.
class FeedPlayerCache {
  final int capacity;
  final _players = <String, CachedFeedPlayer>{};
  FeedPlayerCache({this.capacity = 3}) : assert(capacity > 0);

  CachedFeedPlayer obtain(
    Map<String, dynamic> video,
    FamilyApi api,
    PlaybackProgress progress,
  ) {
    final id = '${video['id']}';
    final source = sourceKey(video, api);
    var entry = _players.remove(id);
    if (entry != null &&
        (entry.source != source ||
            entry.failed ||
            entry.closed ||
            entry.controller.value.hasError)) {
      unawaited(entry.close());
      entry = null;
    }
    entry ??= CachedFeedPlayer(video, api, progress, source);
    // A quick swipe can leave load() before it awaits this initialization.
    // Still observe errors from a retained or evicted pending player.
    unawaited(entry.ready.catchError((Object _) {}));
    _players[id] = entry;
    while (_players.length > capacity) {
      final oldest = _players.remove(_players.keys.first)!;
      unawaited(oldest.close());
    }
    return entry;
  }

  static String sourceKey(Map<String, dynamic> video, FamilyApi api) =>
      '${video['local_path'] ?? ''}|${api.server}|${video['stream_url'] ?? ''}|${video['media_url'] ?? ''}';

  void releaseInactive(CachedFeedPlayer? active) {
    for (final id in _players.keys.toList()) {
      final entry = _players[id]!;
      if (!identical(entry, active)) {
        _players.remove(id);
        unawaited(entry.close());
      }
    }
  }

  Future<void> close() async {
    final entries = _players.values.toList();
    _players.clear();
    await Future.wait(entries.map((entry) => entry.close()));
  }
}

class CachedFeedPlayer {
  final String source;
  late VideoPlayerController controller;
  late final Future<void> ready;
  bool closed = false, failed = false;
  Future<void>? _closing;
  final _released = Completer<void>();

  CachedFeedPlayer(
    Map<String, dynamic> video,
    FamilyApi api,
    PlaybackProgress progress,
    this.source,
  ) {
    final streaming =
        video['local_path'] == null && video['stream_url'] != null;
    controller = video['local_path'] != null
        ? VideoPlayerController.file(File(video['local_path']))
        : VideoPlayerController.networkUrl(
            api.uri(streaming ? video['stream_url'] : video['media_url']),
            formatHint: streaming ? VideoFormat.hls : null,
          );
    ready = _initialize(video, api, progress, streaming);
  }

  void _checkOpen() {
    if (closed) throw StateError('Player released');
  }

  Future<void> _initialize(
    Map<String, dynamic> video,
    FamilyApi api,
    PlaybackProgress progress,
    bool streaming,
  ) async {
    try {
      try {
        await _waitForInitialization(controller);
      } catch (_) {
        _checkOpen();
        if (!streaming) rethrow;
        await controller.dispose();
        _checkOpen();
        controller = VideoPlayerController.networkUrl(
          api.uri(video['media_url']),
        );
        await _waitForInitialization(controller);
      }
      _checkOpen();
      await controller.setLooping(true);
      final position = await progress.position(
        '${video['id']}',
        controller.value.duration,
      );
      _checkOpen();
      if (position > Duration.zero) await controller.seekTo(position);
      _checkOpen();
    } catch (_) {
      failed = true;
      rethrow;
    }
  }

  Future<void> _waitForInitialization(VideoPlayerController current) async {
    final timedOut = Completer<void>();
    final timer = Timer(const Duration(seconds: 25), () {
      timedOut.completeError(
        TimeoutException('Video initialization timed out'),
      );
    });
    try {
      await Future.any<void>([
        current.initialize(),
        timedOut.future,
        _released.future.then((_) => throw StateError('Player released')),
      ]);
    } finally {
      timer.cancel();
    }
  }

  Future<void> close() {
    closed = true;
    if (!_released.isCompleted) _released.complete();
    return _closing ??= _dispose();
  }

  Future<void> _dispose() async {
    try {
      await controller.pause();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }
}
