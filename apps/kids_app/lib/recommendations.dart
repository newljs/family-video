import 'dart:math';

/// Stable for one app session. Refreshes merge new items without reshuffling.
class RecommendationOrder {
  final Random random;
  final List<String> _ids = [];
  RecommendationOrder({Random? random}) : random = random ?? Random();
  List<dynamic> arrange(List<dynamic> items) {
    final byId = {for (final item in items) '${item['id']}': item};
    _ids.removeWhere((id) => !byId.containsKey(id));
    final added = byId.keys.where((id) => !_ids.contains(id)).toList()
      ..shuffle(random);
    _ids.addAll(added);
    return [for (final id in _ids) byId[id]];
  }
}
