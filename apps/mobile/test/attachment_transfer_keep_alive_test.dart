import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/attachment_transfer_keep_alive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the service says it waits only while nobody is sending', () async {
    const channel = MethodChannel('test/attachment_transfer_label');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(
            call.method == 'start'
                ? 'start waiting=${(call.arguments as Map)['waiting']}'
                : call.method,
          );
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
    final waiting = keepAlive.holder(waiting: true);
    final sending = keepAlive.holder();

    waiting(true);
    sending(true);
    sending(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, [
      'start waiting=true',
      'start waiting=false',
      'start waiting=true',
    ]);

    waiting(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls.last, 'stop');
  });

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
