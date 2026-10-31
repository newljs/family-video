import 'dart:async';
import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

/// 每日观看时长额度：家长端设定限额（0 为不限制），服务端按天累计真实观看时长。
/// 额度用完后不做任何提示，而是安静收缩：推荐流只剩家长指定的合集内容
/// （afterLimitCollectionId 为空则整体隐藏）。播放中本地即时扣减，服务端每批
/// 上报确认后校正；离线时沿用最近一次缓存的限额与用量，跨进程重启仍然生效。
/// 换天后额度自动清零。
class TimeBudget extends ChangeNotifier {
  TimeBudget(this.api);
  final FamilyApi api;

  int limitMinutes = 0; // 0 = 不限制；拿到服务端数据前按不限制处理
  int watchedMsToday = 0;
  String afterLimitCollectionId = '';
  String day = _today();
  String _localDay = _today();
  int _unsavedSpends = 0;
  bool _synced = false;

  bool get limited => limitMinutes > 0;
  bool get exhausted => limited && remainingMs <= 0;
  int get remainingMs => limitMinutes * 60000 - watchedMsToday;
  int get watchedMinutes => watchedMsToday ~/ 60000;
  int get remainingMinutes =>
      remainingMs <= 0 ? 0 : (remainingMs + 59999) ~/ 60000;

  String get _cacheKey => 'time_budget_$server';
  String get server => api.server;

  void reset() {
    limitMinutes = 0;
    watchedMsToday = 0;
    afterLimitCollectionId = '';
    day = _today();
    _localDay = _today();
    _unsavedSpends = 0;
    _synced = false;
    notifyListeners();
  }

  /// 启动时先恢复本地缓存：离线或服务端还没响应时，也能执行上次的限额。
  Future<void> restoreCached() async {
    if (server.isEmpty) return;
    final restoringServer = server;
    final key = _cacheKey;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (server != restoringServer) return;
      if (raw == null) return;
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      limitMinutes = (saved['limit_minutes'] as num?)?.toInt() ?? 0;
      afterLimitCollectionId = '${saved['after_limit_collection_id'] ?? ''}';
      watchedMsToday =
          '${saved['day']}' == _today()
              ? (saved['watched_ms'] as num?)?.toInt() ?? 0
              : 0;
      day = _today();
      _localDay = _today();
      _synced = false;
      notifyListeners();
    } catch (_) {
      /* 缓存损坏按未设置处理，不影响播放。 */
    }
  }

  /// 从服务端读取限额与今日已看；失败时静默保留现有额度。
  Future<void> load() async {
    final loadingServer = server;
    try {
      final data = await api.requestWithTimeout(
        'GET',
        '/api/settings/time-limit',
        timeout: const Duration(seconds: 5),
      );
      if (data is Map && server == loadingServer) {
        apply(Map<String, dynamic>.from(data));
      }
    } catch (_) {
      /* 旧服务端没有该接口或暂时离线：保持本地口径。 */
    }
  }

  /// 用服务端口径校正本地计数。服务端可能同时记录了其他设备的观看，
  /// 因此取两边的较大值；日期变化（换天）时以服务端为准重新开始。
  void apply(Map<dynamic, dynamic> data) {
    final nextDay = '${data['day']}';
    final serverWatched = (data['watched_ms_today'] as num?)?.toInt() ?? 0;
    _synced = true;
    if (nextDay != day) {
      day = nextDay;
      watchedMsToday = serverWatched;
    } else if (serverWatched > watchedMsToday) {
      watchedMsToday = serverWatched;
    }
    limitMinutes = (data['limit_minutes'] as num?)?.toInt() ?? 0;
    afterLimitCollectionId = '${data['after_limit_collection_id'] ?? ''}';
    _unsavedSpends = 0;
    notifyListeners();
    _cache();
  }

  /// 播放中的本地即时扣减；随后由服务端上报响应校正。
  void spend(int ms) {
    if (ms <= 0 || exhausted) return;
    watchedMsToday += ms;
    // 每 30 秒左右落一次盘，离线中断后重启不至于重新获得额度。
    if (++_unsavedSpends >= 15) _cache();
    notifyListeners();
  }

  /// 换天检测：拿到服务端日期后以服务端为准，避免设备时区/时钟造成错位；
  /// 仅在尚未成功同步时按本地日期做离线兜底。
  void tick() {
    final now = _today();
    if (now == _localDay) return;
    final previous = _localDay;
    _localDay = now;
    if (!_synced || day == previous) {
      // 同一时区的正常换天；服务端日期不同（时区错位）时改为向服务端确认。
      day = now;
      watchedMsToday = 0;
      notifyListeners();
      _cache();
      return;
    }
    unawaited(load());
  }

  Future<void> _cache() async {
    if (server.isEmpty) return;
    _unsavedSpends = 0;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _cacheKey,
        jsonEncode({
          'limit_minutes': limitMinutes,
          'watched_ms': watchedMsToday,
          'after_limit_collection_id': afterLimitCollectionId,
          'day': day,
        }),
      );
    } catch (_) {
      /* 缓存失败只影响离线重启后的连续性。 */
    }
  }
}
