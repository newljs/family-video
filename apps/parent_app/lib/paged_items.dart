import 'dart:math' as math;
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';

typedef PageLoader =
    Future<ListPage> Function(int offset, int limit, Map<String, String> query);

class ListPage {
  final List<dynamic> items;
  final int total, active;
  const ListPage(this.items, this.total, {this.active = 0});

  factory ListPage.from(dynamic data) {
    // Older services return arrays. They remain usable as a local catalog.
    if (data is List) return ListPage(data, data.length);
    return ListPage(
      data['items'] as List,
      (data['total'] as num).toInt(),
      active: (data['active'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A page is replaced atomically on refresh; stale searches cannot overwrite it.
class PagedItems extends ChangeNotifier {
  final int pageSize;
  final PageLoader? loader;
  List<dynamic> items = [], source = [];
  int total = 0, _offset = 0, _generation = 0;
  bool loading = false, _disposed = false;
  bool _retryRefresh = false;
  String? error;
  Map<String, String> query = {};
  PagedItems({this.loader, this.pageSize = 20});

  bool get hasMore => _offset < total;
  void seed(List<dynamic> values, int? count) {
    _generation++;
    source = values;
    items = values.take(pageSize).toList();
    total = count ?? values.length;
    _offset = items.length;
    loading = false;
    error = null;
  }

  Future<void> refresh({Map<String, String>? query}) async {
    final reset = query != null;
    if (query != null) this.query = query;
    final target = reset ? pageSize : math.max(pageSize, _offset);
    if (reset) {
      items = [];
      _offset = 0;
      total = 0;
    }
    await _read(replace: true, target: target);
  }

  Future<void> more() async {
    if (loading || !hasMore) return;
    await _read(replace: false, target: pageSize);
  }

  Future<void> retry() => _retryRefresh ? refresh() : more();

  Future<void> _read({required bool replace, required int target}) async {
    final generation = replace ? ++_generation : _generation;
    loading = true;
    _retryRefresh = replace;
    error = null;
    notifyListeners();
    try {
      var offset = replace ? 0 : _offset;
      var count = total;
      final loaded = <dynamic>[];
      do {
        final limit = math.min(pageSize, target - loaded.length);
        final page =
            loader == null
                ? ListPage(
                  source.skip(offset).take(limit).toList(),
                  source.length,
                )
                : await loader!(offset, limit, Map.of(query));
        if (_disposed || generation != _generation) return;
        loaded.addAll(page.items);
        count = page.total;
        offset += page.items.length;
        if (page.items.isEmpty) {
          count = offset;
          break;
        }
      } while (replace && loaded.length < target && offset < count);
      if (_disposed || generation != _generation) return;
      final byId = <Object, dynamic>{};
      for (final item in [if (!replace) ...items, ...loaded]) {
        byId[item['id'] ?? item] = item;
      }
      items = byId.values.toList();
      _offset = offset;
      total = count;
    } catch (e) {
      if (!_disposed && generation == _generation) error = friendlyError(e);
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

class PageFooter extends StatelessWidget {
  final PagedItems page;
  const PageFooter(this.page, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Center(
      child:
          page.loading
              ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(),
              )
              : page.error != null
              ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(page.error!, textAlign: TextAlign.center),
                  TextButton(
                    onPressed: page.retry,
                    child: const Text('加载失败，点击重试'),
                  ),
                ],
              )
              : page.hasMore
              ? TextButton(onPressed: page.more, child: const Text('上拉加载更多'))
              : Text(
                '已加载全部 ${page.total} 条',
                style: Theme.of(context).textTheme.bodySmall,
              ),
    ),
  );
}
