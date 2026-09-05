import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_kit_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(CallKitChannel.channelName);
  late List<MethodCall> calls;
  late List<String> tokens;
  late CallKitChannel bridge;

  setUp(() {
    calls = <MethodCall>[];
    tokens = <String>[];
    bridge = CallKitChannel(channel: channel, onVoipToken: tokens.add);
  });

  tearDown(() {
    bridge.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void answerWith(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  Future<void> fromNative(String method, Object? arguments) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          CallKitChannel.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
  }

  test('the token that arrived before Dart existed is collected', () async {
    answerWith((call) => call.method == 'getVoipToken' ? 'ab12' : null);

    await bridge.checkLaunchVoipToken();

    expect(calls.single.method, 'getVoipToken');
    expect(tokens, ['ab12']);
  });

  test('a platform without CallKit is not a failure', () async {
    // Every non-iOS target answers this way, and so does an iOS build whose
    // PushKit registration the system refused.
    answerWith((call) => throw MissingPluginException('no CallKit'));

    await bridge.checkLaunchVoipToken();
    await bridge.endCall('11111111-1111-1111-1111-111111111111');

    expect(tokens, isEmpty);
  });

  test('a later token replaces the launch one', () async {
    await fromNative('voipTokenChanged', <String, Object?>{'token': 'cd34'});

    expect(tokens, ['cd34']);
  });

  test('answering rings through with the room it names', () async {
    final answered = <CallKitRing>[];
    bridge.answered.listen(answered.add);

    await fromNative('callAnswered', <String, Object?>{
      'accountId': 'acc-1',
      'roomToken': 'room-1',
      'callId': '11111111-1111-1111-1111-111111111111',
    });
    await Future<void>.delayed(Duration.zero);

    expect(answered.single.accountId, 'acc-1');
    expect(answered.single.roomToken, 'room-1');
    expect(answered.single.callId, '11111111-1111-1111-1111-111111111111');
  });

  test('a ring with nothing to join is dropped, not joined blindly', () async {
    final answered = <CallKitRing>[];
    final ended = <CallKitRing?>[];
    bridge.answered.listen(answered.add);
    bridge.ended.listen(ended.add);

    // What a push that decrypted to nothing produces: it still rings, so the
    // app keeps its PushKit registration, but there is no room behind it.
    await fromNative('callAnswered', <String, Object?>{'callId': ''});
    await fromNative('callEnded', <String, Object?>{});
    await Future<void>.delayed(Duration.zero);

    expect(answered, isEmpty);
    expect(ended, [null]);
  });

  test('ending names the call the system screen belongs to', () async {
    answerWith((call) => null);

    await bridge.endCall('22222222-2222-2222-2222-222222222222');

    expect(calls.single.method, 'endCall');
    expect(calls.single.arguments, <String, Object?>{
      'callId': '22222222-2222-2222-2222-222222222222',
    });
  });
}
