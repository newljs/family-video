import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native shares stay in Android preferences until the Dart inbox is saved.
class ShareReceiver {
  ShareReceiver(this.onShare, {MethodChannel? channel})
    : channel = channel ?? const MethodChannel('family_video/shares'),
      enabled = channel != null || (!kIsWeb && Platform.isAndroid);
  final bool enabled;
  final Future<void> Function(String id, String text) onShare;
  final MethodChannel channel;
  Future<void> _draining = Future.value();
  bool _closed = false;

  Future<void> start() async {
    if (!enabled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'sharesAvailable') await drain();
    });
    await drain();
  }

  Future<void> drain() {
    _draining = _draining.catchError((Object _) {}).then((_) async {
      if (_closed || !enabled) return;
      try {
        final pending =
            await channel.invokeListMethod<dynamic>('pendingShares') ?? [];
        for (final raw in pending) {
          if (_closed) return;
          final item = Map<dynamic, dynamic>.from(raw as Map);
          final id = '${item['id']}';
          final text = '${item['text']}'.trim();
          if (text.isNotEmpty) await onShare(id, text);
          await channel.invokeMethod<void>('ackShare', id);
        }
      } on MissingPluginException {
        // Non-Android platforms keep the existing paste workflow.
      }
    });
    return _draining;
  }

  void dispose() {
    _closed = true;
    channel.setMethodCallHandler(null);
  }
}
