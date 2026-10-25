import 'dart:async';
import 'dart:convert';
import 'package:family_api/family_api.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'collections_panel.dart';
import 'library_panel.dart';
import 'scanner_page.dart';
import 'collection_editor.dart';

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '小小放映室 · 家长',
    theme: parentTheme(),
    home: const ParentHome(),
  ),
);

class ParentHome extends StatefulWidget {
  final FamilyApi? api;
  const ParentHome({super.key, this.api});
  @override
  State<ParentHome> createState() => _ParentHomeState();
}

class _ParentHomeState extends State<ParentHome> {
  late final api = widget.api ?? FamilyApi(clientRole: 'parent');
  Timer? taskPolling;
  final address = TextEditingController(text: 'http://192.168.1.10:8765');
  final link = TextEditingController(), title = TextEditingController();
  List<dynamic> videos = [], tasks = [], collections = [];
  List<Map<String, dynamic>> inbox = [];
  bool connected = false, busy = false;
  String? error;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    await perform(() async {
      await api.restore();
      final prefs = await SharedPreferences.getInstance();
      inbox = (jsonDecode(prefs.getString('inbox') ?? '[]') as List)
          .cast<Map<String, dynamic>>();
      if (api.server.isNotEmpty) address.text = api.server;
      if (api.server.isNotEmpty) {
        await refresh();
        connected = true;
        unawaited(checkForUpdate());
      }
    });
  }

  /// 连接后检查服务端是否有更新的家长端安装包；失败静默。
  Future<void> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final update = await api.latestUpdate('parent');
      if (update == null || !isNewerVersion(update.version, info.version)) {
        return;
      }
      if (!mounted || error != null) return;
      final go = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('发现新版本'),
              content: Text(
                '家长端有新版本 v${update.version}'
                '${update.sizeBytes > 0 ? '（约 ${(update.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB）' : ''}，'
                '建议下载更新。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('稍后再说'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('立即下载'),
                ),
              ],
            ),
          ) ??
          false;
      if (go && mounted) {
        await launchUrl(
          Uri.parse(update.url),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      /* 更新检查失败不影响管理功能。 */
    }
  }

  Future<void> perform(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      error = friendlyError(e);
    }
    if (mounted) {
      setState(() {
        busy = false;
      });
    }
  }

  Future<void> refresh() async {
    await api.checkServer();
    final nextVideos = await api.request('GET', '/api/videos') as List;
    final nextTasks = await api.request('GET', '/api/tasks') as List;
    final nextCollections =
        await api.request('GET', '/api/collections') as List;
    if (!mounted) return;
    videos = nextVideos;
    tasks = nextTasks;
    collections = nextCollections;
    final active = tasks.any((t) => ['queued', 'running'].contains(t['state']));
    if (active) {
      taskPolling ??= Timer.periodic(const Duration(seconds: 8), (_) {
        if (mounted &&
            connected &&
            !busy &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          perform(refresh);
        }
      });
    } else {
      taskPolling?.cancel();
      taskPolling = null;
    }
  }

  Future<void> persistInbox() async => (await SharedPreferences.getInstance())
      .setString('inbox', jsonEncode(inbox))
      .then((_) {});
  Future<void> collect() async {
    if (link.text.trim().isEmpty) throw Exception('先粘贴分享文案');
    if (inbox.any((item) => item['text'] == link.text.trim())) {
      throw Exception('这条内容已在收集箱中');
    }
    inbox.add({
      'text': link.text.trim(),
      'title': title.text.trim().isEmpty ? '新收集的视频' : title.text.trim(),
    });
    await persistInbox();
    link.clear();
    title.clear();
  }

  Future<void> syncInbox() async {
    while (inbox.isNotEmpty) {
      await api.request('POST', '/api/imports', inbox.first);
      inbox.removeAt(0);
      await persistInbox();
    }
    await refresh();
  }

  @override
  void dispose() {
    taskPolling?.cancel();
    for (final c in [address, link, title]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        '小小放映室',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => setState(() => tab = 3),
          icon: Icon(
            connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
            size: 16,
          ),
          label: Text(
            connected ? '已连接' : '连接电脑',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        IconButton(
          tooltip: '刷新内容',
          onPressed: busy || !connected ? null : () => perform(refresh),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.move_to_inbox_outlined),
          label: '收集箱',
        ),
        NavigationDestination(
          icon: Icon(Icons.video_library_outlined),
          label: '视频库',
        ),
        NavigationDestination(icon: Icon(Icons.playlist_play), label: '合集'),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          label: '连接设置',
        ),
      ],
    ),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            decoration: BoxDecoration(
              color: const Color(0xffffeee9),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  color: Color(0xffaa5344),
                  size: 20,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    error!,
                    style: const TextStyle(
                      color: Color(0xff8a493c),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭提示',
                  onPressed: () => setState(() => error = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: tab == 1
                  ? LibraryPanel(
                      videos: videos,
                      collections: collections,
                      busy: busy,
                      url: (path) => api.uri(path).toString(),
                      onPreview: (v) => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => Preview(
                            url: api.uri(v['media_url']).toString(),
                          ),
                        ),
                      ),
                      onEdit: (v, metadata) => perform(() async {
                        await api.request('PATCH', '/api/videos/${v['id']}', metadata);
                        await refresh();
                      }),
                      onDelete: (v) => perform(() async {
                        await api.request('DELETE', '/api/videos/${v['id']}');
                        await refresh();
                      }),
                      onBatchDelete: (ids) => perform(() async {
                        for (final id in ids) {
                          await api.request('DELETE', '/api/videos/$id');
                        }
                        await refresh();
                      }),
                      onBatchCollect: (ids, collectionId, newTitle) =>
                          perform(() async {
                        if (newTitle.isNotEmpty) {
                          await api.request('POST', '/api/collections', {
                            'title': newTitle,
                            'video_ids': ids,
                          });
                        } else if (collectionId != null) {
                          final target = collections.firstWhere(
                            (c) => '${c['id']}' == collectionId,
                          );
                          final merged = <String>{
                            ...((target['videos'] as List)
                                .map((v) => '${v['id']}')),
                            ...ids,
                          };
                          await api.request(
                            'PUT',
                            '/api/collections/$collectionId',
                            {
                              'title': target['title'],
                              'video_ids': merged.toList(),
                            },
                          );
                        }
                        await refresh();
                      }),
                    )
                  : tab == 2
                  ? CollectionsPanel(
                      videos: videos,
                      collections: collections,
                      busy: busy,
                      onCreate: (title, ids) => perform(() async {
                        await api.request('POST', '/api/collections', {
                          'title': title,
                          'video_ids': ids,
                        });
                        await refresh();
                      }),
                      onEdit: editCollection,
                      onDelete: deleteCollection,
                    )
                  : RefreshIndicator(
                      onRefresh: connected && !busy
                          ? () => perform(refresh)
                          : () async {},
                      child: ListView(
                        key: PageStorageKey('parent-$tab'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                        children: page(),
                      ),
                    ),
            ),
          ),
        ),
      ],
    ),
  );

  List<Widget> page() {
    if (tab == 3) {
      return [
        const SectionHeading('连接家庭电脑', subtitle: '同一个家庭网络，填好地址就能连接。'),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (connected)
                Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: const Color(0xffe9f6ef),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: parentGreen),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '家庭电脑已连接\n${api.server}',
                          style: const TextStyle(height: 1.6, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              TextField(
                controller: address,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'http://电脑IP:8765',
                  prefixIcon: const Icon(Icons.dns_outlined),
                  suffixIcon: IconButton(
                    tooltip: '扫码连接',
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    onPressed: busy
                        ? null
                        : () async {
                            final addr = await scanServerAddress(context);
                            if (addr == null || !mounted) return;
                            address.text = addr;
                            await perform(() async {
                              await api.save(address.text);
                              await refresh();
                              connected = true;
                            });
                          },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => perform(() async {
                        await api.save(address.text);
                        await refresh();
                        connected = true;
                      }),
                icon: const Icon(Icons.link),
                label: Text(connected ? '重新连接' : '连接'),
              ),
              if (connected)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => perform(() async {
                          taskPolling?.cancel();
                          taskPolling = null;
                          await api.logout();
                          connected = false;
                          videos = [];
                          tasks = [];
                          collections = [];
                        }),
                  child: const Text('断开连接'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeading('连接前准备'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.computer_outlined, color: parentGreen),
                title: Text('在家庭电脑启动视频服务'),
                subtitle: Text('电脑保持开机，才能同步和播放未缓存内容。'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.wifi_rounded, color: parentGreen),
                title: Text('手机与电脑接入同一家庭网络'),
                subtitle: Text('填写电脑的局域网地址，无需密钥或配对码。'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.offline_pin_outlined, color: parentGreen),
                title: Text('在儿童端缓存喜欢的内容'),
                subtitle: Text('缓存完成后，离开家庭网络也能观看。'),
              ),
            ],
          ),
        ),
      ];
    }
    if (tab == 0) {
      return [
        const Text(
          '为孩子精选好内容',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '收集好内容，同步到电脑，孩子就能看。',
          style: TextStyle(color: Color(0xff718081), fontSize: 13),
        ),
        const SizedBox(height: 18),
        Overview(
          inbox: inbox.length,
          library: videos.length,
          collections: collections.length,
          connected: connected,
        ),
        const SizedBox(height: 18),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeading(
                '收集一条好内容',
                trailing: TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => perform(() async {
                          final data = await Clipboard.getData(
                            Clipboard.kTextPlain,
                          );
                          if (data?.text?.trim().isNotEmpty != true) {
                            throw Exception('剪贴板里还没有分享内容');
                          }
                          link.text = data!.text!.trim();
                        }),
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: const Text('粘贴'),
                ),
              ),
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: '视频标题（可选）',
                  hintText: '留空时从分享文案或视频信息提取',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: link,
                minLines: 3,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '粘贴抖音分享文案或链接',
                  alignLabelWithHint: true,
                  hintText: '支持直接粘贴完整分享文案',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy ? null : () => perform(collect),
                icon: const Icon(Icons.add, size: 19),
                label: const Text('保存到收集箱'),
              ),
              const SizedBox(height: 6),
              const Text(
                '先保存在本机，连接家庭电脑后再同步。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xff7e8a8a), fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeading(
                '待同步收集箱',
                subtitle: inbox.isEmpty
                    ? '还没有等待同步的内容'
                    : '${inbox.length} 条内容等待发送到家庭电脑',
              ),
              if (inbox.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: Text(
                    '看到适合孩子的内容，先收进来。',
                    style: TextStyle(color: Color(0xff718081), fontSize: 13),
                  ),
                ),
              ...inbox.asMap().entries.map(
                (e) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.bookmark_add_outlined,
                    color: parentGreen,
                  ),
                  title: Text(
                    '${e.value['title']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${e.value['text']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '移出收集箱',
                    icon: const Icon(Icons.close, size: 19),
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            inbox.removeAt(e.key);
                            await persistInbox();
                          }),
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy || !connected || inbox.isEmpty
                    ? null
                    : () => perform(syncInbox),
                icon: const Icon(Icons.sync),
                label: Text('同步 ${inbox.length} 条到家庭电脑'),
              ),
              if (!connected)
                TextButton(
                  onPressed: () => setState(() => tab = 3),
                  child: const Text('先连接家庭电脑'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('上传本地视频'),
          onPressed: busy
              ? null
              : () {
                  if (!connected) {
                    setState(() => tab = 3);
                    return;
                  }
                  perform(() async {
                    final file = await FilePicker.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['mp4', 'mov', 'm4v'],
                    );
                    final picked = file?.files.single.path;
                    if (picked != null) {
                      await api.upload(picked, '');
                      await refresh();
                    }
                  });
                },
        ),
        const SizedBox(height: 26),
        TaskPanel(
          key: const ValueKey('tasks'),
          tasks: tasks,
          busy: busy,
          onRetry: (id) => perform(() async {
            await api.request('POST', '/api/tasks/$id/retry');
            await refresh();
          }),
          onCancel: (id) => perform(() async {
            await api.request('POST', '/api/tasks/$id/cancel');
            await refresh();
          }),
          onLibrary: () => setState(() => tab = 1),
        ),
      ];
    }
    if (!connected) {
      return [
        PanelCard(
          child: EmptyPanel(
            icon: Icons.wifi_off_rounded,
            title: '连接后查看家庭内容',
            message: '收集箱可离线使用，视频库和合集需要连接家庭电脑。',
            action: FilledButton(
              onPressed: () => setState(() => tab = 3),
              child: const Text('连接家庭电脑'),
            ),
          ),
        ),
      ];
    }
    if (tab == 1 || tab == 2) {
      // 视频库与合集各自使用虚拟化面板（见 body 分发），page() 只负责其余页签。
      return const [];
    }
    return const [];
  }

  Future<void> editCollection(Map<String, dynamic> collection) async {
    final draft = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            CollectionEditor(collection: collection, videos: videos),
      ),
    );
    if (draft != null && mounted) {
      await perform(() async {
        await api.request('PUT', '/api/collections/${collection['id']}', draft);
        await refresh();
      });
    }
  }

  Future<void> deleteCollection(Map<String, dynamic> collection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除合集？'),
        content: Text('删除“${collection['title']}”后，视频文件仍保留在视频库。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await perform(() async {
        await api.request('DELETE', '/api/collections/${collection['id']}');
        await refresh();
      });
    }
  }
}

class Preview extends StatefulWidget {
  final String url;
  const Preview({super.key, required this.url});
  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  late final VideoPlayerController controller;
  String? error;
  @override
  void initState() {
    super.initState();
    controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    controller
        .initialize()
        .then((_) {
          if (mounted) {
            setState(() {});
            controller.play();
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => error = '$e');
        });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('视频预览')),
    body: Column(
      children: [
        Expanded(
          child: Center(
            child: error != null
                ? const Padding(
                    padding: EdgeInsets.all(28),
                    child: Text(
                      '暂时无法播放，请返回视频库刷新后重试。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : controller.value.isInitialized
                ? AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: VideoPlayer(controller),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
        if (controller.value.isInitialized)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: parentGreen,
                  bufferedColor: Color(0xffb6cfca),
                  backgroundColor: Color(0xffe2e8e6),
                ),
              ),
            ),
          ),
      ],
    ),
    floatingActionButton: ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) => FloatingActionButton(
        tooltip: value.isPlaying ? '暂停' : '播放',
        onPressed: !value.isInitialized
            ? null
            : () => value.isPlaying ? controller.pause() : controller.play(),
        child: Icon(
          value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ),
      ),
    ),
  );
}
