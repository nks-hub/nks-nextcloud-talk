import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';

import 'test_support.dart';

/// Covers the only way back to the newest message after scrolling into
/// history. Without a control the reader has to drag the same distance back,
/// which on a long history is unbounded work.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault();
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  Future<CachedConversation> seedRoom(String token, int messages) async {
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: token,
            displayName: 'Synthetic room $token',
            description: '',
            lastActivity: 1724300000,
            unreadMessages: 0,
            favorite: false,
            readOnly: const Value(0),
            roomType: const Value(2),
            roomName: Value('synthetic-$token'),
            objectType: const Value(''),
            avatarVersion: const Value(''),
            isCustomAvatar: const Value(false),
            rawJson: '{}',
          ),
        );
    await database.batch((batch) {
      for (var index = 0; index < messages; index++) {
        final wire = _wireMessage(token, 100 + index, index);
        batch.insert(
          database.cachedChatMessages,
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: token,
            messageId: wire['id']! as int,
            actorType: 'users',
            actorId: wire['actorId']! as String,
            actorDisplayName: wire['actorDisplayName']! as String,
            timestamp: wire['timestamp']! as int,
            systemMessage: '',
            messageType: 'comment',
            referenceId: wire['referenceId']! as String,
            displayText: wire['message']! as String,
            deleted: false,
            rawJson: jsonEncode(wire),
          ),
        );
      }
    });
    await database
        .into(database.chatScopes)
        .insert(
          ChatScopesCompanion.insert(
            accountId: account.id,
            roomToken: token,
            scopeKey: 'root',
            historyCursor: '100',
            futureCursor: '${100 + messages - 1}',
            lastCommonRead: '${100 + messages - 1}',
            lastReadMessage: 100 + messages - 1,
            unreadMessages: 0,
            hasHistory: false,
            futureConverged: true,
            blocksJson: '[["100","${100 + messages - 1}"]]',
          ),
        );
    return (database.select(
      database.cachedConversations,
    )..where((row) => row.token.equals(token))).getSingle();
  }

  Widget app(Widget home) => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(vault),
      connectivityWakeEventsProvider.overrideWithValue(
        const Stream<void>.empty(),
      ),
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment dependencies are not wired in this suite'),
          StackTrace.empty,
        ),
      ),
    ],
    child: localizedTestApp(home: home),
  );

  Future<void> openRoom(WidgetTester tester, CachedConversation room) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(PresenceChatRoomScreen(account: account, conversation: room)),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> closeRoom(WidgetTester tester) async {
    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  ScrollableState timelineScrollable(WidgetTester tester) =>
      tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('chat-message-list')),
          matching: find.byType(Scrollable),
        ),
      );

  const jumpButton = Key('chat-jump-to-newest');

  testWidgets('the jump control stays hidden at the newest message', (
    tester,
  ) async {
    await openRoom(tester, await seedRoom('rooma1', 200));

    expect(timelineScrollable(tester).position.pixels, 0);
    expect(find.byKey(jumpButton), findsNothing);

    await closeRoom(tester);
  });

  testWidgets(
    'scrolling into history offers a way back to the newest message',
    (tester) async {
      await openRoom(tester, await seedRoom('roomb2', 400));

      // Drag the way a reader scrolling back through history does.
      await tester.drag(
        find.byKey(const Key('chat-message-list')),
        const Offset(0, 900),
      );
      await tester.pumpAndSettle();

      final away = timelineScrollable(tester).position.pixels;
      expect(away, greaterThan(240));
      expect(find.byKey(jumpButton), findsOneWidget);

      await tester.tap(find.byKey(jumpButton));
      await tester.pumpAndSettle();

      // Back at the newest message, and the control retires with it.
      expect(timelineScrollable(tester).position.pixels, 0);
      expect(find.byKey(jumpButton), findsNothing);
      expect(tester.takeException(), isNull);

      await closeRoom(tester);
    },
  );

  testWidgets('a jump from deep history lands on the newest message', (
    tester,
  ) async {
    await openRoom(tester, await seedRoom('roomc3', 400));

    // Far enough that the animated stretch alone cannot cover the distance.
    timelineScrollable(tester).position.jumpTo(6000);
    await tester.pump();
    expect(find.byKey(jumpButton), findsOneWidget);

    await tester.tap(find.byKey(jumpButton));
    await tester.pumpAndSettle();

    expect(timelineScrollable(tester).position.pixels, 0);
    expect(tester.takeException(), isNull);

    await closeRoom(tester);
  });
}

Map<String, Object?> _wireMessage(String token, int messageId, int index) {
  return <String, Object?>{
    'id': messageId,
    'token': token,
    'actorType': 'users',
    'actorId': 'author-${index % 4}',
    'actorDisplayName': 'Author ${index % 4}',
    'timestamp': 1724300000 + (index * 60),
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$token-$messageId',
    'message': 'Synthetic history message number $index with plain body text.',
    'messageParameters': const <String, Object?>{},
    'markdown': false,
    'reactions': const <String, Object?>{},
    'reactionsSelf': const <Object?>[],
    'deleted': null,
    'threadId': null,
    'isThread': false,
    'threadTitle': null,
    'threadReplies': 0,
  };
}
