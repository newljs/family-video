import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'family_api.dart' show FamilyApi;

class DiscoveredServer {
  const DiscoveredServer({
    required this.id,
    required this.name,
    required this.url,
    this.version = '',
  });
  final String id, name, url, version;
}

/// A short IPv4 broadcast search. It never sweeps IP ranges or public hosts.
class LanDiscovery {
  const LanDiscovery({
    this.port = 8766,
    this.duration = const Duration(seconds: 4),
    this.localAddresses,
    this.targets,
    this.clientFactory,
    this.allowLoopback = false,
  });
  final int port;
  final Duration duration;
  final Future<List<InternetAddress>> Function()? localAddresses;
  final List<InternetAddress>? targets;
  final http.Client Function()? clientFactory;
  final bool allowLoopback;

  Stream<DiscoveredServer> scan() => _DiscoveryScan(this).stream;
}

class _DiscoveryScan {
  _DiscoveryScan(this.options) {
    controller = StreamController<DiscoveredServer>(
      onListen: () => unawaited(start()),
      onCancel: stop,
    );
  }
  final LanDiscovery options;
  late final StreamController<DiscoveredServer> controller;
  final sockets = <RawDatagramSocket>[];
  final attempts = <String, int>{};
  final probing = <String>{}, found = <String>{};
  final nonce =
      List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
  http.Client? client;
  Timer? deadline, resend;
  bool closed = false;
  Stream<DiscoveredServer> get stream => controller.stream;

  Future<void> start() async {
    deadline = Timer(options.duration, stop);
    try {
      client = options.clientFactory?.call() ?? http.Client();
      final List<InternetAddress> addresses;
      if (options.localAddresses != null) {
        addresses = await options.localAddresses!();
      } else {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        addresses =
            interfaces
                .expand((i) => i.addresses)
                .where((a) => localPeer(a))
                .toList();
      }
      if (closed) return;
      final bindings =
          addresses.isEmpty ? [InternetAddress.anyIPv4] : addresses;
      final seen = <String>{};
      for (final address in bindings) {
        if (!seen.add(address.address)) continue;
        try {
          final socket = await RawDatagramSocket.bind(
            address,
            0,
            reuseAddress: false,
            ttl: 1,
          );
          if (closed) {
            socket.close();
            return;
          }
          socket.broadcastEnabled = true;
          socket.writeEventsEnabled = false;
          sockets.add(socket);
          socket.listen(
            (event) {
              if (event != RawSocketEvent.read || closed) return;
              Datagram? packet;
              while ((packet = socket.receive()) != null) {
                receive(packet!);
              }
            },
            onError: (Object _) {
              /* Other network interfaces may still work. */
            },
          );
        } catch (_) {
          /* One unavailable interface must not break the scan. */
        }
      }
      if (closed) return;
      if (sockets.isEmpty) {
        controller.addError(StateError('暂时无法搜索，请检查 Wi-Fi 或使用扫码连接'));
        stop();
        return;
      }
      send();
      resend = Timer.periodic(const Duration(seconds: 1), (_) => send());
    } catch (_) {
      if (!closed) controller.addError(StateError('暂时无法搜索，请检查 Wi-Fi 或使用扫码连接'));
      stop();
    }
  }

  bool localPeer(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final ip = address.rawAddress;
    return (options.allowLoopback && address.isLoopback) ||
        ip[0] == 10 ||
        (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) ||
        (ip[0] == 192 && ip[1] == 168) ||
        address.isLinkLocal;
  }

  void send() {
    if (closed) return;
    final bytes = utf8.encode(
      jsonEncode({
        'service': 'family-video',
        'kind': 'discover',
        'protocol': 1,
        'nonce': nonce,
      }),
    );
    for (final socket in sockets) {
      for (final target
          in options.targets ?? [InternetAddress('255.255.255.255')]) {
        try {
          socket.send(bytes, target, options.port);
        } catch (_) {
          /* Scan ends on its deadline. */
        }
      }
    }
  }

  void receive(Datagram packet) {
    if (closed || packet.data.length > 512 || !localPeer(packet.address))
      return;
    try {
      final value = jsonDecode(utf8.decode(packet.data));
      if (value is! Map ||
          value['service'] != 'family-video' ||
          value['kind'] != 'server' ||
          value['protocol'] != 1 ||
          value['nonce'] != nonce)
        return;
      final id = value['instance_id'], port = value['http_port'];
      if (id is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          found.contains(id))
        return;
      // The UDP source determines the host. Never trust a URL from the packet.
      final url =
          Uri(
            scheme: 'http',
            host: packet.address.address,
            port: port,
          ).toString();
      if (probing.contains(url) ||
          (attempts[url] ?? 0) >= 2 ||
          (!attempts.containsKey(url) && attempts.length >= 16))
        return;
      attempts[url] = (attempts[url] ?? 0) + 1;
      probing.add(url);
      final rawName = value['name'];
      final name =
          rawName is String
              ? String.fromCharCodes(
                rawName.runes.take(64),
              ).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim()
              : '';
      final version =
          value['version'] is String ? (value['version'] as String) : '';
      unawaited(
        verify(
          DiscoveredServer(
            id: id,
            name: name.isEmpty ? '家庭电脑' : name,
            url: url,
            version: version,
          ),
        ),
      );
    } catch (_) {
      /* Ignore unrelated or malformed datagrams. */
    }
  }

  Future<void> verify(DiscoveredServer server) async {
    try {
      final api = FamilyApi(client: client)..server = server.url;
      final health = await api.requestWithTimeout(
        'GET',
        '/health',
        timeout: const Duration(milliseconds: 900),
      );
      if (closed ||
          health is! Map ||
          health['backend'] != 'go' ||
          health['access_mode'] != 'open_lan' ||
          health['content_mode'] != 'direct' ||
          health['library_mode'] != 'managed' ||
          !found.add(server.id))
        return;
      controller.add(server);
    } catch (_) {
      /* A broadcast alone is not proof that the HTTP service works. */
    } finally {
      probing.remove(server.url);
    }
  }

  void stop() {
    if (closed) return;
    closed = true;
    deadline?.cancel();
    resend?.cancel();
    for (final socket in sockets) {
      socket.close();
    }
    client?.close();
    unawaited(controller.close());
  }
}
