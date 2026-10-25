import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 缩略图按视频 ID 落盘缓存。缩略图内容与视频 ID 绑定不变，App 重启、
/// 目录刷新或签名 URL 轮换后都不再重新下载；已删除视频的残留文件按时间清理。
class ThumbnailCache {
  ThumbnailCache._();

  static final ThumbnailCache instance = ThumbnailCache._();

  /// 测试注入：缩略图目录与网络获取。
  Future<Directory> Function()? directory;
  Future<http.Response> Function(Uri uri)? fetch;

  Future<Directory?>? _ready;

  /// 返回该缩略图的本地缓存文件；URL 不是缩略图、目录不可用或下载失败时为 null。
  Future<File?> fileFor(String url) async {
    final match = RegExp(r'^/media/([A-Za-z0-9_-]{1,80})/thumbnail$')
        .firstMatch(Uri.tryParse(url)?.path ?? '');
    final id = match?.group(1);
    if (id == null) return null;
    final dir = await _dir();
    if (dir == null) return null;
    final file = File('${dir.path}/$id.jpg');
    if (await file.exists()) {
      return file;
    }
    try {
      final response =
          await (fetch ?? http.get)(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      final part =
          File('${dir.path}/$id.${DateTime.now().microsecondsSinceEpoch}.part');
      await part.writeAsBytes(response.bodyBytes, flush: true);
      await part.rename(file.path);
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _dir() {
    return _ready ??= () async {
      try {
        final root = await (directory?.call() ?? getTemporaryDirectory());
        final dir = Directory('${root.path}/family_thumbnails');
        await dir.create(recursive: true);
        unawaited(_prune(dir));
        return dir;
      } catch (_) {
        return null;
      }
    }();
  }

  // 缓存键是视频 ID，签名轮换不产生新文件，只按时间清理不再需要的文件。
  Future<void> _prune(Directory dir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 60));
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          try {
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}

/// 优先使用磁盘缓存的缩略图。加载中或失败时显示 [errorBuilder]（与
/// Image.network 的 errorBuilder 同形），命中缓存后离线也能显示。
class CachedThumbnail extends StatefulWidget {
  const CachedThumbnail(
    this.url, {
    super.key,
    this.fit,
    this.cacheWidth,
    this.errorBuilder,
  });

  final String url;
  final BoxFit? fit;
  final int? cacheWidth;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  @override
  State<CachedThumbnail> createState() => _CachedThumbnailState();
}

class _CachedThumbnailState extends State<CachedThumbnail> {
  File? _file;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CachedThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _file = null;
      _failed = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final file = await ThumbnailCache.instance.fileFor(widget.url);
    if (!mounted) return;
    setState(() {
      _file = file;
      _failed = file == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null) {
      final errorBuilder = widget.errorBuilder;
      if (errorBuilder == null) return const SizedBox.expand();
      return errorBuilder(context, _failed ? '缩略图不可用' : '加载中', null);
    }
    return Image.file(
      file,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      errorBuilder: widget.errorBuilder == null
          ? null
          : (context, error, stackTrace) =>
              widget.errorBuilder!(context, error, stackTrace),
    );
  }
}
