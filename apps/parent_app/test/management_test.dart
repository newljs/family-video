import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parent_app/library_panel.dart';
import 'package:parent_app/collection_editor.dart';

const videos = [
  {'id': 'a', 'title': '视频A', 'published': 1, 'thumbnail_url': '/a'},
  {'id': 'b', 'title': '视频B', 'published': 0, 'thumbnail_url': '/b'},
  {'id': 'c', 'title': '视频C', 'published': 1, 'thumbnail_url': '/c'},
];
void main() {
  testWidgets('library searches and renames without an approval control', (
    tester,
  ) async {
    String? renamed;
    String? description;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
              height: 700,
            child: LibraryPanel(
              videos: videos,
              collections: const [],
              onBatchCollect: (_, _, _) async {},
              onBatchDelete: (_) async {},
              busy: false,
              url: (path) => 'https://example.invalid$path',
              onPreview: (_) {},
              onEdit: (v, metadata) async {
                renamed = metadata['title'];
                description = metadata['description'];
              },
              onDelete: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.enterText(find.byType(TextField), '视频B');
    await tester.pumpAndSettle();
    expect(find.text('视频A'), findsNothing);
    expect(find.widgetWithText(Card, '视频B'), findsOneWidget);
    await tester.ensureVisible(find.text('编辑信息'));
    await tester.tap(find.text('编辑信息'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '视频标题'), '自然小知识');
    await tester.enterText(find.widgetWithText(TextField, '视频描述'), '讲解自然现象');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(renamed, '自然小知识');
    expect(description, '讲解自然现象');
  });
  testWidgets(
    'video deletion requires confirmation and preserves content on cancel',
    (tester) async {
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 700,
              child: LibraryPanel(
                collections: const [],
                onBatchCollect: (_, _, _) async {},
                onBatchDelete: (_) async {},
                videos: const [
                  {'id': 'a', 'title': '自然小知识', 'description': '一段介绍自然的文字'},
                ],
                busy: false,
                url: (s) => s,
                onPreview: (_) {},
                onEdit: (_, _) async {},
                onDelete: (_) async {
                  deleted++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '自然的文字');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Card, '自然小知识'), findsOneWidget);
      await tester.ensureVisible(find.text('删除'));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      expect(deleted, 0);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(deleted, 1);
    },
  );
  testWidgets('collection editor changes order, members and title', (
    tester,
  ) async {
    Map<String, dynamic>? draft;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                draft = await Navigator.push<Map<String, dynamic>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CollectionEditor(
                      collection: {
                        'id': 'test',
                        'title': '自然',
                        'videos': [
                          {'id': 'a'},
                          {'id': 'b'},
                        ],
                      },
                      videos: videos,
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上移').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移出合集').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频C'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定 1 条'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '精选自然');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(draft, {
      'title': '精选自然',
      'video_ids': ['b', 'c'],
    });
  });
}
