import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';

import 'test_support.dart';

void main() {
  test('thread window keeps its root and only the newest replies', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 11, 21),
    );
    const roomToken = 'rooma123';
    const threadId = 100;
    const replyCount = 10000;
    await database.batch((batch) {
      batch.insert(
        database.cachedChatMessages,
        _message(
          messageId: threadId,
          threadId: threadId,
          displayText: 'Thread root',
        ),
      );
      for (var index = 1; index <= replyCount; index++) {
        batch.insert(
          database.cachedChatMessages,
          _message(
            messageId: threadId + index,
            threadId: threadId,
            displayText: 'Reply $index',
          ),
        );
      }
      batch.insert(
        database.cachedChatMessages,
        _message(
          messageId: threadId + replyCount + 1,
          threadId: threadId,
          displayText: 'Reaction notice',
          systemMessage: 'reaction',
        ),
      );
    });

    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    const key = (
      accountId: 'account-a',
      roomToken: roomToken,
      threadId: threadId,
    );
    Completer<List<CachedChatMessage>>? waiter;
    bool Function(List<CachedChatMessage>)? accepts;
    final subscription = container.listen(chatMessagesProvider(key), (
      previous,
      next,
    ) {
      final messages = next.valueOrNull;
      if (messages != null &&
          waiter?.isCompleted == false &&
          (accepts?.call(messages) ?? false)) {
        waiter!.complete(messages);
      }
    }, fireImmediately: true);
    addTearDown(subscription.close);

    Future<List<CachedChatMessage>> waitFor(
      bool Function(List<CachedChatMessage>) predicate,
    ) async {
      final current = subscription.read().valueOrNull;
      if (current != null && predicate(current)) {
        return current;
      }
      accepts = predicate;
      waiter = Completer<List<CachedChatMessage>>();
      return waiter!.future.timeout(const Duration(seconds: 5));
    }

    final initial = await waitFor((messages) => messages.length == 301);
    expect(initial.first.messageId, threadId);
    expect(initial[1].messageId, threadId + replyCount - 299);
    expect(initial.last.messageId, threadId + replyCount);

    await (database.update(database.cachedChatMessages)..where(
          (row) =>
              row.accountId.equals('account-a') &
              row.roomToken.equals(roomToken) &
              row.messageId.equals(threadId),
        ))
        .write(
          const CachedChatMessagesCompanion(
            displayText: Value('Thread root after reaction'),
          ),
        );
    final afterReaction = await waitFor(
      (messages) => messages.first.displayText == 'Thread root after reaction',
    );
    expect(afterReaction, hasLength(301));
    expect(afterReaction.first.messageId, threadId);

    const newestReplyId = threadId + replyCount + 2;
    await database
        .into(database.cachedChatMessages)
        .insert(
          _message(
            messageId: newestReplyId,
            threadId: threadId,
            displayText: 'Newest live reply',
          ),
        );
    final afterLiveReply = await waitFor(
      (messages) => messages.last.messageId == newestReplyId,
    );
    expect(afterLiveReply, hasLength(301));
    expect(afterLiveReply.first.messageId, threadId);
    expect(afterLiveReply[1].messageId, threadId + replyCount - 298);

    container.read(chatMessageWindowProvider(key).notifier).state = 600;
    final widened = await waitFor((messages) => messages.length == 601);
    expect(widened.first.messageId, threadId);
    expect(widened[1].messageId, threadId + replyCount - 598);
    expect(widened.last.messageId, newestReplyId);

    final index = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
          variables: [
            Variable.withString('cached_chat_messages_thread_window'),
          ],
        )
        .getSingleOrNull();
    expect(index?.read<String>('name'), 'cached_chat_messages_thread_window');
  });
}

CachedChatMessagesCompanion _message({
  required int messageId,
  required int threadId,
  required String displayText,
  String systemMessage = '',
}) {
  final raw = <String, Object?>{
    'id': messageId,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'fixture-user',
    'actorDisplayName': 'Fixture user',
    'timestamp': 1724300000 + messageId,
    'systemMessage': systemMessage,
    'messageType': 'comment',
    'referenceId': 'reference-$messageId',
    'message': displayText,
    'messageParameters': const <String, Object?>{},
    'markdown': false,
    'reactions': const <String, Object?>{},
    'reactionsSelf': const <Object?>[],
    'deleted': null,
    'threadId': threadId,
    'isThread': messageId == threadId,
    'threadTitle': messageId == threadId ? 'Synthetic thread' : null,
    'threadReplies': messageId == threadId ? 10000 : 0,
  };
  return CachedChatMessagesCompanion.insert(
    accountId: 'account-a',
    roomToken: 'rooma123',
    messageId: messageId,
    actorType: 'users',
    actorId: 'fixture-user',
    actorDisplayName: 'Fixture user',
    timestamp: 1724300000 + messageId,
    systemMessage: systemMessage,
    messageType: 'comment',
    referenceId: 'reference-$messageId',
    displayText: displayText,
    deleted: false,
    threadId: Value(threadId),
    rawJson: jsonEncode(raw),
  );
}
