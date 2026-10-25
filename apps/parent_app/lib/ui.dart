import 'package:flutter/material.dart';

const parentGreen = Color(0xff087f73);

ThemeData parentTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: parentGreen),
  scaffoldBackgroundColor: const Color(0xfff4f6f8),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xfff4f6f8),
    surfaceTintColor: Colors.transparent,
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xfff3f6f7),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: parentGreen, width: 1.5),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: Color(0xffdcf1eb),
    height: 72,
  ),
);

class PanelCard extends StatelessWidget {
  final Widget child;
  const PanelCard({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}

class SectionHeading extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SectionHeading(this.title, {super.key, this.subtitle, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    subtitle!,
                    style: const TextStyle(
                      color: Color(0xff6e797c),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyPanel extends StatelessWidget {
  final IconData icon;
  final String title, message;
  final Widget? action;
  const EmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 28),
    child: Column(
      children: [
        Icon(icon, color: parentGreen.withValues(alpha: .55), size: 38),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xff718081),
            fontSize: 13,
            height: 1.6,
          ),
        ),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 16), child: action!),
      ],
    ),
  );
}

class Overview extends StatelessWidget {
  final int inbox, library, collections;
  final bool connected;
  const Overview({
    super.key,
    required this.inbox,
    required this.library,
    required this.collections,
    required this.connected,
  });
  @override
  Widget build(BuildContext context) => Row(
    children: [
      stat('$inbox', '待同步', const Color(0xff087f73)),
      const SizedBox(width: 10),
      stat(connected ? '$library' : '—', '视频', const Color(0xffb97926)),
      const SizedBox(width: 10),
      stat(connected ? '$collections' : '—', '合集', const Color(0xff5875bd)),
    ],
  );
  Widget stat(String value, String label, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 25,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xff758082)),
          ),
        ],
      ),
    ),
  );
}

class TaskPanel extends StatefulWidget {
  final List<dynamic> tasks;
  final bool busy;
  final ValueChanged<String> onRetry, onCancel;
  final VoidCallback onLibrary;
  const TaskPanel({
    super.key,
    required this.tasks,
    required this.busy,
    required this.onRetry,
    required this.onCancel,
    required this.onLibrary,
  });
  @override
  State<TaskPanel> createState() => _TaskPanelState();
}

class _TaskPanelState extends State<TaskPanel> {
  int filter = 0;
  bool matches(dynamic t) => switch (filter) {
    1 => ['queued', 'running'].contains(t['state']),
    2 => t['state'] == 'failed',
    3 => t['state'] == 'completed',
    _ => true,
  };
  @override
  Widget build(BuildContext context) {
    final items = widget.tasks.where(matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading('导入任务', subtitle: '处理完成后，儿童端即可观看。'),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: List.generate(
            4,
            (i) => ChoiceChip(
              label: Text(['全部', '处理中', '失败', '已完成'][i]),
              selected: filter == i,
              onSelected: (_) => setState(() => filter = i),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          PanelCard(
            child: EmptyPanel(
              icon: Icons.downloading_outlined,
              title: widget.tasks.isEmpty ? '还没有导入任务' : '暂无此类任务',
              message: widget.tasks.isEmpty
                  ? '同步收集箱或上传本地视频后，进度会显示在这里。'
                  : '可以切换筛选查看其他任务。',
            ),
          ),
        ...items.map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: taskCard(t),
          ),
        ),
      ],
    );
  }

  Widget taskCard(dynamic t) {
    final state = '${t['state']}';
    final failed = state == 'failed', done = state == 'completed';
    final color = failed
        ? const Color(0xffb3443c)
        : done
        ? parentGreen
        : const Color(0xff7a8390);
    final phase = '${t['phase'] ?? ''}';
    final nextRetry = (t['next_attempt_at'] as num?)?.toInt() ?? 0;
    final waiting =
        state == 'queued' &&
        nextRetry > DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final received = (t['downloaded_bytes'] as num?)?.toDouble() ?? 0;
    final total = (t['total_bytes'] as num?)?.toDouble() ?? 0;
    final label = waiting
        ? '等待自动重试'
        : state == 'running'
        ? const {
                'cached': '校验已下载原件',
                'resolving': '解析视频地址',
                'downloading': '下载视频',
                'inspecting': '检查视频',
                'processing': '处理视频',
                'thumbnail': '生成封面',
                'streaming': '准备流媒体',
              }[phase] ??
              '处理中'
        : const {
                'queued': '排队中',
                'completed': '已完成',
                'failed': '导入失败',
                'cancelled': '已取消',
              }[state] ??
              state;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  failed
                      ? Icons.error_outline
                      : done
                      ? Icons.check_circle_outline
                      : Icons.downloading_rounded,
                  color: color,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${t['title']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '${t['kind'] == 'upload' ? '本地上传' : '抖音链接'} · $label',
                      style: TextStyle(fontSize: 12, color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (state == 'running' && phase == 'downloading' && total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: (received / total).clamp(0, 1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '${(received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff718081),
                    ),
                  ),
                ],
              ),
            ),
          if (waiting)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '已安排自动重试（${t['auto_retries'] ?? 0}/2），也可以取消任务。',
                style: const TextStyle(fontSize: 12, color: Color(0xff718081)),
              ),
            ),
          if (failed && t['error'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Material(
                color: const Color(0xfffff5f3),
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                  title: const Text(
                    '未能完成导入',
                    style: TextStyle(fontSize: 13, color: Color(0xff9d4b43)),
                  ),
                  subtitle: const Text(
                    '展开查看原因，再决定是否重试',
                    style: TextStyle(fontSize: 12),
                  ),
                  children: [
                    Text(
                      '${t['error']}',
                      style: const TextStyle(fontSize: 13, height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
          if (done)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '已存入视频库，儿童端刷新后即可观看。',
                style: TextStyle(fontSize: 13, color: Color(0xff6e797c)),
              ),
            ),
          if (done || ['queued', 'running', 'failed'].contains(state))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (['queued', 'running', 'failed'].contains(state))
                    TextButton.icon(
                      onPressed: widget.busy
                          ? null
                          : () => widget.onCancel('${t['id']}'),
                      icon: const Icon(Icons.close, size: 17),
                      label: const Text('取消任务'),
                    ),
                  if (failed)
                    FilledButton.tonalIcon(
                      onPressed: widget.busy
                          ? null
                          : () => widget.onRetry('${t['id']}'),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重试'),
                    ),
                  if (done)
                    TextButton.icon(
                      onPressed: widget.onLibrary,
                      icon: const Icon(Icons.arrow_forward, size: 17),
                      label: const Text('前往视频库'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
