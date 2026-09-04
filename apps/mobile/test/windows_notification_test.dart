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

  const channel = MethodChannel(WindowsNotificationChannel.channelName);

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    shown = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'show') {
            shown.add(call.arguments as Map<Object?, Object?>);
          }
          return true;
        });
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'tester',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await database.close();
  });

  Future<void> store({
    required String token,
    required int unread,
    String? lastMessage = 'hello',
    int? lastMessageId,
  }) async {
    await database
        .into(database.cachedConversations)
        .insertOnConflictUpdate(
          CachedConversationsCompanion.insert(
            accountId: 'account-a',
            token: token,
            displayName: 'Room $token',
            description: '',
            lastActivity: 20,
            unreadMessages: unread,
            favorite: false,
            lastMessageText: Value(lastMessage),
            lastMessageTimestamp: const Value(20),
            rawJson: lastMessageId == null
                ? '{}'
                : '{"lastMessage":{"id":$lastMessageId}}',
          ),
        );
  }

  WindowsNotificationService build() {
    final service = WindowsNotificationService(
      accounts: accounts,
      // Named explicitly: the default resolves to the shared apple_push
      // channel on a macOS host, and the mock below listens on the Windows
      // one, so the test would watch a channel nothing ever posts to.
      channel: WindowsNotificationChannel(channel: channel),
    );
    addTearDown(() async => service.dispose());
    service.follow('account-a');
    return service;
  }

  // Waits for the conversation stream to go quiet instead of sleeping a fixed
  // 30 ms. Drift delivers on wall-clock time, so a loaded runner can still be
  // mid-query when the old budget ran out - `shown` was empty on a macOS CI
  // machine and full on every developer machine.
  Future<void> settle() async {
    var stable = 0;
    var last = shown.length;
    for (var round = 0; round < 400 && stable < 6; round++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (shown.length == last) {
        stable++;
      } else {
        last = shown.length;
        stable = 0;
      }
    }
  }

  test('the first read is silent, a later rise is not', () async {
    await store(token: 'roomtoken1', unread: 3);
    build();
    await settle();

    // Announcing what was already unread at startup would be a burst of
    // notifications for messages the user has had all along.
    expect(shown, isEmpty);

    await store(
      token: 'roomtoken1',
      unread: 4,
      lastMessage: 'a new one',
      lastMessageId: 4711,
    );
    await settle();

    expect(shown, hasLength(1));
    expect(shown.single['body'], 'a new one');
    expect(shown.single['messageId'], 4711);
    expect(shown.single['title'], 'Room roomtoken1');
    expect(shown.single['accountId'], 'account-a');
    expect(shown.single['roomToken'], 'roomtoken1');
    expect(shown.single, isNot(contains('url')));
  });

  test('an unchanged or falling count says nothing', () async {
    await store(token: 'roomtoken1', unread: 2);
    build();
    await settle();

    await store(token: 'roomtoken1', unread: 2);
    await settle();
    await store(token: 'roomtoken1', unread: 0);
    await settle();

    expect(shown, isEmpty);
  });

  test('a rise without any text to show is skipped', () async {
    await store(token: 'roomtoken1', unread: 1);
    build();
    await settle();

    await store(token: 'roomtoken1', unread: 2, lastMessage: null);
    await settle();

    expect(shown, isEmpty);
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
