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
import 'share_receiver.dart';
import 'inbox_page.dart';
import 'paged_items.dart';

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
  final LanDiscovery? discovery;
  const ParentHome({super.key, this.api, this.discovery});
  @override
  State<ParentHome> createState() => _ParentHomeState();
}

class _ParentHomeState extends State<ParentHome> with WidgetsBindingObserver {
  late final api = widget.api ?? FamilyApi(clientRole: 'parent');
  Timer? taskPolling;
  ShareReceiver? shares;
  bool syncingInbox = false;
  late final sync = BackgroundSync(() => fetchCatalog(progressive: true));
  bool updateChecked = false, catalogReady = false;
  StartupCache get startup => StartupCache(api.server, api.clientRole);
  final address = TextEditingController(text: 'http://192.168.1.10:8765');
  final link = TextEditingController(), title = TextEditingController();
  List<dynamic> videos = [], tasks = [], collections = [];
  List<dynamic>? collectionVideos;
  int videoTotal = 0, taskTotal = 0, activeTasks = 0;
  final pageChanges = ValueNotifier<int>(0);
  List<Map<String, dynamic>> inbox = [];
  Map<String, dynamic>? timeLimit;
  int limitDraft = 30;
  bool connected = false, busy = false;
  String? error;
  int tab = 0;

  int get watchedMinutes =>
      ((timeLimit?['watched_ms_today'] as num?)?.toInt() ?? 0) ~/ 60000;
  int get limitMinutes => (timeLimit?['limit_minutes'] as num?)?.toInt() ?? 0;
  String get afterLimitId => '${timeLimit?['after_limit_collection_id'] ?? ''}';
  bool get limitReached => timeLimit?['exhausted'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sync.addListener(onSyncChanged);
    initialize();
  }

  Future<void> initialize() async {
    await perform(() async {
      await api.restore();
      final prefs = await SharedPreferences.getInstance();
      inbox =
          (jsonDecode(prefs.getString('inbox') ?? '[]') as List)
              .cast<Map<String, dynamic>>();
      shares = ShareReceiver((id, text) async {
        if (!mounted) throw StateError('Inbox is closed');
        if (!inbox.any(
          (item) => item['share_id'] == id || item['text'] == text,
        )) {
          inbox.add({'text': text, 'title': '新收集的视频', 'share_id': id});
        }
        await persistInbox();
        if (mounted) setState(() => tab = 0);
        if (connected && sync.online == true && !busy) {
          unawaited(perform(() => syncInbox(sharesOnly: true)));
        }
      });
      unawaited(
        shares!.start().catchError((Object e) {
          if (mounted) setState(() => error = friendlyError(e));
        }),
      );
      if (api.server.isNotEmpty) address.text = api.server;
      if (api.server.isNotEmpty) {
        await restoreCatalog();
        connected = true;
      } else {
        tab = 3;
      }
    });
    if (mounted && connected) unawaited(sync.run());
  }

