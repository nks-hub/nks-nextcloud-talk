import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/android_web_push_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidWebPushBridge.channelName);
  late AndroidWebPushBridge bridge;
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    bridge = AndroidWebPushBridge(channel: channel);
  });

  tearDown(() async {
    await bridge.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('register forwards runtime VAPID and returns request status', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object>{'generation': 7, 'status': 'created'};
        });

    final result = await bridge.register(
      accountId: 'account-a',
      generation: 7,
      vapidPublicKey: 'B${'a' * 86}',
    );

    expect(result.generation, 7);
    expect(result.status, AndroidWebPushRegistrationStatus.created);
    expect(calls.single.method, 'register');
    expect(calls.single.arguments, <String, Object>{
      'accountId': 'account-a',
      'generation': 7,
      'vapidPublicKey': 'B${'a' * 86}',
    });
  });

  test('reads account-scoped native registration state', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object?>{
            'generation': 4,
            'nextGeneration': 5,
            'phase': 'ACTIVE',
            'pendingEventCount': 2,
          };
        });

    final state = await bridge.getRegistrationState(accountId: 'account-a');

    expect(state.generation, 4);
    expect(state.nextGeneration, 5);
    expect(state.phase, AndroidWebPushRegistrationPhase.active);
    expect(state.pendingEventCount, 2);
    expect(calls.single.method, 'getRegistrationState');
    expect(calls.single.arguments, <String, Object>{'accountId': 'account-a'});
  });

  test('requests notification permission through the activity', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object>{
            'status': call.method == 'getNotificationPermission'
                ? 'notDetermined'
                : 'granted',
          };
        });

    expect(
      await bridge.getNotificationPermission(),
      AndroidNotificationPermission.notDetermined,
    );
    expect(
      await bridge.requestNotificationPermission(),
      AndroidNotificationPermission.granted,
    );
    expect(calls.map((call) => call.method), <String>[
      'getNotificationPermission',
      'requestNotificationPermission',
    ]);
  });

  test('drain keeps account scope and decodes an encrypted wake-up', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <Object?>[
            <String, Object?>{
              'id': 'event-1',
              'accountId': 'account-b',
              'generation': 3,
              'type': 'activation',
              'createdAtMillis': 1735689600000,
              'coalescedCount': 2,
              'stale': false,
              'content': base64Encode(<int>[1, 2, 3]),
              'decrypted': true,
              'payloadOversized': false,
              'originalSize': 3,
            },
          ];
        });

    final events = await bridge.drainEvents(accountId: 'account-b', limit: 10);

    expect(calls.single.method, 'drainEvents');
    expect(calls.single.arguments, <String, Object>{
      'accountId': 'account-b',
      'limit': 10,
    });
    expect(events.single.type, AndroidWebPushEventType.activation);
    expect(events.single.content, <int>[1, 2, 3]);
    expect(events.single.coalescedCount, 2);
    expect(events.single.decrypted, isTrue);
  });

  test('endpoint must be committed separately from acknowledgement', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'commitEndpoint') {
            return <String, Object>{
              'serverRevokeGenerations': <int>[4],
            };
          }
          return <String, Object>{'removedCount': 1};
        });

    final committed = await bridge.commitEndpoint(
      accountId: 'account-c',
      generation: 5,
      eventId: 'endpoint-event',
    );
    final acknowledged = await bridge.acknowledge(
      accountId: 'account-c',
      eventIds: const <String>['endpoint-event'],
    );

    expect(committed.serverRevokeGenerations, <int>[4]);
    expect(acknowledged, 1);
    expect(calls.map((call) => call.method), <String>[
      'commitEndpoint',
      'acknowledge',
    ]);
  });

  test('prepares account-scoped server revocation durably', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object>{
            'generations': <int>[7, 3],
          };
        });

    final generations = await bridge.prepareServerRevocation(
      accountId: 'account-c',
    );

    expect(generations, <int>[3, 7]);
    expect(calls.single.method, 'prepareServerRevocation');
    expect(calls.single.arguments, <String, Object>{'accountId': 'account-c'});
  });

  test('native eventsAvailable callback is exposed as a stream', () async {
    final nextCount = bridge.eventsAvailable.first;
    final completer = Completer<void>();
    final encodedCall = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('eventsAvailable', <String, Object>{'count': 4}),
    );

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          AndroidWebPushBridge.channelName,
          encodedCall,
          (_) => completer.complete(),
        );
    await completer.future;

    expect(await nextCount, 4);
  });

  test('launch and runtime notification opens expose metadata only', () async {
    final payload = <String, Object?>{
      'accountId': 'account-a',
      'notificationId': 42,
      'app': 'spreed',
      'type': 'chat',
      'objectId': 'room-token',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return payload;
        });

    final launched = await bridge.getLaunchNotification();
    final openedFuture = bridge.notificationOpened.first;
    final completer = Completer<void>();
    final encodedCall = const StandardMethodCodec().encodeMethodCall(
      MethodCall('notificationOpened', payload),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          AndroidWebPushBridge.channelName,
          encodedCall,
          (_) => completer.complete(),
        );
    await completer.future;
    final opened = await openedFuture;

    expect(launched?.accountId, 'account-a');
    expect(launched?.objectId, 'room-token');
    expect(opened.notificationId, 42);
    expect(opened.app, 'spreed');
    expect('$opened', isNot(contains('account-a')));
    expect('$opened', isNot(contains('room-token')));
  });

  test('diagnostic strings redact endpoint, account and payload material', () {
    const endpoint = AndroidWebPushEndpoint(
      url: 'https://push.example.test/secret-endpoint',
      temporary: false,
      publicKey: 'public-secret',
      authSecret: 'auth-secret',
    );
    final event = AndroidWebPushEvent(
      id: 'secret-event-id',
      accountId: 'secret-account-id',
      generation: 1,
      type: AndroidWebPushEventType.endpoint,
      createdAt: DateTime.utc(2025),
      coalescedCount: 1,
      stale: false,
      endpoint: endpoint,
    );

    final diagnostic = '$event $endpoint';

    expect(diagnostic, isNot(contains('secret-endpoint')));
    expect(diagnostic, isNot(contains('secret-account-id')));
    expect(diagnostic, isNot(contains('public-secret')));
    expect(diagnostic, isNot(contains('auth-secret')));
    expect(diagnostic, isNot(contains('secret-event-id')));
  });

  test('malformed native payload is rejected instead of accepted', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <Object?>[
            <String, Object?>{
              'id': 'event-2',
              'accountId': 'account-d',
              'generation': 1,
              'type': 'activation',
            },
          ],
        );

    await expectLater(
      bridge.drainEvents(accountId: 'account-d'),
      throwsFormatException,
    );
  });
}
