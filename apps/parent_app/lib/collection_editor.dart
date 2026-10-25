import 'package:flutter/material.dart';

class CollectionEditor extends StatefulWidget {
  final Map<String, dynamic> collection;
  final List<dynamic> videos;
  const CollectionEditor({
    super.key,
    required this.collection,
    required this.videos,
  });
  @override
  State<CollectionEditor> createState() => _CollectionEditorState();
}

class _CollectionEditorState extends State<CollectionEditor> {
  late final TextEditingController title = TextEditingController(
    text: widget.collection['title'],
  );
  late final List<String> ids = (widget.collection['videos'] as List)
      .map((v) => v['id'] as String)
      .toList();
  String? error;
  String name(String id) {
    final found = widget.videos.where((v) => v['id'] == id);
    return found.isEmpty ? '视频不可用' : '${found.first['title']}';
  }

  void move(int from, int to) {
    setState(() {
      final id = ids.removeAt(from);
      ids.insert(to, id);
    });
  }

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('编辑合集'),
      actions: [
        TextButton(
          onPressed: () {
            if (title.text.trim().isEmpty) {
              setState(() => error = '请输入合集名称');
              return;
            }
            Navigator.pop(context, {
              'title': title.text.trim(),
              'video_ids': ids.toList(),
            });
          },
          child: const Text('保存'),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: title,
            maxLength: 100,
            decoration: InputDecoration(labelText: '合集名称', errorText: error),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: Text('${ids.length} 条视频 · 拖动或使用箭头排序')),
              OutlinedButton.icon(
                onPressed: addVideos,
                icon: const Icon(Icons.add),
                label: const Text('添加视频'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ids.isEmpty
              ? const Center(child: Text('合集为空，添加视频后孩子才能看到'))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: ids.length,
                  onReorderItem: move,
                  itemBuilder: (context, i) => ListTile(
                    key: ValueKey(ids[i]),
                    leading: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                    title: Text(name(ids[i])),
                    subtitle: Text('第 ${i + 1} 条'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '上移',
                          onPressed: i == 0 ? null : () => move(i, i - 1),
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: '下移',
                          onPressed: i == ids.length - 1
                              ? null
                              : () => move(i, i + 1),
                          icon: const Icon(Icons.arrow_downward),
                        ),
                        IconButton(
                          tooltip: '移出合集',
                          onPressed: () => setState(() => ids.removeAt(i)),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    ),
  );
  Future<void> addVideos() async {
    final chosen = <String>{};
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('添加视频'),
          content: SizedBox(
            width: 440,
            height: 340,
            child: ListView(
              children: widget.videos
                  .where((v) => !ids.contains(v['id']))
                  .map(
                    (v) => CheckboxListTile(
                      title: Text('${v['title']}'),
                      value: chosen.contains(v['id']),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          chosen.add(v['id']);
                        } else {
                          chosen.remove(v['id']);
                        }
                      }),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('添加 ${chosen.length} 条'),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) setState(() => ids.addAll(chosen));
  }
}
