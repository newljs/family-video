import 'package:flutter/material.dart';
import 'ui.dart';

/// 可搜索的视频多选对话框：ListView.builder 虚拟化，几百条视频流畅可选。
/// 返回选中的视频 id 集合；取消返回 null。
Future<Set<String>?> showVideoPicker(
  BuildContext context,
  List<dynamic> videos, {
  Set<String>? excludeIds,
  String title = '选择视频',
}) => showDialog<Set<String>>(
  context: context,
  builder: (context) => _VideoPickerDialog(
    videos: videos,
    excludeIds: excludeIds ?? const {},
    title: title,
  ),
);

class _VideoPickerDialog extends StatefulWidget {
  final List<dynamic> videos;
  final Set<String> excludeIds;
  final String title;
  const _VideoPickerDialog({
    required this.videos,
    required this.excludeIds,
    required this.title,
  });
  @override
  State<_VideoPickerDialog> createState() => _VideoPickerDialogState();
}

class _VideoPickerDialogState extends State<_VideoPickerDialog> {
  final chosen = <String>{};
  String search = '';

  @override
  Widget build(BuildContext context) {
    final list = widget.videos
        .where((v) => !widget.excludeIds.contains('${v['id']}'))
        .where((v) => '${v['title']}'
            .toLowerCase()
            .contains(search.toLowerCase()))
        .toList();
    return AlertDialog(
      title: Text('${widget.title}（已选 ${chosen.length} 条）'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: widget.videos.length > 8,
              onChanged: (v) => setState(() => search = v.trim()),
              decoration: const InputDecoration(
                labelText: '搜索标题',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('没有匹配的视频'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final v = list[i];
                        final id = '${v['id']}';
                        return CheckboxListTile(
                          dense: true,
                          title: Text(
                            '${v['title']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: chosen.contains(id),
                          onChanged: (value) => setState(() {
                            value == true ? chosen.add(id) : chosen.remove(id);
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            chosen.clear();
          }),
          child: const Text('清除'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, chosen),
          child: Text('确定 ${chosen.length} 条'),
        ),
      ],
    );
  }
}

/// 合集面板：合集列表虚拟化，创建合集时视频在可搜索对话框中选择。
class CollectionsPanel extends StatelessWidget {
  final List<dynamic> videos;
  final List<dynamic> collections;
  final bool busy;
  final Future<void> Function(String title, List<String> ids) onCreate;
  final Future<void> Function(Map<String, dynamic> collection) onEdit;
  final Future<void> Function(Map<String, dynamic> collection) onDelete;
  const CollectionsPanel({
    super.key,
    required this.videos,
    required this.collections,
    required this.busy,
    required this.onCreate,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async {},
    child: ListView(
      key: const PageStorageKey('parent-collections'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      children: [
        SectionHeading('家庭合集', subtitle: '按主题整理内容，勾选顺序就是播放顺序。'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy || videos.isEmpty ? null : () => create(context),
          icon: const Icon(Icons.playlist_add),
          label: const Text('新建合集'),
        ),
        if (videos.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text(
              '先在视频库导入视频，再整理成合集。',
              style: TextStyle(color: Color(0xff718081)),
            ),
          ),
        const SizedBox(height: 10),
        ...collections.map(
          (raw) => ListTile(
            leading: const Icon(Icons.playlist_play),
            title: Text('${raw['title']}'),
            subtitle: Text('${(raw['videos'] as List).length} 条视频'),
            onTap: busy ? null : () => onEdit(Map<String, dynamic>.from(raw)),
            trailing: PopupMenuButton<String>(
              enabled: !busy,
              onSelected: (value) {
                final c = Map<String, dynamic>.from(raw);
                value == 'edit' ? onEdit(c) : onDelete(c);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑与排序')),
                PopupMenuItem(value: 'delete', child: Text('删除合集')),
              ],
            ),
          ),
        ),
        if (collections.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text(
              '还没有合集',
              style: TextStyle(color: Color(0xff718081)),
            ),
          ),
      ],
    ),
  );

  Future<void> create(BuildContext context) async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建合集'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '合集名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text('下一步，选视频'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    final ids = await showVideoPicker(context, videos, title: '添加到「$name」');
    if (ids == null || ids.isEmpty || !context.mounted) return;
    await onCreate(name, ids.toList());
  }
}
