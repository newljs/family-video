import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parent_app/inbox_page.dart';
import 'package:parent_app/library_panel.dart';
import 'package:parent_app/paged_items.dart';
import 'package:parent_app/ui.dart';

List<Map<String, dynamic>> rows(int count) => List.generate(
  count,
  (i) => {
    'id': '$i',
    'title': '内容 $i',
    'text': '链接 $i',
    'state': i == count - 1 ? 'failed' : 'completed',
    'kind': 'upload',
  },
);

Future<void> reachBottom(WidgetTester tester) async {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).last);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pumpAndSettle();
}

void main() {
  test('failed search keeps seeded rows available offline', () async {
    final data = rows(5);
    final page = PagedItems(
      loader: (offset, limit, query) async {
        throw Exception('电脑暂时离线');
      },
    )..seed(data.take(3).toList(), data.length);
    addTearDown(page.dispose);
    await page.refresh(query: {'search': '内容 1'});
    expect(page.error, contains('离线'));
    expect(page.items.single['id'], '1');
    expect(page.total, 1);
  });

  test(
    'failed next page keeps rows and retries the same offset without duplicates',
    () async {
      final data = rows(45);
      final offsets = <int>[];
      var fail = true;
      final page = PagedItems(
        loader: (offset, limit, query) async {
          offsets.add(offset);
          if (fail) throw Exception('电脑暂时离线');
          return ListPage(data.skip(offset).take(limit).toList(), data.length);
        },
      )..seed(data.take(20).toList(), data.length);
      addTearDown(page.dispose);
      await page.more();
      expect(page.items.length, 20);
      expect(page.error, contains('离线'));
      fail = false;
      await Future.wait([page.retry(), page.more()]);
      expect(offsets, [20, 20]);
      expect(page.items.length, 40);
      expect(page.items.map((v) => v['id']).toSet().length, 40);
      await page.more();
      expect(page.items.length, 45);
      expect(page.hasMore, isFalse);
    },
  );

  test('slow old filter cannot overwrite the newest results', () async {
    final old = Completer<ListPage>();
    final page = PagedItems(
      loader: (offset, limit, query) async {
        if (query['filter'] == 'failed') return old.future;
        return const ListPage([
          {'id': 'new', 'title': '完成'},
        ], 1);
      },
    );
    addTearDown(page.dispose);
    final pending = page.refresh(query: {'filter': 'failed'});
    await page.refresh(query: {'filter': 'completed'});
    old.complete(
      const ListPage([
        {'id': 'old', 'title': '失败'},
      ], 1),
    );
    await pending;
    expect(page.items.single['id'], 'new');
    expect(page.loading, isFalse);
  });

  test('refresh rebuilds all loaded pages and removes deleted rows', () async {
    final data = rows(55);
    final page = PagedItems(
      loader:
          (offset, limit, query) async =>
              ListPage(data.skip(offset).take(limit).toList(), data.length),
    )..seed(data.take(20).toList(), data.length);
    addTearDown(page.dispose);
    await page.more();
    data.removeAt(2);
    await page.refresh();
    expect(page.items.length, 40);
    expect(page.total, 54);
    expect(page.items.any((v) => v['id'] == '2'), isFalse);
    expect(page.items.last['id'], '40');
  });

  testWidgets('inbox loads another local page while sync stays at the bottom', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var syncs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('待同步收集箱')),
          body: InboxPage(
            items: rows(61),
            busy: false,
            connected: true,
            onRemove: (_) async {},
            onSync: () => syncs++,
            onConnect: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Flutter 3.29 的 FilledButton.icon 返回私有子类，find.byType(FilledButton)
    // 匹配不到；3.44 起返回基类。用 is 谓词在两个工具链下都成立。
    final sync = find.ancestor(
      of: find.text('同步 61 条到家庭电脑'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    final position = tester.getRect(sync);
    expect(find.text('61 条待同步 · 已显示 20 条'), findsOneWidget);
    await reachBottom(tester);
    expect(find.text('61 条待同步 · 已显示 40 条'), findsOneWidget);
    expect(tester.getRect(sync), position);
    await tester.tap(sync);
    expect(syncs, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'task pages append and filters stay visible and search all tasks',
    (tester) async {
      final data = rows(65);
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskPanel(
              paged: true,
              tasks: data.take(20).toList(),
              total: data.length,
              busy: false,
              onCancel: (_) {},
              onRetry: (_) {},
              onLibrary: () {},
              loadPage: (offset, limit, query) async {
                calls.add('$offset:${query['filter'] ?? 'all'}');
                final matched =
                    query['filter'] == 'failed'
                        ? data.where((v) => v['state'] == 'failed').toList()
                        : data;
                return ListPage(
                  matched.skip(offset).take(limit).toList(),
                  matched.length,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final filter = find.widgetWithText(ChoiceChip, '失败');
      final position = tester.getRect(filter);
      await reachBottom(tester);
      expect(calls, ['20:all']);
      expect(tester.getRect(filter), position);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(calls.last, '0:failed');
      expect(find.text('内容 64'), findsOneWidget);
      expect(find.text('内容 0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library pages on scroll and searches beyond the loaded rows on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = rows(60);
      final offsets = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPanel(
              videos: data.take(24).toList(),
              total: data.length,
              collections: const [],
              busy: false,
              url: (v) => v,
              onPreview: (_) {},
              onEdit: (_, _) async {},
              onDelete: (_) async {},
              onBatchCollect: (_, _, _) async {},
              onBatchDelete: (_) async {},
              loadPage: (offset, limit, query) async {
                offsets.add(offset);
                final search = query['search'] ?? '';
                final matched =
                    data
                        .where((v) => '${v['title']}'.contains(search))
                        .toList();
                return ListPage(
                  matched.skip(offset).take(limit).toList(),
                  matched.length,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已加载 24 / 60 条视频'), findsOneWidget);
      await reachBottom(tester);
      expect(offsets, [24]);
      expect(find.text('已加载 48 / 60 条视频'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '内容 59');
      await tester.pumpAndSettle();
      expect(offsets.last, 0);
      expect(find.widgetWithText(Card, '内容 59'), findsOneWidget);
      expect(find.text('已加载 1 / 1 条视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
