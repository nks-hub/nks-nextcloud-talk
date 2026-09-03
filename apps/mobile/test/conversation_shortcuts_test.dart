import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shortcuts.dart';
import 'package:nextcloudtalk/features/conversations/deep_link_coordinator.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_authenticator.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_controller.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_store.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('conversationShortcuts', () {
    test('ranks the busiest rooms across accounts and stops at the limit', () {
      final shortcuts = conversationShortcuts(
        accounts: const [_accountA, _accountB],
        conversations: {
          'account-a': [
            _room(account: 'account-a', token: 'aaaa', activity: 30),
            _room(account: 'account-a', token: 'bbbb', activity: 10),
          ],
          'account-b': [
            _room(account: 'account-b', token: 'cccc', activity: 40),
            _room(account: 'account-b', token: 'dddd', activity: 20),
          ],
        },
        limit: 3,
      );

      expect(
        shortcuts.map((shortcut) => shortcut.id),
        ['account-b|cccc', 'account-a|aaaa', 'account-b|dddd'],
      );
    });

    test('builds a link the deep link resolver accepts under a base path', () {
      final shortcuts = conversationShortcuts(
        accounts: const [_accountB],
        conversations: {
          'account-b': [_room(account: 'account-b', token: 'cccc', activity: 1)],
        },
      );

      expect(
        shortcuts.single.uri.toString(),
        'https://talk.example.invalid/nextcloud/index.php/call/cccc',
      );
    });

    test('leaves out archived rooms and unparseable servers', () {
      final shortcuts = conversationShortcuts(
        accounts: const [_accountA, _brokenAccount],
        conversations: {
          'account-a': [
            _room(account: 'account-a', token: 'aaaa', activity: 5),
            _room(
              account: 'account-a',
              token: 'bbbb',
              activity: 50,
              archived: true,
            ),
          ],
          'account-broken': [
            _room(account: 'account-broken', token: 'eeee', activity: 99),
          ],
        },
      );

      expect(shortcuts.map((shortcut) => shortcut.id), ['account-a|aaaa']);
    });

    test('falls back to the token when a room has no display name', () {
      final shortcuts = conversationShortcuts(
        accounts: const [_accountA],
        conversations: {
          'account-a': [
            _room(account: 'account-a', token: 'aaaa', activity: 1, name: '  '),
          ],
        },
      );

      expect(shortcuts.single.label, 'aaaa');
    });
  });

  test('a published shortcut link resolves back to its own room', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://talk.example.invalid/nextcloud',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );

    final shortcut = conversationShortcuts(
      accounts: [account],
      conversations: {
        account.id: [_room(account: account.id, token: 'cccc', activity: 1)],
      },
    ).single;
    final resolved = await DeepLinkResolver(accounts).resolve(shortcut.uri);

    expect(resolved, isNotNull);
    expect(resolved!.accountId, account.id);
    expect(resolved.token.value, 'cccc');
  });

  group('ConversationShortcutsHost', () {
    late List<List<Object?>> published;

    setUp(() {
      published = <List<Object?>>[];
      const channel = MethodChannel(ConversationShortcutPublisher.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments as Map<Object?, Object?>;
            published.add(arguments['shortcuts']! as List<Object?>);
            return published.last.length;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance
            .defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    });

    Widget host({required bool appLockEnabled}) {
      return ProviderScope(
        overrides: [
          appLockMobilePlatformProvider.overrideWithValue(true),
          appLockStoreProvider.overrideWithValue(
            _Store(enabled: appLockEnabled),
          ),
          appLockAuthenticatorProvider.overrideWithValue(_Authenticator()),
          accountsProvider.overrideWith(
            (ref) => Stream.value(const [_accountA]),
          ),
          conversationsProvider.overrideWith(
            (ref, accountId) => Stream.value([
              _room(account: accountId, token: 'aaaa', activity: 7),
            ]),
          ),
        ],
        child: const ConversationShortcutsHost(child: SizedBox()),
      );
    }

    testWidgets('publishes the ranked rooms once they are cached', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(host(appLockEnabled: false));
      await tester.pump();
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;

      expect(published, isNotEmpty);
      expect((published.last.single! as Map)['id'], 'account-a|aaaa');
    });

    testWidgets('keeps room names off the launcher while app lock is on', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(host(appLockEnabled: true));
      await tester.pump();
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;

      expect(published.every((shortcuts) => shortcuts.isEmpty), isTrue);
    });
  });

  group('ConversationShortcutPublisher', () {
    test('hands the whole set to the platform in one call', () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel(
        ConversationShortcutPublisher.channelName,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return 1;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance
            .defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await ConversationShortcutPublisher().publish([
        ConversationShortcut(
          id: 'account-a|aaaa',
          label: 'Room',
          uri: Uri.parse('https://cloud.example.invalid/index.php/call/aaaa'),
        ),
      ]);

      expect(calls.single.method, 'publish');
      expect(calls.single.arguments, {
        'shortcuts': [
          {
            'id': 'account-a|aaaa',
            'label': 'Room',
            'uri': 'https://cloud.example.invalid/index.php/call/aaaa',
          },
        ],
      });
    });

    test('survives a platform that has no shortcut channel', () async {
      const channel = MethodChannel(
        ConversationShortcutPublisher.channelName,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      await expectLater(
        ConversationShortcutPublisher().publish(const []),
        completes,
      );
    });
  });
}

final class _Store implements AppLockStore {
  _Store({required this.enabled});

  bool enabled;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;
}

final class _Authenticator implements AppLockAuthenticator {
  @override
  Future<bool> authenticate(String reason) async => false;

  @override
  Future<bool> isSupported() async => true;
}

const _accountA = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

const _accountB = StoredAccount(
  id: 'account-b',
  serverUrl: 'https://talk.example.invalid/nextcloud',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: false,
  createdAtMillis: 1767225600000,
);

const _brokenAccount = StoredAccount(
  id: 'account-broken',
  serverUrl: 'not a server',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: false,
  createdAtMillis: 1767225600000,
);

CachedConversation _room({
  required String account,
  required String token,
  required int activity,
  String? name,
  bool archived = false,
}) {
  return CachedConversation(
    accountId: account,
    token: token,
    displayName: name ?? 'Room $token',
    description: '',
    lastActivity: activity,
    unreadMessages: 0,
    favorite: false,
    isArchived: archived,
    readOnly: 0,
    roomType: 2,
    roomName: token,
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    rawJson: '{}',
  );
}
