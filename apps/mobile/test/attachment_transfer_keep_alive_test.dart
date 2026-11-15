import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/attachment_transfer_keep_alive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the service runs until the last holder lets go', () async {
    const channel = MethodChannel('test/attachment_transfer');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final keepAlive = AttachmentTransferKeepAlive(
      channel: channel,
      linger: Duration.zero,
    );
    addTearDown(keepAlive.dispose);
    final upload = keepAlive.holder();
    final message = keepAlive.holder();

    upload(true);
    message(true);
    upload(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, ['start'], reason: 'the message is still on its way');

    message(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, ['start', 'stop']);
  });
}
