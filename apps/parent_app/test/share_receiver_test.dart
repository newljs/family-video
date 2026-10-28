import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parent_app/share_receiver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('family_video/test_shares');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'native share is acknowledged only after inbox persistence succeeds',
    () async {
      final acknowledgements = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'pendingShares') {
              return [
                {'id': 'share1', 'text': ' https://v.douyin.com/abc/ '},
              ];
            }
            if (call.method == 'ackShare') {
              acknowledgements.add(call.arguments as String);
            }
            return null;
          });
      var diskFails = true;
      final received = <String>[];
      final receiver = ShareReceiver((id, text) async {
        if (diskFails) throw StateError('disk full');
        received.add(text);
      }, channel: channel);
      await expectLater(receiver.start(), throwsStateError);
      expect(acknowledgements, isEmpty);
      diskFails = false;
      await receiver.drain();
      expect(received, ['https://v.douyin.com/abc/']);
      expect(acknowledgements, ['share1']);
      receiver.dispose();
    },
  );
}
