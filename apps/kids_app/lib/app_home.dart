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
  const KidsHome({super.key, this.api, this.downloads});
  @override
  State<KidsHome> createState() => _KidsHomeState();
}

class _KidsHomeState extends State<KidsHome> {
  late final api = widget.api ?? FamilyApi();
  late final downloads = widget.downloads ?? Downloads(api);
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
  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    await perform(() async {
      await api.restore();
      if (api.server.isNotEmpty) address.text = api.server;
      connected = api.server.isNotEmpty;
      if (connected) {
        await localState();
        await refresh();
        unawaited(checkForUpdate());
      }
    });
  }

  /// 连接后检查服务端是否有更新的安装包；失败静默，绝不影响观看。
  Future<void> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final update = await api.latestUpdate('kids');
      if (update == null || !isNewerVersion(update.version, info.version)) {
        return;
      }
      if (!mounted || error != null) return;
      final go = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('发现新版本'),
              content: Text(
                '抖音儿童版有新版本 v${update.version}，请家长帮忙下载更新。',
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
      /* 更新检查失败不打扰孩子观看。 */
    }
  }

  Future<void> localState() async {
    offline = await downloads.list();
    favorites =
        (await SharedPreferences.getInstance())
            .getStringList(favoriteKey)
            ?.toSet() ??
        {};
  }

  Future<void> refresh() async {
    await api.checkServer();
    final nextVideos = await api.request('GET', '/api/videos') as List;
    final nextCollections =
        await api.request('GET', '/api/collections') as List;
    await localState();
    if (!mounted) return;
    videos = nextVideos;
    collections = nextCollections;
    feedRevision++;
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
      if (offline.isNotEmpty) feedRevision++;
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
    setState(() => previewOpen = true);
    try {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => StatefulBuilder(
            builder: (context, update) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                backgroundColor: Colors.black,
                title: const Text('家庭精选'),
              ),
              body: FeedView(
                api: api,
                progress: progress,
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
    if (oldServer != api.server) {
      order = RecommendationOrder();
      lastRecommendation = null;
    }
    connected = true;
    await localState();
    await refresh();
  }

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => connected
      ? connectedScreen()
      : KidsConnectionPage(
          address: address,
          busy: busy,
          error: error,
          onConnect: () => perform(connectServer),
        );

  Widget connectedScreen() => Scaffold(
    backgroundColor: Colors.black,
    bottomNavigationBar: FeedNavigation(
      selected: tab,
      onSelect: (i) => setState(() => tab = i),
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: tab == 0
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
        if (error != null && tab == 0)
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
    final source = error != null && offline.isNotEmpty
        ? offline
        : videos.isNotEmpty
        ? videos
        : offline;
    final items = order.arrange(source);
    if (items.isEmpty) {
      if (busy) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: accent, strokeWidth: 2),
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
        icon: error == null
            ? Icons.video_library_outlined
            : Icons.wifi_off_rounded,
        title: error == null ? '好内容，等家长为你精选' : '暂时连接不上家庭电脑',
        message: error == null
            ? '家长添加的视频处理好后，就会出现在这里。\n先去看看你喜欢的合集吧。'
            : '请确认设备连接了家庭网络。\n已经缓存的视频，离线也能看。',
        actionLabel: '刷新看看',
        onAction: () => perform(refresh),
      );
    }
    return FeedView(
      key: ValueKey('feed_$feedRevision'),
      active: !previewOpen,
      api: api,
      items: items,
      progress: progress,
      start: items
          .indexWhere((v) => v['id'] == lastRecommendation)
          .clamp(0, items.length - 1),
      onVideoChanged: (id) => lastRecommendation = id,
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
    final byId = <String, dynamic>{for (final v in videos) '${v['id']}': v};
    for (final v in offline) {
      byId['${v['id']}'] = v;
    }
    return byId.values.toList();
  }

  Widget contentList() {
    final list = tab == 1
        ? collections
        : tab == 2
        ? offline
        : availableVideos.where((v) => favorites.contains(v['id'])).toList();
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
              icon: tab == 1
                  ? Icons.video_library_outlined
                  : tab == 2
                  ? Icons.download_outlined
                  : Icons.favorite_border,
              title: tab == 1
                  ? '合集正在准备中'
                  : tab == 2
                  ? '还没有缓存的视频'
                  : '喜欢的内容会留在这里',
              message: tab == 1
                  ? '家长整理好后，就能一口气看个够。'
                  : tab == 2
                  ? '观看时点一下右侧的缓存按钮，\n下次没有网络也能看。'
                  : '看到喜欢的视频，点亮小红心。',
              actionLabel: tab == 1 ? '刷新看看' : '去看看好内容',
              onAction: busy
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
                onDownload: busy
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
      builder: (context) => AlertDialog(
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
        const PlaybackCachePanel(),
        ListTile(
          leading: const Icon(Icons.settings_ethernet),
          title: const Text('更换服务器'),
          onTap: busy
              ? null
              : () => perform(() async {
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
