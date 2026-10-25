import 'dart:io';

import 'package:family_api/family_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    ThumbnailCache.instance.directory = null;
    ThumbnailCache.instance.fetch = null;
  });

  test('缩略图按视频 ID 缓存，签名轮换不重新下载', () async {
    final dir = await Directory.systemTemp.createTemp('thumbs');
    addTearDown(() => dir.delete(recursive: true));
    var downloads = 0;
    ThumbnailCache.instance
      ..directory = (() async => dir)
      ..fetch = (uri) async {
        downloads++;
        return http.Response('jpeg-bytes-$downloads', 200);
      };
    final first = await ThumbnailCache.instance
        .fileFor('http://server:8765/media/abc123/thumbnail?expires=9&role=child&sig=x');
    expect(first, isNotNull);
    expect(await first!.readAsString(), 'jpeg-bytes-1');
    expect(downloads, 1);
    final second =
        await ThumbnailCache.instance.fileFor('/media/abc123/thumbnail?expires=9');
    expect(second!.path, first.path);
    expect(downloads, 1);
    final refreshed = await ThumbnailCache.instance
        .fileFor('http://server:8765/media/abc123/thumbnail?expires=99&sig=new');
    expect(refreshed!.path, first.path);
    expect(downloads, 1);
  });

  test('下载失败返回 null 且不落盘，非缩略图路径不缓存', () async {
    final dir = await Directory.systemTemp.createTemp('thumbs');
    addTearDown(() => dir.delete(recursive: true));
    ThumbnailCache.instance
      ..directory = (() async => dir)
      ..fetch = (uri) async => http.Response('', 404);
    expect(
      await ThumbnailCache.instance
          .fileFor('http://server:8765/media/bad404/thumbnail?expires=9'),
      isNull,
    );
    expect(await ThumbnailCache.instance
        .fileFor('http://server:8765/media/bad404/video?expires=9'), isNull);
    expect(dir.listSync(), isEmpty);
  });
}
