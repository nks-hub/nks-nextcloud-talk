import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';

import 'test_support.dart';

/// Guards the memory a closed chat room is allowed to leave behind.
///
/// The timeline is virtualized, so an open room only ever lays out the bubbles
/// in the viewport. What matters for memory is what survives closing it: the
/// room providers hold a live drift subscription and the last emitted message
/// list, and a family provider without `autoDispose` keeps both for the whole
/// process. Visiting rooms then costs memory that is never returned.
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
        final messageId = 100 + index;
        final wire = <String, Object?>{
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
          'message': 'Synthetic history message number $index',
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
        batch.insert(
          database.cachedChatMessages,
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: token,
            messageId: messageId,
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
    return (database.select(database.cachedConversations)
          ..where((row) => row.token.equals(token)))
        .getSingle();
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

  ChatRoomProviderKey keyFor(CachedConversation conversation) => (
    accountId: account.id,
    roomToken: conversation.token,
    threadId: null,
  );

  bool aliveIn(ProviderContainer container, ProviderBase<Object?> provider) =>
      container
          .getAllProviderElements()
          .any((element) => element.origin == provider);

  testWidgets('a closed room releases its providers and its message list', (
    tester,
  ) async {
    const messages = 5000;
    final conversation = await seedRoom('rooma123', messages);
    await tester.pumpWidget(
      app(PresenceChatRoomScreen(account: account, conversation: conversation)),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatRoomPane)),
    );
    final key = keyFor(conversation);
    expect(container.read(chatMessagesProvider(key)).valueOrNull, hasLength(messages));

    // Close the room the way the app does: the pane leaves the tree while the
    // root ProviderScope stays up.
    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(ChatRoomPane), findsNothing);

    // Nothing watches these any more, so neither the drift subscription nor
    // the emitted list may survive. Without autoDispose every room ever opened
    // keeps both for the process lifetime.
    expect(aliveIn(container, chatMessagesProvider(key)), isFalse);
    expect(aliveIn(container, chatScopeProvider(key)), isFalse);
    expect(aliveIn(container, textSendOperationsProvider(key)), isFalse);
    expect(aliveIn(container, outgoingMessageStatusesProvider(key)), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('time to first painted timeline against cached history size', (
    tester,
  ) async {
    for (final messages in const <int>[500, 5000, 20000]) {
      final conversation = await seedRoom('open$messages', messages);
      final elapsed = Stopwatch()..start();
      await tester.pumpWidget(
        app(
          PresenceChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();
      elapsed.stop();
      final key = keyFor(conversation);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatRoomPane)),
      );
      final emitted = container.read(chatMessagesProvider(key)).valueOrNull;
      // ignore: avoid_print
      print(
        'OPEN cached=$messages emitted=${emitted?.length} '
        'first_paint=${elapsed.elapsedMilliseconds}ms',
      );
      expect(emitted, hasLength(messages));
      // Measured at 90/140/231ms for 500/5000/20000 in a debug VM run, so the
      // query is not what makes a deep room slow to open and no windowing is
      // warranted. Generous bound: this only fires if that stops being true.
      expect(
        elapsed.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'opening a deep room must not stall on the message query',
      );
      await tester.pumpWidget(app(const SizedBox.shrink()));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('visiting many rooms does not accumulate their message lists', (
    tester,
  ) async {
    const rooms = 12;
    const messages = 2000;
    final conversations = <CachedConversation>[];
    for (var index = 0; index < rooms; index++) {
      conversations.add(await seedRoom('room${index.toString().padLeft(4, '0')}', messages));
    }
    final seeded = ProcessInfo.currentRss;

    ProviderContainer? container;
    for (final conversation in conversations) {
      await tester.pumpWidget(
        app(
          PresenceChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();
      container ??= ProviderScope.containerOf(
        tester.element(find.byType(ChatRoomPane)),
      );
      await tester.pumpWidget(app(const SizedBox.shrink()));
      await tester.pump(const Duration(milliseconds: 16));
    }

    final visited = ProcessInfo.currentRss;
    // Diagnostic only. Resident size is not asserted on: measured on macOS,
    // six rooms grew 112.5MB while twelve grew 61.9MB and twenty-four grew
    // 198.9MB, so at this granularity the number tracks GC and allocator
    // timing rather than retention, and a byte budget tight enough to catch a
    // leak also fails on a loaded machine.
    // ignore: avoid_print
    print(
      'VISIT rooms=$rooms messages=$messages '
      'after_seed=${(seeded / (1024 * 1024)).toStringAsFixed(1)}MB '
      'after_visits=${(visited / (1024 * 1024)).toStringAsFixed(1)}MB '
      'growth=${((visited - seeded) / (1024 * 1024)).toStringAsFixed(1)}MB',
    );

    // What retention would actually look like, and what is deterministic:
    // an element per visited room left behind in the container. Without
    // autoDispose every one of the twelve survives.
    final leaked = [
      for (final conversation in conversations)
        if (aliveIn(container!, chatMessagesProvider(keyFor(conversation))))
          conversation.token,
    ];
    expect(
      leaked,
      isEmpty,
      reason: 'closed rooms must not keep their message lists resident',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
