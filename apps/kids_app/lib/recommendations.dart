import 'dart:math';

/// 会话内稳定的推荐排序：
/// - 分桶：完全没播过的最上面，播过未完播的居中，已完播的最后；
/// - 桶内随机：每个新会话重新洗牌，同会话内保持稳定不跳动；
/// - 刷新时新内容随机并入所在桶，不重排已有内容。
class RecommendationOrder {
  final Random random;
  final List<String> _ids = [];
  RecommendationOrder({Random? random}) : random = random ?? Random();

  int _bucket(Map<String, dynamic> video) {
    final completed = (video['completed_count'] as num?)?.toInt() ?? 0;
    if (completed > 0) return 2;
    final plays = (video['plays'] as num?)?.toInt() ?? 0;
    return plays > 0 ? 1 : 0;
  }

  List<dynamic> arrange(List<dynamic> items) {
    final byId = {for (final item in items) '${item['id']}': item};
    _ids.removeWhere((id) => !byId.containsKey(id));
    final known = _ids.toSet();
    final added =
        byId.keys.where((id) => !known.contains(id)).toList()..shuffle(random);
    _ids.addAll(added);
    final buckets = [<String>[], <String>[], <String>[]];
    for (final id in _ids) {
      buckets[_bucket(Map<String, dynamic>.from(byId[id]!))].add(id);
    }
    return [
      for (final bucket in buckets)
        for (final id in bucket) byId[id]!,
    ];
  }
}
