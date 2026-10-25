import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PlaybackCacheInfo {
  final int bytes, limitBytes;
  const PlaybackCacheInfo(this.bytes, this.limitBytes);
  factory PlaybackCacheInfo.fromMap(Map<String, dynamic> map) =>
      PlaybackCacheInfo(
        (map['bytes'] as num?)?.toInt() ?? 0,
        (map['limitBytes'] as num?)?.toInt() ?? 2 * 1024 * 1024 * 1024,
      );
}

class PlaybackDiskCache {
  static const channel = MethodChannel('family_video/playback_cache');
  static Future<PlaybackCacheInfo> stats() async => PlaybackCacheInfo.fromMap(
    await channel.invokeMapMethod<String, dynamic>('stats') ?? {},
  );
  static Future<PlaybackCacheInfo> clear() async => PlaybackCacheInfo.fromMap(
    await channel.invokeMapMethod<String, dynamic>('clear') ?? {},
  );
}

class PlaybackCachePanel extends StatefulWidget {
  const PlaybackCachePanel({super.key});
  @override
  State<PlaybackCachePanel> createState() => _PlaybackCachePanelState();
}

class _PlaybackCachePanelState extends State<PlaybackCachePanel> {
  PlaybackCacheInfo? info;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final result = await PlaybackDiskCache.stats();
      if (mounted) setState(() => info = result);
    } catch (_) {
      /* Unsupported platforms still use the regular player. */
    }
  }

  String size(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理播放缓存？'),
        content: const Text('再次观看时会重新获取视频片段。你手动保存的离线视频会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理播放缓存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      final result = await PlaybackDiskCache.clear();
      if (mounted) setState(() => info = result);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法清理，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.storage_outlined),
    title: const Text('播放缓存'),
    subtitle: Text(
      info == null
          ? '边看边保存视频片段，供再次观看使用'
          : '${size(info!.bytes)} / ${size(info!.limitBytes)} · 空间满后自动清理较少使用的内容',
    ),
    trailing: TextButton(
      onPressed: info == null || busy ? null : clear,
      child: Text(busy ? '清理中' : '清理'),
    ),
  );
}
