import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'downloads.dart';
import 'feed.dart';
import 'pages.dart';
import 'playback_progress.dart';
import 'playback_disk_cache.dart';
import 'recommendations.dart';
import 'time_budget.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '抖音儿童版',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ),
      ),
      home: const KidsHome(),
    ),
  );
}

class KidsHome extends StatefulWidget {
  final FamilyApi? api;
  final Downloads? downloads;
  final LanDiscovery? discovery;
  const KidsHome({super.key, this.api, this.downloads, this.discovery});
  @override
  State<KidsHome> createState() => _KidsHomeState();
}

class _KidsHomeState extends State<KidsHome> with WidgetsBindingObserver {
  late final api = widget.api ?? FamilyApi();
  late final downloads = widget.downloads ?? Downloads(api);
  // 家长设定的每日额度：先恢复缓存，耗尽后按安静模式收缩内容。
  late final budget = TimeBudget(api);
  final address = TextEditingController(text: 'http://192.168.1.10:8765');
  List<dynamic> videos = [], collections = [], offline = [];
  Set<String> favorites = {};
  bool busy = false, connected = false, previewOpen = false;
  int tab = 0, feedRevision = 0;
  String? error;
  RecommendationOrder order = RecommendationOrder();
  PlaybackProgress? savedProgress;
  String? lastRecommendation;
  PlaybackProgress get progress {
    if (savedProgress?.server != api.server) {
      savedProgress = PlaybackProgress(api.server);
    }
    return savedProgress!;
  }

  String get favoriteKey =>
      'favorites_${sha256.convert(utf8.encode('${api.server}|${api.token}'))}';
  bool _wasExhausted = false;
  @override
  void initState() {
    super.initState();
    budget.addListener(_onBudgetChanged);
    WidgetsBinding.instance.addObserver(this);
    sync.addListener(onSyncChanged);
    restore();
  }

  /// 额度用完/恢复时切换安静模式：只重建列表，不弹任何提示。
  void _onBudgetChanged() {
    if (!mounted) return;
    final exhausted = budget.exhausted;
    if (exhausted == _wasExhausted) return;
    _wasExhausted = exhausted;
    setState(() => feedRevision++);
  }

  /// 安静模式的可见内容池：家长指定的合集；未指定或合集已删除时为空。
  List<dynamic> get quietPool {
    final id = budget.afterLimitCollectionId;
    if (id.isEmpty) return const [];
    for (final c in collections) {
      if ('${c['id']}' == id) return List<dynamic>.from(c['videos'] as List);
    }
    return const [];
  }

  StartupCache get startup => StartupCache(api.server, api.clientRole);
  late final sync = BackgroundSync(() => fetchCatalog(progressive: true));
  bool restoring = true, networkReady = false, updateChecked = false;

  void onSyncChanged() {
    if (!mounted || restoring) return;
    setState(() {});
    if (sync.online == true && !updateChecked) {
      updateChecked = true;
      unawaited(checkForUpdate());
    }
  }

  Future<void> restore() async {
    try {
      await api.restore();
      if (api.server.isNotEmpty) {
        address.text = api.server;
        await restoreServerState();
      }
    } catch (e) {
      error = friendlyError(e);
    }
    if (!mounted) return;
    setState(() {
      restoring = false;
      connected = api.server.isNotEmpty;
    });
    if (connected) unawaited(sync.run());
  }

  Future<void> restoreServerState() async {
    final server = api.server;
    final cache = startup;
    // Apply the saved allowance before revealing any cached catalog entries.
    await budget.restoreCached();
    final saved = await Future.wait([
      cache.readList('videos'),
      cache.readList('collections'),
      cache.readText('last_video'),
      cache.readText('tab'),
    ]);
    if (!mounted || server != api.server) return;
    videos = saved[0] as List;
    collections = saved[1] as List;
    lastRecommendation = budget.exhausted ? null : saved[2] as String?;
    tab = (int.tryParse(saved[3] as String? ?? '') ?? 0).clamp(0, 4);
    // File checks may be slow on older devices; they don't delay the catalog.
    unawaited(
      localState().then((_) {
        if (mounted && server == api.server) setState(() {});
      }),
    );
  }

