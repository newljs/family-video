import 'dart:convert';
import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
export 'package:family_models/family_models.dart';

class FamilyApiException implements Exception {
  final String message;
  final int? statusCode;
  const FamilyApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

String friendlyError(Object error) {
  if (error is FamilyApiException) return error.message;
  if (error is TimeoutException) return '连接超时，请检查服务器地址，并确认电脑服务已启动。';
  if (error is http.ClientException) return '无法连接家庭电脑，请检查服务器地址和家庭网络。';
  return '$error'.replaceFirst(RegExp(r'^Exception:\s*'), '');
}

class FamilyApi {
  final http.Client? _client;
  final String clientRole;
  FamilyApi({http.Client? client, this.clientRole = 'child'})
    : _client = client;
  String server = '';
  // Retained only to find pre-0.4 offline files and favorites. Never transmitted.
  String token = '';
  static const _storage = FlutterSecureStorage();
  Map<String, String> get headers => {'X-Family-Client': clientRole};
  Uri uri(String path) => Uri.parse('$server$path');
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    server = prefs.getString('server') ?? '';
    final cachedIdentity = prefs.getString('cache_identity_$server');
    if (cachedIdentity != null) {
      token = cachedIdentity;
      return;
    }
    try {
      token = await _storage.read(key: 'token') ?? '';
    } catch (_) {
      token = '';
    }
  }

  Future<void> checkServer() async {
    final health = await request('GET', '/health');
    if (health is! Map ||
        health['access_mode'] != 'open_lan' ||
        health['content_mode'] != 'direct' ||
        health['library_mode'] != 'managed') {
      throw const FamilyApiException(
        '请先将家庭电脑服务端更新到 0.7 或更新版本，以支持视频管理、描述和流媒体播放。',
      );
    }
  }

  Future<void> save(String address) async {
    final parsed = Uri.tryParse(address.trim());
    if (parsed == null ||
        !['http', 'https'].contains(parsed.scheme) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        (parsed.path.isNotEmpty && parsed.path != '/') ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw const FamilyApiException('请输入服务器地址，例如 http://192.168.1.10:8765');
    }
    final candidate = FamilyApi(client: _client, clientRole: clientRole)
      ..server = address.trim().replaceFirst(RegExp(r'/+$'), '');
    await candidate.checkServer();
    // Verify first so an unreachable address never replaces a working connection.
    final prefs = await SharedPreferences.getInstance();
    if (server.isNotEmpty)
      await prefs.setString('cache_identity_$server', token);
    if (candidate.server != server) {
      token = prefs.getString('cache_identity_${candidate.server}') ?? '';
      try {
        await _storage.write(key: 'token', value: token);
      } catch (_) {}
    }
    await prefs.setString('server', candidate.server);
    server = candidate.server;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    if (server.isNotEmpty)
      await prefs.setString('cache_identity_$server', token);
    await prefs.remove('server');
    server = '';
    token = '';
    try {
      await _storage.delete(key: 'token');
    } catch (_) {}
  }

  dynamic decode(http.Response response) {
    dynamic result;
    try {
      result = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw FamilyApiException(
        '服务器响应不是有效数据，请确认地址指向家庭视频服务。',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      throw FamilyApiException(
        result is Map ? '${result['detail']}' : '请求失败 ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return result;
  }

  Future<dynamic> request(String method, String path, [Object? body]) async {
    final request = http.Request(method, uri(path));
    request.headers.addAll({...headers, 'Content-Type': 'application/json'});
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await (_client == null ? request.send() : _client.send(request)).timeout(
        const Duration(seconds: 15),
      ),
    ).timeout(const Duration(seconds: 30));
    return decode(response);
  }

  Future<void> upload(String path, String title) async {
    final req = http.MultipartRequest('POST', uri('/api/uploads'));
    req.headers.addAll(headers);
    req.fields['title'] = title;
    req.files.add(await http.MultipartFile.fromPath('file', path));
    decode(
      await http.Response.fromStream(
        await req.send(),
      ).timeout(const Duration(minutes: 15)),
    );
  }
}
