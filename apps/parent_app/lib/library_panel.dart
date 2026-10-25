import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'ui.dart';

/// 视频库面板：GridView.builder 虚拟化渲染（几千条也只构建可见卡片）、
/// 缩略图按显示宽度降采样解码、支持排序与多选批量删除/加入合集。
class LibraryPanel extends StatefulWidget {
  final List<dynamic> videos;
  final List<dynamic> collections;
  final bool busy;
  final String Function(String) url;
  final ValueChanged<Map<String, dynamic>> onPreview;
  final Future<void> Function(Map<String, dynamic>, Map<String, String>) onEdit;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  final Future<void> Function(List<String> ids) onBatchDelete;
  final Future<void> Function(List<String> ids, String? collectionId, String newTitle) onBatchCollect;
  const LibraryPanel({
    super.key,
    required this.videos,
    required this.collections,
    required this.busy,
    required this.url,
    required this.onPreview,
    required this.onEdit,
    required this.onDelete,
    required this.onBatchDelete,
    required this.onBatchCollect,
  });
  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends State<LibraryPanel> {
  String search = '';
  String sort = 'newest';
  bool batchMode = false;
  final selected = <String>{};

  List<Map<String, dynamic>> get items {
    final query = search.toLowerCase();
    final matched = widget.videos
        .where(
          (v) => "${v['title']} ${v['description'] ?? ''}"
              .toLowerCase()
              .contains(query),
        )
        .map((raw) => Map<String, dynamic>.from(raw))
        .toList();
    int plays(Map<String, dynamic> v) => (v['plays'] as num?)?.toInt() ?? 0;
    int done(Map<String, dynamic> v) =>
        (v['completed_count'] as num?)?.toInt() ?? 0;
    int watched(Map<String, dynamic> v) =>
        (v['watched_ms'] as num?)?.toInt() ?? 0;
    switch (sort) {
      case 'most_played':
        matched.sort((a, b) => plays(b).compareTo(plays(a)));
      case 'most_completed':
        matched.sort((a, b) => done(b).compareTo(done(a)));
      case 'most_watched':
        matched.sort((a, b) => watched(b).compareTo(watched(a)));
      default:
        break; // 服务端已按创建时间倒序
    }
    return matched;
  }

  void togglePick(String id) => setState(() {
        selected.contains(id) ? selected.remove(id) : selected.add(id);
      });

  @override
  Widget build(BuildContext context) {
    final list = items;
    return RefreshIndicator(
      onRefresh: () async {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeading('视频库', subtitle: '处理完成的内容会直接出现在儿童端。'),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        onChanged: (v) => setState(() => search = v.trim()),
                        decoration: const InputDecoration(
                          labelText: '搜索标题或描述',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DropdownButton<String>(
                      value: sort,
                      items: const [
                        DropdownMenuItem(value: 'newest', child: Text('最新优先')),
                        DropdownMenuItem(value: 'most_played', child: Text('播放最多')),
                        DropdownMenuItem(value: 'most_completed', child: Text('完播最多')),
                        DropdownMenuItem(value: 'most_watched', child: Text('观看最久')),
                      ],
                      onChanged: (v) => setState(() => sort = v ?? 'newest'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.tonal(
                      onPressed: () => setState(() {
                        batchMode = !batchMode;
                        selected.clear();
                      }),
                      child: Text(batchMode ? '退出多选' : '批量管理'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('${list.length} / ${widget.videos.length} 条视频'),
                if (batchMode) ...[
                  const SizedBox(height: 8),
                  _BatchBar(
                    count: selected.length,
                    total: list.length,
                    busy: widget.busy,
                    onSelectAll: () => setState(() {
                      selected.addAll(list.map((v) => '${v['id']}'));
                    }),
                    onClear: () => setState(() => selected.clear()),
                    onCollect: selected.isEmpty || widget.busy
                        ? null
                        : () => pickCollection(list),
                    onDelete: selected.isEmpty || widget.busy
                        ? null
                        : () => confirmBatchDelete(),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      PanelCard(
                        child: EmptyPanel(
                          icon: Icons.video_library_outlined,
                          title: '没有符合条件的视频',
                          message: '试试其他关键词；新内容可以从收集箱导入。',
                        ),
                      ),
                    ],
                  )
                : GridView.builder(
                    key: const PageStorageKey('parent-library-grid'),
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                    physics: const AlwaysScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 330,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      // 固定卡片像素高度：窄屏两列时按比例缩高会挤爆卡片内容
                      mainAxisExtent: 380,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) => videoCard(list[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget videoCard(Map<String, dynamic> video) {
    final seconds = (video['duration'] as num?)?.round() ?? 0;
    final plays = (video['plays'] as num?)?.toInt() ?? 0;
    final completed = (video['completed_count'] as num?)?.toInt() ?? 0;
    final picked = selected.contains('${video['id']}');
    final card = Card(
      clipBehavior: Clip.antiAlias,
      color: picked ? const Color(0xffe8f0fe) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: batchMode
                ? () => togglePick('${video['id']}')
                : () => widget.onPreview(video),
            child: SizedBox(
              height: 136,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: const Color(0xffe9eeef),
                    child: video['thumbnail_url'] == null
                        ? const Icon(
                            Icons.movie_outlined,
                            size: 40,
                            color: Color(0xff9caeae),
                          )
                        : CachedThumbnail(
                            widget.url(video['thumbnail_url']),
                            fit: BoxFit.cover,
                            // 按卡片宽度降采样解码，几百条列表不再卡顿
                            cacheWidth: 480,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.movie_outlined,
                              size: 40,
                              color: Color(0xff9caeae),
                            ),
                          ),
                  ),
                  if (batchMode)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Icon(
                        picked
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: picked ? const Color(0xff1a56c4) : Colors.white,
                        size: 26,
                        shadows: const [
                          Shadow(blurRadius: 4, color: Colors.black45),
                        ],
                      ),
                    )
                  else ...[
                    const Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0x55000000),
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                    ),
                    if (seconds > 0)
                      Positioned(
                        bottom: 10,
                        right: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Text(
              '${video['title']}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Text(
              [
                if (plays > 0) '播放 $plays',
                if (completed > 0) '完播 $completed',
                if ((video['watched_ms'] as num?)?.toInt() != null &&
                    (video['watched_ms'] as num).toInt() > 60000)
                  '看了 ${(video['watched_ms'] as num).toInt() ~/ 60000} 分钟',
                if (video['created_at'] != null)
                  '${video['created_at']}'.split('T').first,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xff718081)),
            ),
          ),
          if (!batchMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => widget.onPreview(video),
                    icon: const Icon(Icons.play_arrow_rounded, size: 19),
                    label: const Text('预览'),
                  ),
                  TextButton.icon(
                    onPressed: widget.busy ? null : () => edit(video),
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: const Text('编辑信息'),
                  ),
                  TextButton.icon(
                    onPressed: widget.busy ? null : () => remove(video),
                    icon: const Icon(Icons.delete_outline, size: 17),
                    label: const Text('删除'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xffb53d38),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return batchMode
        ? InkWell(onTap: () => togglePick('${video['id']}'), child: card)
        : card;
  }

  Future<void> confirmBatchDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除选中的 ${selected.length} 条视频？'),
        content: const Text(
          '将从家庭电脑和所有合集中删除这些视频。已经缓存到设备的副本需要在设备上单独删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onBatchDelete(selected.toList());
      if (mounted) setState(() => selected.clear());
    }
  }

  Future<void> pickCollection(List<Map<String, dynamic>> list) async {
    String? chosenId;
    final name = TextEditingController();
    final result = await showDialog<List<String?>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('把 ${selected.length} 条视频加入合集'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: widget.collections.isEmpty
                      ? const Text('还没有合集，可在下方输入新合集名称')
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: widget.collections.length,
                          itemBuilder: (context, i) {
                            final c =
                                Map<String, dynamic>.from(widget.collections[i]);
                            return RadioListTile<String>(
                              value: '${c['id']}',
                              groupValue: chosenId,
                              dense: true,
                              title: Text('${c['title']}'),
                              subtitle: Text(
                                '${(c['videos'] as List).length} 条视频',
                              ),
                              onChanged: (v) => update(() => chosenId = v),
                            );
                          },
                        ),
                ),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: '或创建新合集（填写后优先使用）',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                [chosenId, name.text.trim()],
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await widget.onBatchCollect(selected.toList(), result[0], result[1] ?? '');
      if (mounted) {
        setState(() {
          selected.clear();
          batchMode = false;
        });
      }
    }
  }

  Future<void> edit(Map<String, dynamic> video) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => VideoDetailsDialog(video: video),
    );
    if (result != null) await widget.onEdit(video, result);
  }

  Future<void> remove(Map<String, dynamic> video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个视频？'),
        content: Text(
          '“${video['title']}”将从家庭电脑和所有合集中删除。已经缓存到设备的副本需要在设备上单独删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.onDelete(video);
  }
}

class _BatchBar extends StatelessWidget {
  final int count, total;
  final bool busy;
  final VoidCallback onSelectAll, onClear;
  final VoidCallback? onCollect, onDelete;
  const _BatchBar({
    required this.count,
    required this.total,
    required this.busy,
    required this.onSelectAll,
    required this.onClear,
    required this.onCollect,
    required this.onDelete,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xffeef4ee),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('已选 $count / $total 条',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        TextButton(onPressed: onSelectAll, child: const Text('全选')),
        TextButton(onPressed: onClear, child: const Text('清除')),
        TextButton.icon(
          onPressed: onCollect,
          icon: const Icon(Icons.playlist_add, size: 18),
          label: const Text('加入合集'),
        ),
        TextButton.icon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('批量删除'),
          style: TextButton.styleFrom(foregroundColor: const Color(0xffb53d38)),
        ),
      ],
    ),
  );
}

class VideoDetailsDialog extends StatefulWidget {
  final Map<String, dynamic> video;
  const VideoDetailsDialog({super.key, required this.video});
  @override
  State<VideoDetailsDialog> createState() => _VideoDetailsDialogState();
}

class _VideoDetailsDialogState extends State<VideoDetailsDialog> {
  late final title = TextEditingController(text: widget.video['title']);
  late final description = TextEditingController(
    text: widget.video['description'] ?? '',
  );
  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑视频信息'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(labelText: '视频标题'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: description,
              minLines: 3,
              maxLines: 7,
              maxLength: 4000,
              decoration: const InputDecoration(labelText: '视频描述'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (title.text.trim().isNotEmpty) {
            Navigator.pop(context, {
              'title': title.text.trim(),
              'description': description.text.trim(),
            });
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
