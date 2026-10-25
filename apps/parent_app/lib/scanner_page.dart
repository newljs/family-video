import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫描管理台「手机连接」面板上的服务器地址二维码。
/// 识别 http/https 链接并返回 origin 形式（scheme://host:port）；取消返回 null。
Future<String?> scanServerAddress(BuildContext context) =>
    Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool settled = false;

  String? parseAddress(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme)) {
      return null;
    }
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  void onDetect(BarcodeCapture capture) {
    if (settled) return;
    for (final barcode in capture.barcodes) {
      final address = parseAddress(barcode.rawValue);
      if (address != null) {
        settled = true;
        Navigator.pop(context, address);
        return;
      }
    }
    // 非地址二维码忽略，继续扫描。
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('扫描服务器二维码'),
    ),
    body: Stack(
      children: [
        MobileScanner(
          onDetect: onDetect,
          errorBuilder: (context, error) => const Center(
            child: Text(
              '无法启动相机，请检查相机权限，\n或回到上一页手动输入地址。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, height: 1.6),
            ),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 36,
          child: Text(
            '对准电脑管理台「手机连接」面板上的二维码',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
