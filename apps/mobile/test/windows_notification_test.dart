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
            rawJson: '{}',
          ),
        );
  }

  WindowsNotificationService build() {
    final service = WindowsNotificationService(
      accounts: accounts,
      channel: WindowsNotificationChannel(),
    );
    addTearDown(() async => service.dispose());
    service.follow('account-a', 'https://cloud.example.invalid');
    return service;
  }

  Future<void> settle() async {
    for (var round = 0; round < 6; round++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('the first read is silent, a later rise is not', () async {
    await store(token: 'roomtoken1', unread: 3);
    build();
    await settle();

    // Announcing what was already unread at startup would be a burst of
    // notifications for messages the user has had all along.
    expect(shown, isEmpty);

    await store(token: 'roomtoken1', unread: 4, lastMessage: 'a new one');
    await settle();

    expect(shown, hasLength(1));
    expect(shown.single['body'], 'a new one');
    expect(shown.single['title'], 'Room roomtoken1');
    // The click route is the existing deep link handler, so the URL has to be
    // the shape it already parses.
    expect(
      shown.single['url'],
      'https://cloud.example.invalid/call/roomtoken1',
    );
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
}
