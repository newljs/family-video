import 'package:flutter/material.dart';
import 'feed.dart';

const kidsSurface = Color(0xff141619);

class KidsEmptyState extends StatelessWidget {
  final IconData icon;
  final String title, message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const KidsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 390),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: kidsSurface,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(icon, size: 34, color: cyan.withValues(alpha: .8)),
            ),
            const SizedBox(height: 22),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.7,
                color: Colors.white54,
              ),
            ),
            if (actionLabel != null)
              Padding(
                padding: const EdgeInsets.only(top: 22),
                child: OutlinedButton(
                  onPressed: onAction,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                  child: Text(actionLabel!),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class KidsConnectionPage extends StatelessWidget {
  final TextEditingController address;
  final bool busy;
  final String? error;
  final VoidCallback onConnect;
  const KidsConnectionPage({
    super.key,
    required this.address,
    required this.busy,
    this.error,
    required this.onConnect,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff112426), Color(0xff080a0d), Colors.black],
          stops: [0, .45, 1],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 30),
              children: [
                const Text(
                  '抖音儿童版',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 14,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 34),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 74,
                    height: 74,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Image.asset(
                      'assets/branding/douyin_icon.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                const Text(
                  '欢迎来到你的放映室',
                  style: TextStyle(
                    fontSize: 28,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '家长精选的好内容，\n还有你喜欢的每一段小发现。',
                  style: TextStyle(
                    color: Colors.white54,
                    height: 1.7,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 30),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xff12171b),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .08),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.wifi_rounded, size: 17, color: cyan),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '连接家庭电脑',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '请家长帮忙填写地址，设备需接入家庭网络。',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: address,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          labelText: '家庭服务器地址',
                          hintText: 'http://电脑IP:8765',
                          labelStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: Colors.black26,
                          contentPadding: const EdgeInsets.all(16),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Colors.white12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Colors.white12),
                          ),
                        ),
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.info_outline,
                                size: 16,
                                color: accent,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  error!,
                                  style: const TextStyle(
                                    color: Color(0xffff9eb0),
                                    fontSize: 12,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: busy ? null : onConnect,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (busy) ...[
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Text(busy ? '连接中…' : '进入放映室'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.offline_pin_outlined,
                      size: 15,
                      color: Colors.white38,
                    ),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '缓存到设备，离线也能看',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class KidsMediaTile extends StatelessWidget {
  final Map<String, dynamic> video;
  final String Function(String) url;
  final VoidCallback onPlay;
  final VoidCallback? onDelete;
  final bool offline;
  const KidsMediaTile({
    super.key,
    required this.video,
    required this.url,
    required this.onPlay,
    this.onDelete,
    this.offline = false,
  });
  @override
  Widget build(BuildContext context) {
    final seconds = (video['duration'] as num?)?.round() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: kidsSurface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: .04)),
        ),
        child: ListTile(
          minTileHeight: 100,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          leading: SizedBox(
            width: 66,
            height: 76,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(
                    color: Color(0xff242a2e),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 30,
                      color: Colors.white38,
                    ),
                  ),
                  if (video['thumbnail_url'] != null && !offline)
                    Image.network(
                      url(video['thumbnail_url']),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.movie_outlined,
                        color: Colors.white24,
                      ),
                    ),
                  if (seconds > 0)
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        color: Colors.black54,
                        child: Text(
                          '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          title: Text(
            '${video['title']}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              offline ? '已缓存 · 离线可看' : '家长精选',
              style: TextStyle(
                color: offline ? cyan.withValues(alpha: .8) : Colors.white38,
                fontSize: 11,
              ),
            ),
          ),
          trailing: onDelete == null
              ? const Icon(Icons.chevron_right, size: 19, color: Colors.white24)
              : IconButton(
                  tooltip: '删除缓存',
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.white38,
                    size: 21,
                  ),
                ),
          onTap: onPlay,
        ),
      ),
    );
  }
}

class KidsCollectionCard extends StatelessWidget {
  final Map<String, dynamic> collection;
  final int index;
  final VoidCallback onPlay;
  final VoidCallback? onDownload;
  const KidsCollectionCard({
    super.key,
    required this.collection,
    required this.index,
    required this.onPlay,
    this.onDownload,
  });
  @override
  Widget build(BuildContext context) {
    final items = collection['videos'] as List;
    final colors = [
      const Color(0xff28585b),
      const Color(0xff504068),
      const Color(0xff6c4c38),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: kidsSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: .06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onPlay,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
                gradient: LinearGradient(
                  colors: [colors[index % colors.length], kidsSurface],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '家长为你整理',
                          style: TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${collection['title']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${items.length} 条精选视频',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Icon(
                    Icons.play_circle_fill_rounded,
                    size: 44,
                    color: Colors.white70,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white70,
                    size: 19,
                  ),
                  label: const Text(
                    '开始观看',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '缓存整个合集',
                  onPressed: onDownload,
                  icon: const Icon(
                    Icons.download_outlined,
                    color: Colors.white60,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class KidsSearchSheet extends StatefulWidget {
  final List<dynamic> videos;
  const KidsSearchSheet({super.key, required this.videos});
  @override
  State<KidsSearchSheet> createState() => _KidsSearchSheetState();
}

class _KidsSearchSheetState extends State<KidsSearchSheet> {
  final query = TextEditingController();
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = widget.videos
        .where(
          (v) => '${v['title']}'.toLowerCase().contains(
            query.text.trim().toLowerCase(),
          ),
        )
        .toList();
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SizedBox(
          height:
              (MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom) *
              .68,
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '搜索精选',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭搜索',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white54,
                      size: 21,
                    ),
                  ),
                ],
              ),
              TextField(
                controller: query,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索家长精选和已缓存视频',
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: matches.isEmpty
                    ? const SingleChildScrollView(
                        child: KidsEmptyState(
                          icon: Icons.search_off,
                          title: '没有找到相关视频',
                          message: '换个关键词试试看。',
                        ),
                      )
                    : ListView(
                        children: matches
                            .map(
                              (v) => ListTile(
                                leading: Icon(
                                  v['local_path'] != null
                                      ? Icons.offline_pin_outlined
                                      : Icons.play_circle_outline,
                                  color: Colors.white38,
                                ),
                                title: Text(
                                  '${v['title']}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  v['local_path'] != null
                                      ? '已缓存 · 离线可看'
                                      : '家长精选',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white38,
                                  ),
                                ),
                                onTap: () => Navigator.pop(
                                  context,
                                  Map<String, dynamic>.from(v),
                                ),
                              ),
                            )
                            .toList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
