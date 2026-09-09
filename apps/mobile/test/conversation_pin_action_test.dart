import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_pin_action.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shortcuts.dart';

import 'test_support.dart';

/// A launcher that answers exactly what the test is about.
///
/// The real publisher talks to the platform channel, so the fake goes in at the
/// channel and the Dart side under test is the shipped one.
final class _FakeLauncher {
  _FakeLauncher({required this.supported, this.accepts = true});

  static const _channel = MethodChannel(
    ConversationShortcutPublisher.channelName,
  );

  final bool supported;
  final bool accepts;
  final requested = <Map<Object?, Object?>>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'pinSupported':
              return supported;
            case 'requestPin':
              requested.add(
                (call.arguments as Map<Object?, Object?>)['shortcut']
                    as Map<Object?, Object?>,
              );
              return accepts;
            default:
              return null;
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }
}

Widget _host({
  required StoredAccount account,
  required CachedConversation conversation,
}) {
  return ProviderScope(
    child: localizedTestApp(
      home: Consumer(
        builder: (context, ref, _) {
          final actions = conversationPinActions(
            context,
            ref,
            account: account,
            conversation: conversation,
          );
          return Scaffold(
            body: Column(
              children: [
                for (final action in actions)
                  TextButton(
                    key: action.id,
                    onPressed: action.onPressed,
                    child: Text(action.label),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  late AppDatabase database;
  late StoredAccount account;
  late CachedConversation conversation;

  setUp(() async {
    database = openTestDatabase();
    account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: 'rooma123',
            displayName: 'Team',
            description: '',
            lastActivity: 10,
            unreadMessages: 0,
            favorite: false,
            rawJson: '{}',
          ),
        );
    conversation = await database.select(database.cachedConversations).getSingle();
  });

  tearDown(() => database.close());

  testWidgets('a launcher that refuses pins is not offered the action', (
    tester,
  ) async {
    _FakeLauncher(supported: false).install();
    await tester.pumpWidget(
      _host(account: account, conversation: conversation),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('pin-conversation-to-launcher')),
      findsNothing,
    );
  });

  testWidgets('pinning asks the launcher with the conversation link', (
    tester,
  ) async {
    final launcher = _FakeLauncher(supported: true)..install();
    await tester.pumpWidget(
      _host(account: account, conversation: conversation),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pin-conversation-to-launcher')));
    await tester.pumpAndSettle();

    expect(launcher.requested, hasLength(1));
    final shortcut = launcher.requested.single;
    expect(shortcut['id'], '${account.id}|rooma123');
    expect(shortcut['label'], 'Team');
    expect(
      shortcut['uri'],
      'https://cloud.example.invalid/index.php/call/rooma123',
      reason: 'a pin opens through the same link a recent shortcut does',
    );
    expect(find.text('The launcher was asked to pin it.'), findsOneWidget);
  });

  testWidgets('a launcher that drops the request says so', (tester) async {
    _FakeLauncher(supported: true, accepts: false).install();
    await tester.pumpWidget(
      _host(account: account, conversation: conversation),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pin-conversation-to-launcher')));
    await tester.pumpAndSettle();

    expect(
      find.text('This launcher did not take the shortcut.'),
      findsOneWidget,
    );
  });

  test('a conversation with no token has no shortcut', () {
    expect(
      conversationShortcutFor(
        account: account,
        room: conversation.copyWith(token: ''),
      ),
      isNull,
    );
  });

  test('an unparseable server address has no shortcut', () async {
    expect(
      conversationShortcutFor(
        account: account.copyWith(serverUrl: 'not a url'),
        room: conversation,
      ),
      isNull,
    );
  });

  test('a nameless conversation falls back to its token', () {
    expect(
      conversationShortcutFor(
        account: account,
        room: conversation.copyWith(displayName: '   '),
      )!.label,
      'rooma123',
    );
  });
}
