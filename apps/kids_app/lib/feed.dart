import 'dart:async';
import 'feed_player_cache.dart';
import 'playback_progress.dart';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

const accent = Color(0xfffe2c55);
const cyan = Color(0xff25f4ee);

/// The overlay is independent of the player so layout and interactions can be
/// tested without a native decoder, at phone, tablet and TV resolutions.
class FeedOverlay extends StatelessWidget {
  final Map<String, dynamic> video;
  final bool liked, downloaded, saving;
  final VoidCallback onLike, onDownload, onCollections;
  const FeedOverlay({
    super.key,
    required this.video,
    required this.liked,
    required this.downloaded,
    required this.saving,
    required this.onLike,
    required this.onDownload,
    required this.onCollections,
  });
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x66000000),
                  Colors.transparent,
                  Colors.transparent,
                  Color(0xd9000000),
                ],
                stops: [0, .22, .48, 1],
              ),
            ),
          ),
        ),
      ),
      Positioned(
        right: 10,
        bottom: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: '家庭精选',
              child: Container(
                width: 48,
                height: 48,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  gradient: const LinearGradient(
                    colors: [Color(0xff306e62), Color(0xff102a29)],
                  ),
                ),
                child: const Icon(
                  Icons.home_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
            action(
              liked ? Icons.favorite : Icons.favorite_rounded,
              '喜欢',
              onLike,
              color: liked ? accent : Colors.white,
            ),
            action(
              downloaded ? Icons.download_done_rounded : Icons.download_rounded,
              saving
                  ? '下载中'
                  : downloaded
                  ? '已缓存'
                  : '缓存',
              onDownload,
              color: downloaded ? cyan : Colors.white,
            ),
            action(Icons.video_library_rounded, '合集', onCollections),
            Container(
              width: 43,
              height: 43,
              margin: const EdgeInsets.only(top: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xff242424),
                border: Border.all(color: const Color(0xff424242), width: 7),
              ),
              child: const Icon(
                Icons.music_note,
                color: Colors.white,
                size: 21,
              ),
            ),
          ],
        ),
      ),
      Positioned(
        left: 16,
        right: 82,
        bottom: 34,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '@家长精选',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 5, color: Colors.black)],
              ),
            ),
            const SizedBox(height: 9),
            Text(
              '${video['title']}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.45,
              ),
            ),
            if ('${video['description'] ?? ''}'.isNotEmpty &&
                video['description'] != video['title']) ...[
              const SizedBox(height: 5),
              Text(
                '${video['description']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.music_note, size: 15, color: Colors.white),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    video['local_path'] != null ? '离线视频 · 原声' : '抖音儿童版 · 视频原声',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
  Widget action(
    IconData icon,
    String label,
    VoidCallback callback, {
    Color color = Colors.white,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 17),
    child: Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: saving && label == '下载中' ? null : callback,
        radius: 30,
        child: SizedBox(
          width: 54,
          child: Column(
            children: [
              Icon(
                icon,
                size: 35,
                color: color,
                shadows: const [Shadow(color: Colors.black45, blurRadius: 5)],
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class FeedView extends StatefulWidget {
  final FamilyApi api;
  final List<dynamic> items;
  final int start;
  final bool active;
  final PlaybackProgress? progress;
  final ValueChanged<String>? onVideoChanged;
  final Set<String> favorites, downloaded;
  final ValueChanged<String> onLike;
  final Future<void> Function(Map<String, dynamic>) onDownload;
  final VoidCallback onCollections;
  const FeedView({
    super.key,
    required this.api,
    required this.items,
    this.start = 0,
    this.active = true,
    this.progress,
    this.onVideoChanged,
    required this.favorites,
    required this.downloaded,
    required this.onLike,
    required this.onDownload,
    required this.onCollections,
  });
  @override
  State<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<FeedView> with WidgetsBindingObserver {
  late final PageController pages;
  VideoPlayerController? player;
  final playerCache = FeedPlayerCache();
  CachedFeedPlayer? activeEntry;
  late int index;
  int generation = 0;
  String? error;
  bool sessionEnded = false, saving = false, resumeWhenActive = true;
  late final Timer session;
  late final Timer progressTimer;
  late final PlaybackProgress progress =
      widget.progress ?? PlaybackProgress(widget.api.server);
  String? playingId;
  bool restoringPosition = false;
  bool appActive = true;

  void remember() {
    final p = player;
    if (playingId != null &&
        p?.value.isInitialized == true &&
        !restoringPosition) {
      progress.record(playingId!, p!.value.position, p.value.duration);
    }
  }

  void observePlayer() {
    remember();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    index = widget.start;
    pages = PageController(initialPage: index);
    load(index);
    progressTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      remember();
      unawaited(progress.flush());
    });
    session = Timer(const Duration(minutes: 20), () {
      player?.pause();
      if (mounted) setState(() => sessionEnded = true);
    });
  }

  @override
  void didUpdateWidget(covariant FeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.items.indexWhere((v) => '${v['id']}' == playingId);
    if (next >= 0 &&
        activeEntry?.source !=
            FeedPlayerCache.sourceKey(
              Map<String, dynamic>.from(widget.items[next]),
              widget.api,
            )) {
      load(next);
    }
    if (oldWidget.active != widget.active) {
      if (!widget.active) {
        resumeWhenActive = player?.value.isInitialized == true
            ? player!.value.isPlaying
            : !sessionEnded;
        remember();
        unawaited(progress.flush());
        player?.pause();
      } else if (resumeWhenActive &&
          appActive &&
          !sessionEnded &&
          player?.value.isInitialized == true) {
        player?.play();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appActive = state == AppLifecycleState.resumed;
    if (!appActive) {
      remember();
      unawaited(progress.flush());
      player?.pause();
    }
  }

  @override
  void didHaveMemoryPressure() {
    playerCache.releaseInactive(activeEntry);
  }

  Future<void> load(int next) async {
    final epoch = ++generation;
    final previous = player;
    remember();
    unawaited(progress.flush());
    previous?.removeListener(observePlayer);
    final v = Map<String, dynamic>.from(widget.items[next]);
    final entry = playerCache.obtain(v, widget.api, progress);
    activeEntry = entry;
    playingId = '${v['id']}';
    restoringPosition = true;
    player = entry.controller;
    error = null;
    if (mounted) setState(() => index = next);
    widget.onVideoChanged?.call(playingId!);
    try {
      try {
        await previous?.pause();
      } catch (_) {
        /* A failed player may already be released. */
      }
      if (!mounted || epoch != generation) return;
      // For a retained player this future is already complete: do not seek or
      // initialize again, since doing so discards useful native buffering.
      await entry.ready;
      if (!mounted || epoch != generation || entry.closed) return;
      final current = entry.controller;
      player = current;
      restoringPosition = false;
      current.addListener(observePlayer);
      if (!sessionEnded && widget.active && appActive) await current.play();
      if (!mounted || epoch != generation) {
        if (!identical(activeEntry, entry) && !entry.closed) {
          await current.pause();
        }
        return;
      }
      setState(() {});
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(() => error = '暂时无法播放\n返回刷新或选择已缓存视频');
      }
    }
  }

  void move(int delta) {
    final next = index + delta;
    if (!sessionEnded && next >= 0 && next < widget.items.length) {
      pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void toggle() {
    final p = player;
    if (!sessionEnded && p != null && p.value.isInitialized) {
      p.value.isPlaying ? p.pause() : p.play();
    }
  }

  void seek(int delta) {
    final p = player;
    if (p != null && p.value.isInitialized && !sessionEnded) {
      p.seekTo(
        Duration(
          seconds: (p.value.position.inSeconds + delta).clamp(
            0,
            p.value.duration.inSeconds,
          ),
        ),
      );
    }
  }

  Future<void> save(Map<String, dynamic> video) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await widget.onDownload(video);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    remember();
    unawaited(progress.flush());
    player?.removeListener(observePlayer);
    progressTimer.cancel();
    session.cancel();
    pages.dispose();
    unawaited(playerCache.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => seek(-10),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => seek(10),
      const SingleActivator(LogicalKeyboardKey.select): toggle,
      const SingleActivator(LogicalKeyboardKey.enter): toggle,
      const SingleActivator(LogicalKeyboardKey.space): toggle,
    },
    child: Focus(
      autofocus: true,
      child: sessionEnded
          ? const Center(
              child: Text(
                '看了二十分钟啦\n休息一下吧',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 26),
              ),
            )
          : PageView.builder(
              controller: pages,
              scrollDirection: Axis.vertical,
              itemCount: widget.items.length,
              onPageChanged: load,
              itemBuilder: (context, i) {
                final v = Map<String, dynamic>.from(widget.items[i]);
                final p = i == index ? player : null;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onTap: toggle,
                      onDoubleTap: () {
                        if (!widget.favorites.contains(v['id'])) {
                          widget.onLike(v['id']);
                        }
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: p?.value.isInitialized == true
                            ? AspectRatio(
                                aspectRatio: p!.value.aspectRatio,
                                child: VideoPlayer(p),
                              )
                            : error != null && i == index
                            ? Text(
                                error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              )
                            : i != index
                            ? const SizedBox.shrink()
                            : const CircularProgressIndicator(
                                color: Colors.white70,
                                strokeWidth: 2,
                              ),
                      ),
                    ),
                    if (p?.value.isInitialized == true)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: p!,
                        builder: (context, value, _) => IgnorePointer(
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: value.isPlaying ? 0 : 1,
                              duration: const Duration(milliseconds: 150),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                size: 82,
                                color: Colors.white54,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (p?.value.isInitialized == true)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: p!,
                        builder: (_, value, _) => value.isBuffering
                            ? const IgnorePointer(
                                child: Center(
                                  child: SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      color: Colors.white70,
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    FeedOverlay(
                      video: v,
                      liked: widget.favorites.contains(v['id']),
                      downloaded:
                          widget.downloaded.contains(v['id']) ||
                          v['local_path'] != null,
                      saving: saving,
                      onLike: () => widget.onLike(v['id']),
                      onDownload: () => save(v),
                      onCollections: widget.onCollections,
                    ),
                    if (p?.value.isInitialized == true)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: VideoProgressIndicator(
                          p!,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          colors: const VideoProgressColors(
                            playedColor: Colors.white,
                            bufferedColor: Colors.white30,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
    ),
  );
}

class FeedNavigation extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  const FeedNavigation({
    super.key,
    required this.selected,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SizedBox(
      height: 57,
      child: Row(
        children: List.generate(
          5,
          (i) => Expanded(
            child: InkWell(
              onTap: () => onSelect(i),
              child: Center(
                child: i == 2
                    ? Container(
                        width: 44,
                        height: 30,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          gradient: const LinearGradient(
                            colors: [cyan, Colors.white, Colors.white, accent],
                            stops: [0, .17, .83, 1],
                          ),
                        ),
                        child: const Icon(
                          Icons.download_rounded,
                          color: Colors.black,
                          size: 25,
                        ),
                      )
                    : Text(
                        ['首页', '合集', '离线', '喜欢', '我'][i],
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: i == selected ? Colors.white : Colors.white54,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
