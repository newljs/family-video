import 'package:flutter/material.dart';
import 'ui.dart';

class LibraryPanel extends StatefulWidget {
  final List<dynamic> videos;
  final bool busy;
  final String Function(String) url;
  final ValueChanged<Map<String, dynamic>> onPreview;
  final Future<void> Function(Map<String, dynamic>, Map<String, String>) onEdit;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  const LibraryPanel({
    super.key,
    required this.videos,
    required this.busy,
    required this.url,
    required this.onPreview,
    required this.onEdit,
    required this.onDelete,
  });
  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends State<LibraryPanel> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    final items = widget.videos
        .where(
          (v) => "${v['title']} ${v['description'] ?? ''}"
              .toLowerCase()
              .contains(search.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading('视频库', subtitle: '处理完成的内容会直接出现在儿童端。'),
        const SizedBox(height: 16),
        TextField(
          onChanged: (v) => setState(() => search = v.trim()),
          decoration: const InputDecoration(
            labelText: '搜索标题或描述',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('${items.length} / ${widget.videos.length} 条视频'),
        ),
        if (items.isEmpty)
          const PanelCard(
            child: EmptyPanel(
              icon: Icons.video_library_outlined,
              title: '没有符合条件的视频',
              message: '试试其他关键词；新内容可以从收集箱导入。',
            ),
          ),
        LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth >= 640
                ? (box.maxWidth - 16) / 2
                : box.maxWidth;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: items.map((raw) {
                final video = Map<String, dynamic>.from(raw);
                return SizedBox(width: width, child: videoCard(video));
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget videoCard(Map<String, dynamic> video) {
    final seconds = (video['duration'] as num?)?.round() ?? 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => widget.onPreview(video),
            child: SizedBox(
              height: 166,
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
                        : Image.network(
                            widget.url(video['thumbnail_url']),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.movie_outlined,
                              size: 40,
                              color: Color(0xff9caeae),
                            ),
                          ),
                  ),
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
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .95),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '儿童端可观看',
                        style: TextStyle(
                          color: parentGreen,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
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
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              '${video['title']}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
          if ('${video['description'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${video['description']}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xff718081),
                  height: 1.5,
                ),
              ),
            ),
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