  void selectTab(int value) {
    setState(() => tab = value);
    unawaited(startup.write('tab', '$value'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    sync.setActive(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed && connected && !restoring) {
      unawaited(sync.run());
    }
  }

  /// 连接后检查服务端是否有更新的安装包；失败静默，绝不影响观看。
  Future<void> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final update = await api.latestUpdate('kids');
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
                  content: Text('抖音儿童版有新版本 v${update.version}，请家长帮忙下载更新。'),
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
      /* 更新检查失败不打扰孩子观看。 */
    }
  }

  Future<void> localState() async {
    final server = api.server;
    final key = favoriteKey;
    List<dynamic> nextOffline = [];
    try {
      nextOffline = await downloads.list();
    } catch (_) {
      /* Broken local index doesn't prevent startup. */
    }
    final nextFavorites =
        (await SharedPreferences.getInstance()).getStringList(key)?.toSet() ??
        <String>{};
    if (!mounted || api.server != server) return;
    offline = nextOffline;
    favorites = nextFavorites;
  }

  Future<void> refresh() async {
    sync.reset(); // Explicit refresh/mutation must supersede older background reads.
    await sync.run(action: () => fetchCatalog(progressive: false));
    if (sync.error != null) throw sync.error!;
  }

  Future<void> fetchCatalog({required bool progressive}) async {
    final server = api.server;
    final generation = sync.generation;
    final cache = startup;
    final verified = api.checkServer();
    final loaded = <String, List<dynamic>>{};
    Object? failure;
    void apply(String section, List<dynamic> items) {
      if (!mounted || api.server != server || sync.generation != generation) {
        return;
      }
      setState(() {
        if (section == 'videos') {
          videos = items;
          networkReady = true;
        }
        if (section == 'collections') collections = items;
      });
      unawaited(cache.write(section, items));
    }

    Future<void> section(String name) async {
      try {
        final results = await Future.wait([
          verified,
          api.requestWithTimeout(
            'GET',
            '/api/$name',
            timeout: const Duration(seconds: 5),
          ),
        ]);
        final items = results[1] as List;
        loaded[name] = items;
        if (progressive) apply(name, items);
      } catch (e) {
        failure ??= e;
      }
    }

    unawaited(budget.load());
    await Future.wait([section('videos'), section('collections')]);
    if (!mounted || api.server != server || sync.generation != generation) {
      return;
    }
    if (failure != null) throw failure!;
    if (!progressive) {
      for (final entry in loaded.entries) {
        apply(entry.key, entry.value);
      }
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
    if (mounted) setState(() => busy = false);
  }

  void toggleFavorite(String id) {
    setState(() {
      if (!favorites.add(id)) favorites.remove(id);
    });
    SharedPreferences.getInstance().then(
      (p) => p.setStringList(favoriteKey, favorites.toList()),
    );
  }

  Future<void> saveVideo(Map<String, dynamic> video) async {
    if (video['local_path'] != null) return;
    await downloads.save(video);
    offline = await downloads.list();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存，离线也能看')));
    }
  }

  Set<String> get downloaded => offline.map((v) => v['id'] as String).toSet();
  void showCollections() {
    setState(() => tab = 1);
  }