  /// 连接后检查服务端是否有更新的家长端安装包；失败静默。
  Future<void> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final update = await api.latestUpdate('parent');
      if (update == null ||
          !isNewerVersion(
            update.version,
            '${info.version}+${info.buildNumber}',
          )) {
        return;
      }
      if (!mounted || error != null) return;
      final go =
          await showDialog<bool>(
            context: context,
            builder:
                (context) => AlertDialog(
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
    pageChanges.value++;
    try {
      await action();
    } catch (e) {
      error = friendlyError(e);
    }
    if (mounted) {
      setState(() {
        busy = false;
      });
      pageChanges.value++;
    }
  }

  void onSyncChanged() {
    if (!mounted) return;
    setState(() {});
    if (sync.online == true && !updateChecked) {
      updateChecked = true;
      unawaited(checkForUpdate());
    }
    if (sync.online == true &&
        !syncingInbox &&
        !busy &&
        inbox.any((item) => item['share_id'] != null)) {
      unawaited(
        syncInbox(sharesOnly: true).catchError((Object e) {
          if (mounted) setState(() => error = friendlyError(e));
        }),
      );
    }
  }

  Future<void> restoreCatalog() async {
    final cache = startup;
    final saved = await Future.wait([
      cache.readList('videos'),
      cache.readList('tasks'),
      cache.readList('collections'),
      cache.readText('tab'),
    ]);
    if (!mounted || cache.server != api.server) return;
    videos = saved[0] as List;
    tasks = saved[1] as List;
    videoTotal = videos.length;
    taskTotal = tasks.length;
    collections = saved[2] as List;
    tab = (int.tryParse(saved[3] as String? ?? '') ?? 0).clamp(0, 3);
  }

  Future<void> connectServer() async {
    await api.save(address.text);
    sync.reset();
    updateChecked = false;
    catalogReady = false;
    collectionVideos = null;
    videoTotal = taskTotal = activeTasks = 0;
    videos = [];
    tasks = [];
    collections = [];
    timeLimit = null;
    await restoreCatalog();
    if (!mounted) return;
    setState(() => connected = true);
    unawaited(sync.run());
  }

  Future<void> refresh() async {
    sync.reset(); // Don't join a background read that predates a mutation.
    await sync.run(action: () => fetchCatalog(progressive: false));
    if (sync.error != null) throw sync.error!;
  }

  Future<void> fetchCatalog({required bool progressive}) async {
    final cache = startup;
    final generation = sync.generation;
    final verified = api.checkServer();
    final loaded = <String, ListPage>{};
    Object? failure;
    void apply(String name, ListPage page) {
      if (!mounted ||
          api.server != cache.server ||
          sync.generation != generation) {
        return;
      }
      setState(() {
        final items = page.items;
        if (name == 'videos') {
          videos = items;
          videoTotal = page.total;
          catalogReady = true;
        }
        if (name == 'tasks') {
          tasks = items;
          taskTotal = page.total;
          activeTasks = page.active;
        }
        if (name == 'collections') collections = items;
      });
      if (name == 'tasks') configurePolling();
      unawaited(cache.write(name, page.items));
      pageChanges.value++;
    }

    Future<void> section(String name) async {
      try {
        final results = await Future.wait([
          verified,
          api.requestWithTimeout(
            'GET',
            '/api/$name${name == 'collections' ? '' : '?limit=${name == 'videos' ? 24 : 20}'}',
            timeout: const Duration(seconds: 5),
          ),
        ]);
        loaded[name] = ListPage.from(results[1]);
        if (progressive) apply(name, loaded[name]!);
      } catch (e) {
        failure ??= e;
      }
    }

    Future<void> settings() async {
      try {
        final data = await api.requestWithTimeout(
          'GET',
          '/api/settings/time-limit',
          timeout: const Duration(seconds: 5),
        );
        if (data is Map &&
            mounted &&
            api.server == cache.server &&
            sync.generation == generation) {
          setState(() {
            timeLimit = Map<String, dynamic>.from(data);
            if (limitMinutes > 0) limitDraft = limitMinutes;
          });
        }
      } catch (_) {
        /* Optional on older services. Keep any displayed settings. */
      }
    }

    await Future.wait([
      section('videos'),
      section('tasks'),
      section('collections'),
      settings(),
    ]);
    if (!mounted ||
        api.server != cache.server ||
        sync.generation != generation) {
      return;
    }
    if (failure != null) throw failure!;
    if (!progressive) {
      for (final entry in loaded.entries) {
        apply(entry.key, entry.value);
      }
    }
    if (tab == 2) await loadCollectionVideos();
  }

  void configurePolling() {
    if (activeTasks > 0 ||
        tasks.any((t) => ['queued', 'running'].contains(t['state']))) {
      taskPolling ??= Timer.periodic(const Duration(seconds: 8), (_) {
        if (mounted &&
            connected &&
            !busy &&
            sync.online != false &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          unawaited(sync.run());
        }
      });
    } else {
      taskPolling?.cancel();
      taskPolling = null;
    }
  }

  Future<ListPage> loadPage(
    String section,
    int offset,
    int limit,
    Map<String, String> query,
  ) async {
    final path =
        Uri(
          path: '/api/$section',
          queryParameters: {...query, 'offset': '$offset', 'limit': '$limit'},
        ).toString();
    final data = await api.requestWithTimeout(
      'GET',
      path,
      timeout: const Duration(seconds: 5),
    );
    if (data is! List) return ListPage.from(data);
    // Array responses from older computers are filtered and paged locally.
    var rows = List<dynamic>.of(data);
    final search = (query['search'] ?? '').toLowerCase();
    if (search.isNotEmpty) {
      rows =
          rows
              .where(
                (v) => "${v['title']} ${v['description'] ?? ''}"
                    .toLowerCase()
                    .contains(search),
              )
              .toList();
    }
    final filter = query['filter'];
    if (filter != null && filter != 'all') {
      rows =
          rows
              .where(
                (t) =>
                    filter == 'processing'
                        ? ['queued', 'running'].contains(t['state'])
                        : t['state'] == filter,
              )
              .toList();
    }
    final metric =
        {
          'most_played': 'plays',
          'most_completed': 'completed_count',
          'most_watched': 'watched_ms',
        }[query['sort']];
    if (metric != null) {
      rows.sort(
        (a, b) =>
            ((b[metric] as num?) ?? 0).compareTo((a[metric] as num?) ?? 0),
      );
    }
    return ListPage(rows.skip(offset).take(limit).toList(), rows.length);
  }

  Future<void> loadCollectionVideos() async {
    final server = api.server;
    final generation = sync.generation;
    final all = <dynamic>[];
    while (true) {
      final page = await loadPage('videos', all.length, 200, {});
      if (!mounted || api.server != server || sync.generation != generation) {
        return;
      }
      all.addAll(page.items);
      if (page.items.isEmpty || all.length >= page.total) break;
    }
    if (mounted && api.server == server && sync.generation == generation) {
      setState(() => collectionVideos = all);
    }
  }

  Widget secondaryPage(String title, Widget Function() content) =>
      AnimatedBuilder(
        animation: pageChanges,
        builder:
            (context, _) => Scaffold(
              appBar: AppBar(title: Text(title)),
              body: Column(
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(error!),
                    ),
                  Expanded(child: content()),
                ],
              ),
            ),
      );

  void openInbox() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder:
          (_) => secondaryPage(
            '待同步收集箱',
            () => InboxPage(
              items: inbox,
              busy: busy || syncingInbox,
              connected: connected,
              onRemove:
                  (item) => perform(() async {
                    inbox.remove(item);
                    await persistInbox();
                  }),
              onSync: () => perform(syncInbox),
              onConnect: () {
                Navigator.of(context).pop();
                setState(() => tab = 3);
              },
            ),
          ),
    ),
  );

  void openTasks() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder:
          (_) => secondaryPage(
            '导入任务',
            () => Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TaskPanel(
                tasks: tasks,
                total: taskTotal,
                paged: true,
                busy: busy,
                loadPage:
                    connected
                        ? (offset, limit, query) =>
                            loadPage('tasks', offset, limit, query)
                        : null,
                onRetry:
                    (id) => perform(() async {
                      await api.request('POST', '/api/tasks/$id/retry');
                      await refresh();
                    }),
                onCancel:
                    (id) => perform(() async {
                      await api.request('POST', '/api/tasks/$id/cancel');
                      await refresh();
                    }),
                onLibrary: () {
                  Navigator.of(context).pop();
                  setState(() => tab = 1);
                },
              ),
            ),
          ),
    ),
  );

  Future<void> previewVideo(Map<String, dynamic> video) async {
    if (!catalogReady) {
      await sync.run();
      if (!mounted) return;
    }
    final fresh = videos.where((item) => item['id'] == video['id']).toList();
    if (fresh.isEmpty && sync.online == true && video['media_url'] != null) {
      fresh.add(video);
    }
    if (!catalogReady || fresh.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请连接家庭电脑后重试播放')));
      }
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder:
            (_) => Preview(url: api.uri(fresh.first['media_url']).toString()),
      ),
    );
  }

  Future<void> persistInbox() async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      'inbox',
      jsonEncode(inbox),
    );
    if (!saved) throw StateError('收集箱保存失败，请检查设备空间');
    if (mounted) pageChanges.value++;
  }

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

  Future<void> syncInbox({bool sharesOnly = false}) async {
    if (syncingInbox || !connected) return;
    syncingInbox = true;
    if (mounted) {
      setState(() {});
      pageChanges.value++;
    }
    final skipped = <String>[];
    try {
      while (inbox.isNotEmpty) {
        final next =
            sharesOnly
                ? inbox.indexWhere((item) => item['share_id'] != null)
                : 0;
        if (next < 0) break;
        final item = inbox[next];
        try {
          await api.request('POST', '/api/imports', item);
        } on FamilyApiException catch (e) {
          // A malformed item must not block every item behind it. Transient
          // network/server failures keep the item for the next retry.
          if (e.statusCode != 400) rethrow;
          skipped.add('${item['title']}：${e.message}');
        }
        inbox.remove(item);
        await persistInbox();
      }
      await refresh();
      if (skipped.isNotEmpty) {
        throw Exception('已跳过 ${skipped.length} 条无法导入的内容：${skipped.first}');
      }
    } finally {
      syncingInbox = false;
      if (mounted) {
        setState(() {});
        pageChanges.value++;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    sync.setActive(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      if (connected) unawaited(sync.run());
      unawaited(
        shares?.drain().catchError((Object e) {
          if (mounted) setState(() => error = friendlyError(e));
        }),
      );
      if (connected && inbox.any((item) => item['share_id'] != null) && !busy) {
        unawaited(perform(() => syncInbox(sharesOnly: true)));
      }
    }
  }

  /// 保存每日观看时长限制与额度用完后的可见合集；失败时 perform 显示错误提示。
  Future<void> saveTimeLimit(int minutes, String collectionId) =>
      perform(() async {
        timeLimit =
            await api.request('PUT', '/api/settings/time-limit', {
                  'limit_minutes': minutes,
                  'after_limit_collection_id': collectionId,
                })
                as Map<String, dynamic>?;
        if (minutes > 0) limitDraft = minutes;
      });

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    shares?.dispose();
    taskPolling?.cancel();
    sync.dispose();
    pageChanges.dispose();
    if (widget.api == null) api.close();
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
            sync.online == true ? Icons.wifi_rounded : Icons.wifi_off_rounded,
            size: 16,
          ),
          label: Text(
            sync.online == true
                ? '已连接'
                : connected
                ? '服务器状态'
                : '连接电脑',
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
      onDestinationSelected: (v) {
        setState(() => tab = v);
        if (v == 2 && connected) unawaited(perform(loadCollectionVideos));
        unawaited(startup.write('tab', '$v'));
      },
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
        if (connected && (sync.syncing || sync.online == false))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(sync.syncing ? Icons.sync : Icons.wifi_off, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    sync.syncing ? '正在后台同步…' : '电脑暂时离线或部分内容未更新，已保留本机内容',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
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
              child:
                  tab == 1
                      ? LibraryPanel(
                        videos: videos,
                        total: videoTotal,
                        loadPage:
                            (offset, limit, query) =>
                                loadPage('videos', offset, limit, query),
                        collections: collections,
                        busy: busy,
                        url: (path) => api.uri(path).toString(),
                        onPreview: previewVideo,
                        onEdit:
                            (v, metadata) => perform(() async {
                              await api.request(
                                'PATCH',
                                '/api/videos/${v['id']}',
                                metadata,
                              );
                              await refresh();
                            }),
                        onDelete:
                            (v) => perform(() async {
                              await api.request(
                                'DELETE',
                                '/api/videos/${v['id']}',
                              );
                              await refresh();
                            }),
                        onBatchDelete:
                            (ids) => perform(() async {
                              for (final id in ids) {
                                await api.request('DELETE', '/api/videos/$id');
                              }
                              await refresh();
                            }),
                        onBatchCollect:
                            (ids, collectionId, newTitle) => perform(() async {
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
                                  ...((target['videos'] as List).map(
                                    (v) => '${v['id']}',
                                  )),
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
                        videos: collectionVideos ?? videos,
                        collections: collections,
                        busy: busy,
                        onCreate:
                            (title, ids) => perform(() async {
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
                        onRefresh:
                            connected && !busy
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
        const SectionHeading('连接家庭电脑', subtitle: '连接家庭 Wi-Fi，搜索并选择电脑即可。'),
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
                          sync.online == true
                              ? '家庭电脑已连接\n${api.server}'
                              : '已保存家庭电脑地址\n${api.server}',
                          style: const TextStyle(height: 1.6, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!connected)
                LanDiscoveryPanel(
                  discovery: widget.discovery,
                  busy: busy,
                  onSelect: (url) {
                    address.text = url;
                    unawaited(perform(connectServer));
                  },
                ),
              ExpansionTile(
                key: PageStorageKey('parent-manual-$connected'),
                initiallyExpanded: connected,
                tilePadding: EdgeInsets.zero,
                title: const Text('扫码或手动输入'),
                children: [
                  TextField(
                    key: const PageStorageKey('parent-server-address'),
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
                        onPressed:
                            busy
                                ? null
                                : () async {
                                  final addr = await scanServerAddress(context);
                                  if (addr == null || !mounted) return;
                                  address.text = addr;
                                  await perform(() async {
                                    await connectServer();
                                  });
                                },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed:
                        busy
                            ? null
                            : () => perform(() async {
                              await connectServer();
                            }),
                    icon: const Icon(Icons.link),
                    label: Text(connected ? '重新连接' : '连接'),
                  ),
                  if (connected)
                    TextButton(
                      onPressed:
                          busy
                              ? null
                              : () => perform(() async {
                                taskPolling?.cancel();
                                taskPolling = null;
                                sync.reset();
                                catalogReady = false;
                                await api.logout();
                                connected = false;
                                collectionVideos = null;
                                timeLimit = null;
                                limitDraft = 30;
                                videoTotal = taskTotal = activeTasks = 0;
                                videos = [];
                                tasks = [];
                                collections = [];
                              }),
                      child: const Text('断开连接'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        if (timeLimit != null)
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeading(
                  '儿童观看时长',
                  subtitle: '设定孩子每天可观看的总时长，用完后儿童端当天停止播放。',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(
                    Icons.schedule_rounded,
                    color: parentGreen,
                  ),
                  title: const Text('每日时长限制'),
                  subtitle: Text(
                    limitMinutes > 0 ? '每天最多 $limitMinutes 分钟' : '不限制',
                  ),
                  value: limitMinutes > 0,
                  onChanged:
                      busy
                          ? null
                          : (v) =>
                              saveTimeLimit(v ? limitDraft : 0, afterLimitId),
                ),
                if (limitMinutes > 0)
                  Slider(
                    value: limitDraft.clamp(5, 240).toDouble(),
                    min: 5,
                    max: 240,
                    divisions: 47,
                    label: '${limitDraft.clamp(5, 240)} 分钟',
                    onChanged:
                        busy
                            ? null
                            : (v) => setState(() => limitDraft = v.round()),
                    onChangeEnd:
                        busy
                            ? null
                            : (v) => saveTimeLimit(v.round(), afterLimitId),
                  ),
                if (limitMinutes > 0)
                  DropdownButtonFormField<String>(
                    value:
                        collections.any((c) => '${c['id']}' == afterLimitId)
                            ? afterLimitId
                            : '',
                    decoration: const InputDecoration(
                      labelText: '额度用完后可看',
                      prefixIcon: Icon(Icons.nights_stay_rounded),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('不指定（用完后什么也看不到）'),
                      ),
                      ...collections.map(
                        (c) => DropdownMenuItem(
                          value: '${c['id']}',
                          child: Text('${c['title']}'),
                        ),
                      ),
                    ],
                    onChanged:
                        busy
                            ? null
                            : (v) => saveTimeLimit(limitMinutes, v ?? ''),
                  ),
                if (limitMinutes > 0 && afterLimitId.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      '不指定合集时，额度用完后儿童端将看不到任何视频。',
                      style: TextStyle(color: Color(0xff718081), fontSize: 12),
                    ),
                  ),
                Text(
                  limitMinutes > 0
                      ? (limitReached
                          ? '今日额度已用完，儿童端只剩所选合集的内容'
                          : '今日已看 $watchedMinutes 分钟，还剩 ${(limitMinutes - watchedMinutes).clamp(0, limitMinutes)} 分钟')
                      : '今日已看 $watchedMinutes 分钟',
                  style: const TextStyle(
                    color: Color(0xff718081),
                    fontSize: 12,
                  ),
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
          library: videoTotal,
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
                  onPressed:
                      busy
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
        OutlinedButton.icon(
          onPressed: openInbox,
          icon: const Icon(Icons.move_to_inbox_outlined),
          label: Text('查看待同步收集箱（${inbox.length}）'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: openTasks,
          icon: const Icon(Icons.downloading_outlined),
          label: const Text('查看导入任务列表'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('上传本地视频'),
          onPressed:
              busy
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
    await perform(loadCollectionVideos);
    if (!mounted || collectionVideos == null) return;
    final draft = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder:
            (_) => CollectionEditor(
              collection: collection,
              videos: collectionVideos!,
            ),
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
      builder:
          (context) => AlertDialog(
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
            child:
                error != null
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
      builder:
          (context, value, _) => FloatingActionButton(
            tooltip: value.isPlaying ? '暂停' : '播放',
            onPressed:
                !value.isInitialized
                    ? null
                    : () =>
                        value.isPlaying
                            ? controller.pause()
                            : controller.play(),
            child: Icon(
              value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
    ),
  );
}
