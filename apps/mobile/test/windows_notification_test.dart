import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:nextcloudtalk/features/push/windows_notification.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late AccountRepository accounts;
  late List<Map<Object?, Object?>> shown;
  late Map<String, List<Map<String, Object?>>> responses;
  const channel = MethodChannel(WindowsNotificationChannel.channelName);

  Map<String, Object?> notification(
    int id, {
    bool shouldNotify = true,
    String app = 'spreed',
  }) => {
    'notification_id': id,
    'app': app,
    'object_type': 'chat',
    'object_id': 'roomtoken1/4711',
    'subject': 'Room title',
    'message': 'New message',
    'shouldNotify': shouldNotify,
  };

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    shown = [];
    responses = {'account-a': [], 'account-b': []};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'show') {
            shown.add(call.arguments as Map<Object?, Object?>);
          }
          return true;
        });
    for (final id in responses.keys) {
      await accounts.upsertAccount(
        accountId: id,
        serverUrl: 'https://cloud.example.invalid',
        loginName: id,
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
    }
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await database.close();
  });

  Future<WindowsNotificationService> build({
    Future<List<Map<String, Object?>>?> Function(String, Future<void>)? fetch,
  }) async {
    final service = WindowsNotificationService(
      accounts: accounts,
      channel: WindowsNotificationChannel(channel: channel),
      fetchNotifications: fetch ?? (id, _) async => responses[id],
    );
    addTearDown(service.dispose);
    await service.follow('account-a');
    return service;
  }

  test('startup is silent and server notifications are shown once', () async {
    responses['account-a'] = [notification(7)];
    final service = await build();
    expect(shown, isEmpty);
    responses['account-a'] = [notification(8), notification(7)];
    await service.refresh('account-a');
    await service.refresh('account-a');
    expect(shown, hasLength(1));
    expect(shown.single, containsPair('messageId', 4711));
    expect(shown.single, containsPair('body', 'New message'));
    expect(shown.single, containsPair('accountId', 'account-a'));
    expect(shown.single, containsPair('roomToken', 'roomtoken1'));
  });

  test(
    'unread messages without an eligible server notification stay silent',
    () async {
      final service = await build();
      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: 'account-a',
              token: 'roomtoken1',
              displayName: 'Muted',
              description: '',
              lastActivity: 20,
              unreadMessages: 5,
              favorite: false,
              lastMessageText: const Value('Do not announce'),
              rawJson: '{"notificationLevel":3}',
            ),
          );
      await service.refresh('account-a');
      responses['account-a'] = [
        notification(1, shouldNotify: false),
        notification(2, app: 'other'),
      ];
      await service.refresh('account-a');
      expect(shown, isEmpty);
      responses['account-a'] = [notification(1), notification(3)];
      await service.refresh('account-a');
      expect(
        shown,
        hasLength(1),
        reason: 'Suppressed messages must not replay later',
      );
    },
  );

  test('notification IDs and baselines are isolated per account', () async {
    final service = await build();
    await service.follow('account-b');
    responses['account-a'] = [notification(10)];
    responses['account-b'] = [notification(10)];
    await service.refresh('account-a');
    await service.refresh('account-b');
    expect(shown.map((n) => n['accountId']), ['account-a', 'account-b']);
  });

  test('late responses from an unfollowed account cannot notify', () async {
    Completer<List<Map<String, Object?>>?>? pending;
    final service = await build(
      fetch: (_, _) => pending?.future ?? Future.value([]),
    );
    pending = Completer();
    final refresh = service.refresh('account-a');
    await service.unfollow('account-a');
    pending.complete([notification(10)]);
    await refresh;
    expect(shown, isEmpty);
  });

  test('a failed fetch neither notifies nor advances the baseline', () async {
    var fail = false;
    final service = await build(
      fetch: (id, _) async {
        if (fail) throw StateError('offline');
        return responses[id];
      },
    );
    responses['account-a'] = [notification(10)];
    fail = true;
    await service.refresh('account-a');
    expect(shown, isEmpty);
    fail = false;
    await service.refresh('account-a');
    expect(shown, hasLength(1));
  });

  test('native open preserves the exact account and room route', () async {
    final notificationChannel = WindowsNotificationChannel(channel: channel);
    addTearDown(notificationChannel.dispose);
    final opened = notificationChannel.notificationOpened.first;

    final response = await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          WindowsNotificationChannel.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('notificationOpened', <String, Object>{
              'accountId': 'account-b',
              'roomToken': 'shared-host-room',
            }),
          ),
          (_) {},
        );

    expect(const StandardMethodCodec().decodeEnvelope(response!), isTrue);
    await opened;
    final open = notificationChannel.takeNextNotificationOpen();
    expect(open?.accountId, 'account-b');
    expect(open?.roomToken, 'shared-host-room');
  });

  test('native actions remain account scoped', () async {
    final actions = <Map<String, Object?>>[];
    final notificationChannel = WindowsNotificationChannel(
      channel: channel,
      onNotificationAction:
          ({
            required kind,
            required accountId,
            required roomToken,
            replyText,
            messageId,
          }) async {
            actions.add(<String, Object?>{
              'kind': kind,
              'accountId': accountId,
              'roomToken': roomToken,
              'replyText': replyText,
              'messageId': messageId,
            });
          },
    );
    addTearDown(notificationChannel.dispose);

    final response = await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          WindowsNotificationChannel.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('notificationAction', <String, Object>{
              'kind': 'reply',
              'accountId': 'account-b',
              'roomToken': 'shared-host-room',
              'replyText': 'Reply text',
              'messageId': 4711,
            }),
          ),
          (_) {},
        );

    expect(const StandardMethodCodec().decodeEnvelope(response!), isTrue);
    // The quoted message rides along so the reply answers it, not the room.
    expect(actions, <Map<String, Object?>>[
      <String, Object?>{
        'kind': 'reply',
        'accountId': 'account-b',
        'roomToken': 'shared-host-room',
        'replyText': 'Reply text',
        'messageId': 4711,
      },
    ]);
  });
}