  Future<void> play(List<dynamic> items, [int index = 0]) async {
    if (items.isEmpty) return;
    final requested = '${items[index]['id']}';
    if (!networkReady && items.any((item) => item['local_path'] == null)) {
      await sync.run();
      if (!mounted) return;
    }
    final local = {for (final item in offline) '${item['id']}': item};
    final fresh = {
      if (networkReady)
        for (final item in videos) '${item['id']}': item,
    };
    items = [
      for (final item in items)
        if (item['local_path'] != null)
          item
        else if (local.containsKey('${item['id']}'))
          local['${item['id']}']
        else if (fresh.containsKey('${item['id']}'))
          fresh['${item['id']}'],
    ];
    if (items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法播放，请连接家庭电脑或选择已下载视频')));
      }
      return;
    }
    index = items
        .indexWhere((item) => '${item['id']}' == requested)
        .clamp(0, items.length - 1);
    setState(() => previewOpen = true);
    try {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder:
              (_) => StatefulBuilder(
                builder:
                    (context, update) => Scaffold(
                      backgroundColor: Colors.black,
                      appBar: AppBar(
                        backgroundColor: Colors.black,
                        title: const Text('家庭精选'),
                      ),
                      body: FeedView(
                        api: api,
                        progress: progress,
                        budget: budget,
                        items: items,
                        start: index,
                        favorites: favorites,
                        downloaded: downloaded,
                        onLike: (id) {
                          toggleFavorite(id);
                          update(() {});
                        },
                        onDownload: (v) async {
                          await saveVideo(v);
                          if (context.mounted) update(() {});
                        },
                        onCollections: () {
                          Navigator.pop(context);
                          showCollections();
                        },
                      ),
                    ),
              ),
        ),
      );
    } finally {
      if (mounted) setState(() => previewOpen = false);
    }
  }

  Future<void> connectServer() async {
    final oldServer = api.server;
    await api.save(address.text);
    sync.reset();
    networkReady = false;
    updateChecked = false;
    if (oldServer != api.server) {
      budget.reset();
      videos = [];
      collections = [];
      offline = [];
      favorites = {};
      order = RecommendationOrder();
      lastRecommendation = null;
      savedProgress = null;
      feedRevision++;
    }
    await restoreServerState();
    if (!mounted) return;
    setState(() => connected = true);
    unawaited(sync.run());
  }

  @override
  void dispose() {
    budget.removeListener(_onBudgetChanged);
    WidgetsBinding.instance.removeObserver(this);
    sync.dispose();
    if (widget.api == null) api.close();
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      restoring
          ? const Scaffold(body: Center(child: Text('正在恢复上次内容…')))
          : connected
          ? connectedScreen()
          : KidsConnectionPage(
            address: address,
            busy: busy,
            error: error,
            onConnect: () => perform(connectServer),
            discovery: widget.discovery,
          );

  Widget connectedScreen() => Scaffold(
    backgroundColor: Colors.black,
    bottomNavigationBar: FeedNavigation(selected: tab, onSelect: selectTab),
    body: Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child:
              tab == 0
                  ? feed()
                  : SafeArea(child: tab == 4 ? profile() : contentList()),
        ),
        if (tab == 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '我的合集',
                      onPressed: showCollections,
                      icon: const Icon(Icons.menu, color: Colors.white),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: showCollections,
                      child: const Text(
                        '合集',
                        style: TextStyle(color: Colors.white60, fontSize: 17),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '推荐',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 19,
                          ),
                        ),
                        Container(
                          width: 22,
                          height: 3,
                          margin: const EdgeInsets.only(top: 5),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '搜索精选',
                      onPressed: search,
                      icon: const Icon(
                        Icons.search,
                        color: Colors.white,
                        size: 29,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (busy)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(color: accent),
          ),
        if (sync.syncing && tab == 0)
          const Positioned(
            top: 78,
            right: 16,
            child: SafeArea(
              child: Text(
                '正在同步',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ),
        if ((error != null || sync.error != null) && tab == 0)
          Positioned(
            top: 100,
            left: 16,
            right: 16,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off, size: 18, color: Colors.white60),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        offline.isNotEmpty
                            ? '电脑暂时离线，正在播放已缓存内容'
                            : '暂时未能更新，已保留当前内容',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: busy ? null : () => perform(refresh),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
  Widget feed() {
    final connectionError = error != null || sync.online == false;
    final List<dynamic> items;
    if (budget.exhausted) {
      // 安静模式：没有任何提示，当前这条自然播完，之后只能刷到
      // 家长指定合集里的内容；未指定合集时就像内容都被看完了一样。
      final pool = quietPool;
      final current = <dynamic>[];
      if (lastRecommendation != null) {
        for (final v in [...videos, ...offline]) {
          if ('${v['id']}' == lastRecommendation) {
            current.add(v);
            break;
          }
        }
      }
      final seen = {for (final v in current) '${v['id']}'};
      items = [...current, ...pool.where((v) => seen.add('${v['id']}'))];
    } else {
      final source = List<dynamic>.from(videos.isNotEmpty ? videos : offline);
      // A downloaded clip may be playing before the network catalog arrives.
      // Keep it in the current queue so background sync doesn't cut it off.
      final currentOffline = offline.where(
        (item) => item['id'] == lastRecommendation,
      );
      if (currentOffline.isNotEmpty &&
          !source.any((item) => item['id'] == lastRecommendation)) {
        source.insert(0, currentOffline.first);
      }
      items = order.arrange(source);
    }
    if (items.isEmpty) {
      if (busy || sync.syncing) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sync, color: Colors.white54),
              SizedBox(height: 18),
              Text(
                '正在准备好内容…',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        );
      }
      return KidsEmptyState(
        icon:
            !connectionError
                ? Icons.video_library_outlined
                : Icons.wifi_off_rounded,
        title: !connectionError ? '好内容，等家长为你精选' : '暂时连接不上家庭电脑',
        message:
            !connectionError
                ? '家长添加的视频处理好后，就会出现在这里。\n先去看看你喜欢的合集吧。'
                : '请确认设备连接了家庭网络。\n已经缓存的视频，离线也能看。',
        actionLabel: '刷新看看',
        onAction: () => perform(refresh),
      );
    }
    final localById = {for (final item in offline) '${item['id']}': item};
    final playable = [
      for (final item in items) localById['${item['id']}'] ?? item,
    ];
    if (!networkReady && playable.every((item) => item['local_path'] == null)) {
      final cached = playable.firstWhere(
        (item) => item['id'] == lastRecommendation,
        orElse: () => playable.first,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          if (cached['thumbnail_url'] != null)
            CachedThumbnail(
              api.uri(cached['thumbnail_url']).toString(),
              fit: BoxFit.contain,
            ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.movie_outlined,
                    size: 48,
                    color: Colors.white54,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${cached['title']}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sync.error == null ? '正在后台同步，连接后继续观看' : '电脑暂时离线，目录已保留',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final feedItems =
        networkReady
            ? playable
            : playable.where((item) => item['local_path'] != null).toList();
    return FeedView(
      key: ValueKey('feed_$feedRevision'),
      active: !previewOpen,
      api: api,
      items: feedItems,
      progress: progress,
      budget: budget,
      start: feedItems
          .indexWhere((v) => v['id'] == lastRecommendation)
          .clamp(0, feedItems.length - 1),
      onVideoChanged: (id) {
        lastRecommendation = id;
        unawaited(startup.write('last_video', id));
      },
      favorites: favorites,
      downloaded: downloaded,
      onLike: toggleFavorite,
      onDownload: saveVideo,
      onCollections: showCollections,
      // 刷完全部内容后，在顶部下拉或底部上拉自动拉取服务器最新视频；
      // 成功后新内容按推荐顺序追加，当前视频保持播放位置。
      onLoadLatest: () => perform(refresh),
    );
  }

  List<dynamic> get availableVideos {
    // 安静模式：搜索同样只剩指定合集的内容。
    if (budget.exhausted) return quietPool;
    final byId = <String, dynamic>{for (final v in videos) '${v['id']}': v};
    for (final v in offline) {
      byId['${v['id']}'] = v;
    }
    return byId.values.toList();
  }

  Widget contentList() {
    // 安静模式下各页签同步收缩：合集只剩指定的一个，离线与喜欢隐藏。
    final quiet = budget.exhausted;
    final list =
        tab == 1
            ? (quiet
                ? collections
                    .where((c) => '${c['id']}' == budget.afterLimitCollectionId)
                    .toList()
                : collections)
            : tab == 2
            ? (quiet ? <dynamic>[] : offline)
            : availableVideos
                .where((v) => favorites.contains(v['id']))
                .toList();
    final title = ['', '我的合集', '离线缓存', '我喜欢的'][tab];
    final tips = ['', '按主题发现，按喜欢观看', '下载完成后，离开网络也能看', '把喜欢的每一段，留在这里'][tab];
    return RefreshIndicator(
      color: accent,
      onRefresh: busy ? () async {} : () => perform(refresh),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新内容',
                onPressed: busy ? null : () => perform(refresh),
                icon: const Icon(Icons.refresh_rounded, color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            tips,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 18),
          Text(
            '${list.length} ${tab == 1 ? '个合集' : '条视频'}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (list.isEmpty)
            KidsEmptyState(
              icon:
                  tab == 1
                      ? Icons.video_library_outlined
                      : tab == 2
                      ? Icons.download_outlined
                      : Icons.favorite_border,
              title:
                  tab == 1
                      ? '合集正在准备中'
                      : tab == 2
                      ? '还没有缓存的视频'
                      : '喜欢的内容会留在这里',
              message:
                  tab == 1
                      ? '家长整理好后，就能一口气看个够。'
                      : tab == 2
                      ? '观看时点一下右侧的缓存按钮，\n下次没有网络也能看。'
                      : '看到喜欢的视频，点亮小红心。',
              actionLabel: tab == 1 ? '刷新看看' : '去看看好内容',
              onAction:
                  busy
                      ? null
                      : tab == 1
                      ? () => perform(refresh)
                      : () => setState(() => tab = 0),
            ),
          ...list.asMap().entries.map((entry) {
            final v = Map<String, dynamic>.from(entry.value);
            if (tab == 1) {
              return KidsCollectionCard(
                collection: v,
                index: entry.key,
                onPlay: () => play(v['videos'] as List),
                onDownload:
                    busy
                        ? null
                        : () => perform(() async {
                          for (final item in v['videos']) {
                            await saveVideo(Map<String, dynamic>.from(item));
                          }
                        }),
              );
            }
            return KidsMediaTile(
              video: v,
              url: (path) => api.uri(path).toString(),
              offline: v['local_path'] != null,
              onPlay: () => play(list, entry.key),
              onDelete: tab == 2 && !busy ? () => deleteCachedVideo(v) : null,
            );
          }),
        ],
      ),
    );
  }

  Future<void> deleteCachedVideo(Map<String, dynamic> video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('删除这条缓存？'),
            content: const Text('只删除本机缓存，家庭电脑上的视频会继续保留。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保留'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除缓存'),
              ),
            ],
          ),
    );
    if (confirmed == true && mounted) {
      await perform(() async {
        await downloads.remove(video);
        await localState();
      });
    }
  }

  Widget profile() => RefreshIndicator(
    color: accent,
    onRefresh: busy ? () async {} : () => perform(refresh),
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 20),
        const CircleAvatar(
          radius: 40,
          backgroundColor: Color(0xff25282b),
          child: Icon(Icons.person, size: 48, color: Colors.white),
        ),
        const SizedBox(height: 18),
        const Center(
          child: Text(
            '我的放映室',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 30),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            stat('${favorites.length}', '喜欢'),
            stat('${offline.length}', '已缓存'),
            stat('${collections.length}', '合集'),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          '我的设备',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 10),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('家庭服务器'),
          subtitle: Text(api.server),
        ),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('刷新内容'),
          onTap: busy ? null : () => perform(refresh),
        ),
        ListTile(
          leading: const Icon(Icons.offline_pin_outlined),
          title: const Text('管理离线缓存'),
          onTap: () => setState(() => tab = 2),
        ),
        ListTile(
          leading: const Icon(Icons.schedule_rounded),
          title: Text('今日已看 ${budget.watchedMinutes} 分钟'),
          subtitle: Text(
            budget.limited ? '家长设定每天最多 ${budget.limitMinutes} 分钟' : '家长未限制观看时长',
          ),
        ),
        const PlaybackCachePanel(),
        ListTile(
          leading: const Icon(Icons.settings_ethernet),
          title: const Text('更换服务器'),
          onTap:
              busy
                  ? null
                  : () => perform(() async {
                    sync.reset();
                    networkReady = false;
                    updateChecked = false;
                    await api.logout();
                    connected = false;
                    videos = [];
                    collections = [];
                    offline = [];
                    favorites = {};
                    tab = 0;
                    order = RecommendationOrder();
                    lastRecommendation = null;
                    savedProgress = null;
                    feedRevision++;
                  }),
        ),
        if (error != null)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              '暂时未能更新内容，可以重试或继续观看已缓存视频。',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ),
      ],
    ),
  );
  Widget stat(String number, String label) => Container(
    constraints: const BoxConstraints(minWidth: 76),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    decoration: BoxDecoration(
      color: kidsSurface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        Text(
          number,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 5),
        Text(label, style: const TextStyle(color: Colors.white54)),
      ],
    ),
  );
  Future<void> search() async {
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kidsSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => KidsSearchSheet(videos: availableVideos),
    );
    if (selected != null && mounted) await play([selected]);
  }
}
