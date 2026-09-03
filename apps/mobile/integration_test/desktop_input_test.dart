import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../test/test_support.dart';

/// The desktop input the widget suite can only assert about a headless tree.
/// Here the same keyboard and pointer go through a REAL engine on a real
/// window, which is the whole reason this is an integration test: the other
/// way to drive a Mac is synthetic keys through System Events, and that needs
/// an Accessibility grant nobody can give from a shell.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const room = 'roomone';
  const messageId = 10;

  const message = CachedChatMessage(
    accountId: 'account-a',
    roomToken: room,
    messageId: messageId,
    actorType: 'users',
    actorId: 'someone-else',
    actorDisplayName: 'Other person',
    timestamp: 1724300000,
    systemMessage: '',
    messageType: 'comment',
    referenceId: 'reference-10',
    displayText: 'Cached hello',
    deleted: false,
    rawJson: '{}',
  );

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openTestDatabase();
    addTearDown(database.close);
    final account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://account-a.example.invalid',
      loginName: 'user-account-a',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'unified-search'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    const conversation = CachedConversation(
      accountId: 'account-a',
      token: room,
      displayName: 'Synthetic room',
      description: '',
      lastActivity: 1,
      unreadMessages: 0,
      favorite: false,
      isArchived: false,
      readOnly: 0,
      roomType: 2,
      roomName: '',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      lastMessageText: 'Preview',
      lastMessageTimestamp: 1,
      rawJson: '{}',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          clientPushEnabledProvider.overrideWithValue(false),
          credentialVaultProvider.overrideWithValue(MemoryCredentialVault()),
          accountsProvider.overrideWith((ref) => Stream.value([account])),
          selectedAccountProvider.overrideWith((ref) => Stream.value(account)),
          conversationsProvider.overrideWith(
            (ref, accountId) => Stream.value(const [conversation]),
          ),
          chatMessagesProvider.overrideWith(
            (ref, key) => Stream.value(const [message]),
          ),
          outgoingMessageStatusesProvider.overrideWith(
            (ref, key) => Stream.value(const <OutgoingMessageStatus>[]),
          ),
          textSendOperationsProvider.overrideWith(
            (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
          ),
          chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
          connectivityWakeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => RichChatCapabilityProfile.fromTalkFeatures(
              talkFeatures: const [
                'chat-v2',
                'chat-reference-id',
                'chat-replies',
              ],
              talkLocalFeatures: const <String>[],
              federated: false,
              moderator: false,
              participantPermissions: 0,
              translationAvailable: false,
            ),
          ),
          chatAttachmentDependenciesProvider.overrideWith(
            (ref, key) => Future<ChatAttachmentDependencies>.error(
              StateError('attachment transport is outside this test'),
              StackTrace.empty,
            ),
          ),
        ],
        child: localizedTestApp(home: const ConversationShell()),
      ),
    );
    await tester.pumpAndSettle();

    // Opened with a MOUSE click, not a touch tap: FocusManager flips its
    // highlight mode on the pointer it last saw, and a touch tap would leave
    // the tree in touch mode where hover highlights never show at all.
    await tester.tap(
      find.byKey(const Key('conversation-tile-$room')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  Color? ring(WidgetTester tester) {
    final finder = find.byKey(const Key('chat-message-ring-$messageId'));
    if (finder.evaluate().isEmpty) {
      return null;
    }
    final decoration =
        tester.widget<DecoratedBox>(finder).decoration as BoxDecoration;
    return decoration.border?.top.color;
  }

  bool focusedIn(String key) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) {
      return false;
    }
    var found = false;
    context.visitAncestorElements((element) {
      final widgetKey = element.widget.key;
      if (widgetKey is ValueKey<String> && widgetKey.value == key) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  testWidgets('Tab crosses the panes in reading order on a real window', (
    tester,
  ) async {
    await pumpShell(tester);

    const landmarks = <String>[
      'conversation-tile-$room',
      'chat-message-affordance-$messageId',
      'chat-composer',
    ];
    final reached = <String>[];
    for (var press = 0; press < 40; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      for (final landmark in landmarks) {
        if (!reached.contains(landmark) && focusedIn(landmark)) {
          reached.add(landmark);
          break;
        }
      }
      if (reached.length == landmarks.length) {
        break;
      }
    }

    expect(reached, landmarks);
  });

  testWidgets('a real pointer over a message shows and clears the ring', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(ring(tester), Colors.transparent);

    // A pointer id of its own: the click that opened the room already used
    // the default one, and re-adding it trips MouseTracker.
    final mouse = await tester.createGesture(
      pointer: 77,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('chat-message-target-$messageId'))),
    );
    await tester.pumpAndSettle();
    expect(ring(tester), isNot(Colors.transparent));

    await mouse.moveTo(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(ring(tester), Colors.transparent);
  });

  testWidgets(
    'Enter on a focused message opens the same sheet as a right click',
    (tester) async {
      await pumpShell(tester);

      var reached = false;
      for (var press = 0; press < 40 && !reached; press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        reached = focusedIn('chat-message-affordance-$messageId');
      }
      expect(reached, isTrue, reason: 'Tab must reach the message');
      expect(ring(tester), isNot(Colors.transparent));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-action-reply')), findsOneWidget);
    },
  );
}
