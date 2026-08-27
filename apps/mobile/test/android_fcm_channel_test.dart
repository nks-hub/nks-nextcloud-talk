import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/android_fcm_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidFcmChannel.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a failed token fetch can be retried in the same process', () async {
    var calls = 0;
    final tokens = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          if (calls == 1) {
            throw PlatformException(code: 'fcm_token_unavailable');
          }
          return 'token-after-retry';
        });
    final bridge = AndroidFcmChannel(channel: channel, onToken: tokens.add);
    addTearDown(bridge.dispose);

    await expectLater(bridge.start(), throwsA(isA<PlatformException>()));
    await bridge.start();

    expect(calls, 2);
    expect(tokens, ['token-after-retry']);
  });

  test('concurrent starts share one native token request', () async {
    final token = Completer<String>();
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls++;
          return token.future;
        });
    final tokens = <String>[];
    final bridge = AndroidFcmChannel(channel: channel, onToken: tokens.add);
    addTearDown(bridge.dispose);

    final first = bridge.start();
    final second = bridge.start();
    expect(calls, 1);
    token.complete('single-flight-token');
    await Future.wait([first, second]);

    expect(calls, 1);
    expect(tokens, ['single-flight-token']);
  });

  test('dispose suppresses a token that arrives after teardown', () async {
    final token = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => token.future);
    final tokens = <String>[];
    final bridge = AndroidFcmChannel(channel: channel, onToken: tokens.add);

    final start = bridge.start();
    bridge.dispose();
    token.complete('too-late');
    await start;

    expect(tokens, isEmpty);
  });
}
