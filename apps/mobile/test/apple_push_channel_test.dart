import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/apple_push_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ApplePushCoordinator.channelName);
  late ApplePushCoordinator coordinator;
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    coordinator = ApplePushCoordinator(channel: channel);
  });

  tearDown(() {
    coordinator.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('requests permission and fetches the token once granted', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'requestPermission' => true,
            'getDeviceToken' => 'abcd1234deadbeef',
            _ => null,
          };
        });

    await coordinator.requestPermissionAndLogToken();

    expect(calls.map((call) => call.method), <String>[
      'requestPermission',
      'getDeviceToken',
    ]);
  });

  test('does not fetch a token when permission is denied', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'requestPermission' ? false : null;
        });

    await coordinator.requestPermissionAndLogToken();

    expect(calls.map((call) => call.method), <String>['requestPermission']);
  });

  test('only asks once per coordinator, even if called again', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'requestPermission' => true,
            'getDeviceToken' => 'abcd1234deadbeef',
            _ => null,
          };
        });

    await coordinator.requestPermissionAndLogToken();
    await coordinator.requestPermissionAndLogToken();

    expect(calls.length, 2);
  });

  test('accepts a native token refresh without throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    final data = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('deviceTokenChanged', 'fresh-token-1234'),
    );
    final response = await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(ApplePushCoordinator.channelName, data, (_) {});
    expect(
      const StandardMethodCodec().decodeEnvelope(response!),
      isNull,
    );
  });

  test('rejects an unknown native callback', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    final data = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('somethingElse'),
    );
    // MissingPluginException is the binding's own signal for "unhandled" and
    // is reported back to the platform side as a null reply, not an error
    // envelope — this only confirms the handler doesn't silently swallow an
    // unknown callback into a successful no-op.
    final response = await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(ApplePushCoordinator.channelName, data, (_) {});
    expect(response, isNull);
  });
}
