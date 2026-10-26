import 'dart:async';
import 'package:family_api/family_api.dart';

class _Pending {
  int watchedMs = 0;
  bool played = false;
  bool completed = false;

  void merge(_Pending other) {
    watchedMs += other.watchedMs;
    played = played || other.played;
    completed = completed || other.completed;
  }
}

/// 观看统计批量上报：进程内按视频聚合，每 30 秒一批发往服务器；
/// 失败时数据保留合并进下一批，绝不丢失也绝不阻塞播放。
/// 服务端响应携带每日时长额度（限额与今日已看），经 onSync 回传给预算。
class WatchReporter {
  final FamilyApi api;
  final void Function(Map<dynamic, dynamic> data)? onSync;
  final Map<String, _Pending> _pending = {};
  Timer? _timer;
  bool _sending = false;

  WatchReporter(this.api, {this.onSync}) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => flush());
  }

  void record(
    String videoId, {
    Duration watched = Duration.zero,
    bool played = false,
    bool completed = false,
  }) {
    if (videoId.isEmpty) return;
    final pending = _pending.putIfAbsent(videoId, _Pending.new);
    pending.watchedMs += watched.inMilliseconds;
    pending.played = pending.played || played;
    pending.completed = pending.completed || completed;
  }

  Future<void> flush() async {
    if (_sending || _pending.isEmpty) return;
    final batch = Map<String, _Pending>.from(_pending);
    _pending.clear();
    _sending = true;
    try {
      final result = await api.request('POST', '/api/watch', {
        'reports': [
          for (final entry in batch.entries)
            {
              'video_id': entry.key,
              'watched_ms': entry.value.watchedMs,
              'played': entry.value.played,
              'completed': entry.value.completed,
            },
        ],
      });
      if (result is Map) onSync?.call(result);
    } catch (_) {
      // 服务器暂时不可达：内容退回队列，30 秒后随下批重试。
      batch.forEach((id, pending) {
        _pending.putIfAbsent(id, _Pending.new).merge(pending);
      });
    } finally {
      _sending = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    unawaited(flush());
  }
}
