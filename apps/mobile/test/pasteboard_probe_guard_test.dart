import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/pasteboard_probe_guard.dart';

final class _RecordingMessenger implements BinaryMessenger {
  final sent = <MethodCall>[];

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    sent.add(const JSONMethodCodec().decodeMethodCall(message));
    return Future.value(
      const JSONMethodCodec().encodeSuccessEnvelope('from engine'),
    );
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the paste probe is answered without reaching the engine', () async {
    final engine = _RecordingMessenger();
    final channel = MethodChannel(
      SystemChannels.platform.name,
      const JSONMethodCodec(),
      PasteboardProbeGuard(engine),
    );

    final result = await channel.invokeMethod<Map<Object?, Object?>>(
      'Clipboard.hasStrings',
      Clipboard.kTextPlain,
    );
    final text = await channel.invokeMethod<String>(
      'Clipboard.getData',
      Clipboard.kTextPlain,
    );

    expect(result, {'value': true});
    expect(text, 'from engine');
    expect(engine.sent.map((call) => call.method), ['Clipboard.getData']);
  });
}
