import 'package:flutter/material.dart';
import 'ui.dart';

class InboxPage extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final bool busy, connected;
  final Future<void> Function(Map<String, dynamic>) onRemove;
  final VoidCallback onSync, onConnect;
  const InboxPage({
    super.key,
    required this.items,
    required this.busy,
    required this.connected,
    required this.onRemove,
    required this.onSync,
    required this.onConnect,
  });
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  static const pageSize = 20;
  int visible = pageSize;
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      if (scroll.position.extentAfter < 240 && visible < widget.items.length) {
        setState(() => visible += pageSize);
      }
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = visible.clamp(0, widget.items.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('${widget.items.length} 条待同步 · 已显示 $count 条'),
        ),
        Expanded(
          child:
              widget.items.isEmpty
                  ? const Center(
                    child: EmptyPanel(
                      icon: Icons.inbox_outlined,
                      title: '还没有等待同步的内容',
                      message: '返回收集箱，先保存一条好内容。',
                    ),
                  )
                  : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: count + 1,
                    itemBuilder: (context, index) {
                      if (index == count) {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: Text(
                              count < widget.items.length
                                  ? '上拉加载更多'
                                  : '已加载全部 $count 条',
                            ),
                          ),
                        );
                      }
                      final item = widget.items[index];
                      return ListTile(
                        leading: const Icon(
                          Icons.bookmark_add_outlined,
                          color: parentGreen,
                        ),
                        title: Text(
                          '${item['title']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${item['text']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: '移出收集箱',
                          icon: const Icon(Icons.close),
                          onPressed:
                              widget.busy ? null : () => widget.onRemove(item),
                        ),
                      );
                    },
                  ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: const Border(top: BorderSide(color: Color(0xffdde5e5))),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    onPressed:
                        widget.busy || !widget.connected || widget.items.isEmpty
                            ? null
                            : widget.onSync,
                    icon: const Icon(Icons.sync),
                    label: Text('同步 ${widget.items.length} 条到家庭电脑'),
                  ),
                  if (!widget.connected)
                    TextButton(
                      onPressed: widget.onConnect,
                      child: const Text('先连接家庭电脑'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
