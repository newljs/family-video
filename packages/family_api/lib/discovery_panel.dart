import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'discovery.dart';

class LanDiscoveryPanel extends StatefulWidget {
  const LanDiscoveryPanel({
    super.key,
    required this.onSelect,
    this.discovery,
    this.autoStart = true,
    this.busy = false,
  });
  final ValueChanged<String> onSelect;
  final LanDiscovery? discovery;
  final bool autoStart, busy;
  @override
  State<LanDiscoveryPanel> createState() => _LanDiscoveryPanelState();
}

class _LanDiscoveryPanelState extends State<LanDiscoveryPanel>
    with WidgetsBindingObserver {
  final servers = <DiscoveredServer>[];
  StreamSubscription<DiscoveredServer>? subscription;
  bool scanning = false, searched = false;
  String? error;
  int generation = 0;
  bool get automatic =>
      widget.autoStart && (widget.discovery != null || Platform.isAndroid);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (automatic)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) search();
      });
  }

  void search() {
    if (!mounted || widget.busy) return;
    final current = ++generation;
    unawaited(subscription?.cancel());
    setState(() {
      servers.clear();
      error = null;
      scanning = true;
      searched = true;
    });
    subscription = (widget.discovery ?? const LanDiscovery()).scan().listen(
      (server) {
        if (!mounted ||
            generation != current ||
            servers.any((s) => s.id == server.id))
          return;
        setState(() {
          servers.add(server);
          servers.sort((a, b) => a.name.compareTo(b.name));
        });
      },
      onError: (Object _) {
        if (mounted && generation == current)
          setState(() => error = '暂时无法搜索，可检查 Wi-Fi 后重试或扫码连接');
      },
      onDone: () {
        if (mounted && generation == current) setState(() => scanning = false);
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      generation++;
      unawaited(subscription?.cancel());
      if (mounted) setState(() => scanning = false);
    } else if (automatic && !widget.busy) {
      search();
    }
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Icon(Icons.radar, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '搜索家庭服务器',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: scanning || widget.busy ? null : search,
            child: Text(
              scanning
                  ? '搜索中…'
                  : searched
                  ? '重新搜索'
                  : '开始搜索',
            ),
          ),
        ],
      ),
      Text(
        widget.busy
            ? '正在连接家庭电脑…'
            : error ??
                (scanning
                    ? '正在搜索同一 Wi-Fi 中的家庭电脑…'
                    : servers.isNotEmpty
                    ? '请选择要连接的家庭电脑'
                    : searched
                    ? '未发现服务器。请确认同一 Wi-Fi、电脑服务已更新，并允许局域网访问。'
                    : '连接家庭 Wi-Fi 后搜索，无需填写 IP 地址。'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      for (final server in servers)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.computer),
          title: Text(
            server.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(server.url, maxLines: 2),
          trailing: TextButton(
            onPressed:
                widget.busy
                    ? null
                    : () {
                      generation++;
                      unawaited(subscription?.cancel());
                      setState(() => scanning = false);
                      widget.onSelect(server.url);
                    },
            child: const Text('连接'),
          ),
        ),
    ],
  );
}
