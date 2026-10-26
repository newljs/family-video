import 'dart:async';
import 'feed_player_cache.dart';
import 'playback_progress.dart';
import 'time_budget.dart';
import 'watch_stats.dart';
import 'package:family_api/family_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
// playerId 为门面 testing-only 成员，倍速需经平台接口直调。
// ignore_for_file: invalid_use_of_visible_for_testing_member

const accent = Color(0xfffe2c55);
const cyan = Color(0xff25f4ee);

/// 门面 video_player 未暴露倍速设置，经平台接口直调（fork 的 ExoPlayer 已实现）。
Future<void> setPlayerSpeed(VideoPlayerController? controller, double speed) {
    if (controller == null || controller.playerId < 0) {
    return Future.value();
  }
  return VideoPlayerPlatform.instance.setPlaybackSpeed(
    controller.playerId,
    speed,
  );
}

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

  /// 家长设定的每日时长额度；为空时不启用时长控制（旧入口与测试兼容）。
  final TimeBudget? budget;
  final ValueChanged<String>? onVideoChanged;
  final Set<String> favorites, downloaded;
  final ValueChanged<String> onLike;
  final Future<void> Function(Map<String, dynamic>) onDownload;
  final VoidCallback onCollections;

  /// 在第一条继续下拉或最后一条继续上拉时触发，用于拉取服务器最新内容。
  final Future<void> Function()? onLoadLatest;
  const FeedView({
    super.key,
    required this.api,
    required this.items,
    this.start = 0,
    this.active = true,
    this.progress,
    this.budget,
    this.onVideoChanged,
    required this.favorites,
    required this.downloaded,
    required this.onLike,
    required this.onDownload,
    required this.onCollections,
    this.onLoadLatest,
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
  // 观看统计：按采样累计观看时长、播放次数与完播，批量上报服务器。
  // 服务端响应同时校正每日时长额度（家长端设定）。
  late final WatchReporter reporter = WatchReporter(
    widget.api,
    onSync: (data) => widget.budget?.apply(data),
  );
  final Map<String, Duration> lastSample = {};
  final Set<String> completedSeen = {};
  bool playCounted = false;
  // 休息提示生效：连续观看 20 分钟到点，且今日额度没有先耗尽。
  // 额度用完后进入安静模式（由列表收缩接管），不再弹任何提示。
  bool get blocked => sessionEnded && (widget.budget?.exhausted != true);
  // 播放手势瞬态：长按 2 倍速、水平拖动快进的预览位置（毫秒）。
  bool speeding = false;
  double? seekPreview;
  Duration seekTotal = Duration.zero;
  double seekTarget = 0;
  bool seekForward = true;

  // 边缘拖动加载最新：单次手势只触发一次，加载中与冷却期内不再触发。
  bool loadingLatest = false;
  bool edgeGestureConsumed = true;
  double edgeDragDistance = 0;
  DateTime edgeCooldownUntil = DateTime(2000);

  void remember() {
    final p = player;
    if (playingId == null || p?.value.isInitialized != true) return;
    if (!restoringPosition) {
      progress.record(playingId!, p!.value.position, p.value.duration);
      // 统计采样：正向播放增量计时长；首次开播计一次播放；接近片尾记完播。
      final position = p.value.position;
      final last = lastSample[playingId!];
      if (last != null && position > last) {
        final delta = position - last;
        reporter.record(playingId!, watched: delta);
        // 时长额度与统计同口径：只计正向播放增量，暂停与回拖不计。
        widget.budget?.spend(delta.inMilliseconds);
      }
      lastSample[playingId!] = position;
      if (!playCounted && p.value.isPlaying) {
        playCounted = true;
        reporter.record(playingId!, played: true);
      }
      if (!completedSeen.contains(playingId) &&
          p.value.duration > Duration.zero &&
          (p.value.isCompleted ||
              position >= p.value.duration - const Duration(milliseconds: 800))) {
        completedSeen.add(playingId!);
        reporter.record(playingId!, completed: true);
      }
    }
  }

  void observePlayer() {
    remember();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.budget?.addListener(onBudgetChanged);
    index = widget.start;
    pages = PageController(initialPage: index);
    load(index);
    progressTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      widget.budget?.tick(); // 跨天时额度重新开始
      remember();
      unawaited(progress.flush());
    });
    session = Timer(const Duration(minutes: 20), () {
      player?.pause();
      if (mounted) setState(() => sessionEnded = true);
    });
  }

  /// 额度变化只刷新角标；安静模式的列表收缩由页面层（KidsHome）处理，
  /// 播放绝不中断，让孩子感觉不到额度机制的存在。
  void onBudgetChanged() {
    if (!mounted) return;
    setState(() {});
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
            : !blocked;
        remember();
        unawaited(progress.flush());
        player?.pause();
      } else if (resumeWhenActive &&
          appActive &&
          !blocked &&
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
      unawaited(reporter.flush());
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
    resetPlaybackGestures();
    previous?.removeListener(observePlayer);
    final v = Map<String, dynamic>.from(widget.items[next]);
    final entry = playerCache.obtain(v, widget.api, progress);
    activeEntry = entry;
    playingId = '${v['id']}';
    playCounted = false; // 再次进入该视频重新计一次播放
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
      if (!blocked && widget.active && appActive) await current.play();
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
    if (!blocked && next >= 0 && next < widget.items.length) {
      pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void toggle() {
    final p = player;
    if (!blocked && p != null && p.value.isInitialized) {
      p.value.isPlaying ? p.pause() : p.play();
    }
  }

  void seek(int delta) {
    final p = player;
    if (p != null && p.value.isInitialized && !blocked) {
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

  /// 换页或释放播放器时复位倍速与快进预览，避免状态残留到下一条视频。
  void resetPlaybackGestures() {
    if (speeding) {
      setPlayerSpeed(player, 1.0);
      speeding = false;
    }
    seekPreview = null;
    seekTarget = 0;
    seekTotal = Duration.zero;
  }

  void startSpeedBoost() {
    final p = player;
    if (!blocked && !speeding && p != null && p.value.isInitialized) {
      setPlayerSpeed(p, 2.0);
      setState(() => speeding = true);
    }
  }

  void stopSpeedBoost() {
    if (!speeding) return;
    setPlayerSpeed(player, 1.0);
    if (mounted) setState(() => speeding = false);
  }

  void startSeekPreview(DragStartDetails details) {
    final p = player;
    if (blocked || speeding || p == null || !p.value.isInitialized) return;
    seekTarget = p.value.position.inMilliseconds.toDouble();
    seekTotal = p.value.duration;
    setState(() => seekPreview = seekTarget);
  }

  void updateSeekPreview(DragUpdateDetails details) {
    if (seekPreview == null) return;
    final p = player;
    if (p == null || !p.value.isInitialized || seekTotal <= Duration.zero) {
      return;
    }
    final width = MediaQuery.of(context).size.width;
    if (width <= 0) return;
    final total = seekTotal.inMilliseconds.toDouble();
    // 一屏宽的拖动距离最多快进/快退两分钟，避免长视频一划到底。
    final span = total > 120000 ? 120000.0 : total;
    seekTarget = (seekTarget + details.delta.dx / width * span).clamp(
      0.0,
      total,
    );
    seekForward = details.delta.dx >= 0;
    setState(() => seekPreview = seekTarget);
  }

  void endSeekPreview(DragEndDetails details) {
    final target = seekTarget;
    final active = seekPreview != null;
    final p = player;
    setState(() => seekPreview = null);
    if (!active || p == null || !p.value.isInitialized || blocked) {
      return;
    }
    p.seekTo(Duration(milliseconds: target.round()));
  }

  void cancelSeekPreview() {
    if (seekPreview != null && mounted) setState(() => seekPreview = null);
  }

  /// 第一条继续下拉 / 最后一条继续上拉超过阈值时拉取服务器最新内容。
  bool onEdgeScroll(ScrollNotification notice) {
    if (notice.depth != 0) return false;
    if (notice is ScrollStartNotification) {
      edgeGestureConsumed = false;
      edgeDragDistance = 0;
      return false;
    }
    double delta = 0;
    if (notice is OverscrollNotification) {
      delta = notice.overscroll;
    } else if (notice is ScrollUpdateNotification &&
        notice.metrics.outOfRange) {
      delta = notice.scrollDelta ?? 0;
    } else {
      return false;
    }
    if (delta == 0 ||
        widget.onLoadLatest == null ||
        loadingLatest ||
        edgeGestureConsumed ||
        DateTime.now().isBefore(edgeCooldownUntil)) {
      return false;
    }
    final atFirst = index <= 0;
    final atLast = index >= widget.items.length - 1;
    if (!(delta < 0 && atFirst) && !(delta > 0 && atLast)) return false;
    edgeDragDistance += delta;
    if (edgeDragDistance.abs() < 60) return false;
    edgeGestureConsumed = true;
    edgeDragDistance = 0;
    edgeCooldownUntil = DateTime.now().add(const Duration(seconds: 3));
    unawaited(loadLatest());
    return false;
  }

  Future<void> loadLatest() async {
    final callback = widget.onLoadLatest;
    if (callback == null || loadingLatest) return;
    loadingLatest = true;
    if (mounted) setState(() {});
    try {
      await callback();
    } catch (_) {
      /* 刷新失败由页面顶部横幅提示，播放不中断。 */
    } finally {
      loadingLatest = false;
      if (mounted) setState(() {});
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
    widget.budget?.removeListener(onBudgetChanged);
    remember();
    unawaited(progress.flush());
    reporter.dispose();
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
      child: blocked
          ? const Center(
              child: Text(
                '看了二十分钟啦\n休息一下吧',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 26),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                NotificationListener<ScrollNotification>(
            onNotification: onEdgeScroll,
            child: PageView.builder(
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
                      onLongPressStart: (_) => startSpeedBoost(),
                      onLongPressEnd: (_) => stopSpeedBoost(),
                      onLongPressCancel: stopSpeedBoost,
                      onHorizontalDragStart: startSeekPreview,
                      onHorizontalDragUpdate: updateSeekPreview,
                      onHorizontalDragEnd: endSeekPreview,
                      onHorizontalDragCancel: cancelSeekPreview,
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
                    if (speeding && i == index)
                      const IgnorePointer(child: Center(child: SpeedBadge())),
                    if (loadingLatest)
                      const IgnorePointer(
                        child: Center(child: LoadingLatestBadge()),
                      ),
                    if (seekPreview != null && i == index)
                      IgnorePointer(
                        child: Center(
                          child: SeekPreviewBadge(
                            target: seekPreview!,
                            total: seekTotal,
                            forward: seekForward,
                          ),
                        ),
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
                if (widget.budget?.limited == true &&
                    widget.budget?.exhausted != true)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 62),
                          child: RemainingBadge(
                            minutes: widget.budget!.remainingMinutes,
                            urgent: widget.budget!.remainingMs <= 5 * 60000,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    ),
  );
}

String _mmss(Duration d) {
  final m = d.inMinutes, s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 顶部居中的剩余时长提示：临期 5 分钟内变为醒目的红底样式。
class RemainingBadge extends StatelessWidget {
  final int minutes;
  final bool urgent;
  const RemainingBadge({super.key, required this.minutes, required this.urgent});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
    decoration: BoxDecoration(
      color: urgent ? accent : Colors.black54,
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.schedule_rounded, color: Colors.white, size: 15),
        const SizedBox(width: 5),
        Text(
          minutes >= 1 ? '还能看 $minutes 分钟' : '快到时间啦',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// 长按屏幕时居中显示的 2 倍速提示。
class SpeedBadge extends StatelessWidget {
  const SpeedBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(30),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.fast_forward_rounded, color: Colors.white, size: 22),
        SizedBox(width: 6),
        Text(
          '2倍速播放中',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// 边缘拖动触发加载时的居中提示。
class LoadingLatestBadge extends StatelessWidget {
  const LoadingLatestBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(30),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Text(
          '正在加载最新内容…',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// 水平拖动快进时的目标时间预览。
class SeekPreviewBadge extends StatelessWidget {
  final double target;
  final Duration total;
  final bool forward;
  const SeekPreviewBadge({
    super.key,
    required this.target,
    required this.total,
    required this.forward,
  });
  @override
  Widget build(BuildContext context) {
    final totalMs = total.inMilliseconds.toDouble();
    final fraction = totalMs > 0 ? (target / totalMs).clamp(0.0, 1.0) : 0.0;
    return Container(
      width: 190,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                forward
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 6),
              Text(
                '${_mmss(Duration(milliseconds: target.round()))} / ${_mmss(total)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 4,
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 4,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
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
