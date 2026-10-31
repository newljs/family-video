import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:family_api/family_api.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class Downloads {
  final FamilyApi api;
  Downloads(this.api);
  final Set<String> _saving = <String>{};
  Future<void> _indexQueue = Future.value();

  Future<void> _withIndexLock(Future<void> Function() action) {
    final next = _indexQueue.catchError((Object _) {}).then((_) => action());
    _indexQueue = next;
    return next;
  }

  Future<void> _writeIndex(
    Directory directory,
    List<dynamic> entries,
  ) async {
    final file = File('${directory.path}/index.json');
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsString(jsonEncode(entries), flush: true);
    await temp.rename(file.path);
  }

  Future<Directory> get folder async {
    final root = await getApplicationSupportDirectory();
    final namespace = sha256
        .convert(utf8.encode('${api.server}|${api.token}'))
        .toString()
        .substring(0, 24);
    return Directory('${root.path}/offline/$namespace').create(recursive: true);
  }

  Future<List<dynamic>> list() async {
    final file = File('${(await folder).path}/index.json');
    if (!await file.exists()) return [];
    final entries = jsonDecode(await file.readAsString()) as List;
    final result = <dynamic>[];
    // Check files asynchronously in small batches, keeping startup IO off the UI
    // isolate even when the device has many saved videos.
    for (var offset = 0; offset < entries.length; offset += 32) {
      final batch = entries.skip(offset).take(32).toList();
      final exists = await Future.wait(
        batch.map((e) => File(e['local_path']).exists()),
      );
      for (var i = 0; i < batch.length; i++) {
        if (exists[i]) result.add(batch[i]);
      }
    }
    return result;
  }

  Future<void> save(Map<String, dynamic> video) async {
    final id = '${video['id']}';
    if (!_saving.add(id)) throw Exception('该视频正在缓存，请稍候');
    try {
      final directory = await folder;
      final target = File('${directory.path}/$id.mp4');
      if (await target.exists()) {
        if ((await list()).any((entry) => entry['id'] == id)) return;
        await target.delete();
      }
      final freeLimit = 2 * 1024 * 1024 * 1024;
      var used = 0;
      await for (final file in directory.list()) {
        if (file is File) used += await file.length();
      }
      final temp = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
      );
      final client = http.Client();
      IOSink? sink;
      var received = 0;
      var installed = false;
      try {
        final response = await client
            .send(http.Request('GET', api.uri(video['media_url'])))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          throw Exception('下载授权失效，请刷新视频库');
        }
        sink = temp.openWrite();
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          used += chunk.length;
          received += chunk.length;
          if (used > freeLimit) throw Exception('离线空间上限为 2GB，请先删除部分下载');
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (received == 0 ||
            (response.contentLength != null &&
                received != response.contentLength)) {
          throw Exception('视频下载不完整，请重试');
        }
        await temp.rename(target.path);
        installed = true;
        await _withIndexLock(() async {
          final entries = await list();
          entries.add({
            'id': id,
            'title': video['title'],
            'description': video['description'] ?? '',
            'duration': video['duration'] ?? 0,
            'local_path': target.path,
          });
          await _writeIndex(directory, entries);
        });
      } catch (_) {
        if (sink != null) await sink.close();
        if (await temp.exists()) await temp.delete();
        if (installed && await target.exists()) await target.delete();
        rethrow;
      } finally {
        client.close();
      }
    } finally {
      _saving.remove(id);
    }
  }

  Future<void> remove(Map<String, dynamic> video) async {
    final directory = await folder;
    await _withIndexLock(() async {
      final entries = await list();
      entries.removeWhere((e) => e['id'] == video['id']);
      await _writeIndex(directory, entries);
    });
    final file = File(video['local_path']);
    if (await file.exists()) await file.delete();
  }
}
