import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  group('outgoing message truth states', () {
    test('queued, sending, and ambiguous sends stay sending', () {
      for (final state in <String>[
        'queued',
        'sending',
        'awaitingConfirmation',
      ]) {
        final status = resolveOutgoingMessageStatuses(
          _projection(outboxState: state),
        ).single;

        expect(status.state, OutgoingMessageDeliveryState.sending);
        expect(status.confirmationAmbiguous, state == 'awaitingConfirmation');
      }
    });

    test('retryable and terminal failures are not sent', () {
      for (final state in <String>['retryable', 'failed']) {
        final status = resolveOutgoingMessageStatuses(
          _projection(outboxState: state),
        ).single;

        expect(status.state, OutgoingMessageDeliveryState.failed);
        expect(status.messageId, isNull);
      }
    });

    test('completed operation without cached confirmation is not sent', () {
      final status = resolveOutgoingMessageStatuses(
        _projection(outboxState: 'completed', messageIds: const [120]),
      ).single;

      expect(status.state, OutgoingMessageDeliveryState.sending);
      expect(status.messageId, isNull);
    });

    test('server-confirmed own message is sent before common read', () {
      final status = resolveOutgoingMessageStatuses(
        _projection(
          outboxState: 'completed',
          messageIds: const [120],
          confirmedMessages: [_message(messageId: 120)],
        ),
      ).single;

      expect(status.state, OutgoingMessageDeliveryState.sent);
      expect(status.messageId, 120);
      expect(
        OutgoingMessageDeliveryState.values.map((state) => state.name),
        isNot(contains('delivered')),
      );
    });

    test('server common-read cursor upgrades a confirmed message to read', () {
      final status = resolveOutgoingMessageStatuses(
        _projection(
          outboxState: 'completed',
          messageIds: const [120],
          confirmedMessages: [_message(messageId: 120)],
          lastCommonRead: ChatCursor.parse('120'),
        ),
      ).single;

      expect(status.state, OutgoingMessageDeliveryState.read);
      expect(status.messageId, 120);
    });

    test('common-read cursor never upgrades an unconfirmed send', () {
      final status = resolveOutgoingMessageStatuses(
        _projection(
          outboxState: 'awaitingConfirmation',
          messageIds: const [120],
          lastCommonRead: ChatCursor.parse('999'),
        ),
      ).single;

      expect(status.state, OutgoingMessageDeliveryState.sending);
      expect(status.messageId, isNull);
    });
  });

  test('service projection ignores unconfirmed reference collisions', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await database
        .into(database.textSendOperations)
        .insert(_operation(outboxState: 'completed', messageIds: const [120]));
    await database
        .into(database.cachedChatMessages)
        .insert(_message(messageId: 120));
    await database
        .into(database.cachedChatMessages)
        .insert(
          _message(
            messageId: 121,
            actorId: 'another-user',
            displayText: 'Reference collision from another user',
          ),
        );
    final api = HttpNextcloudApi(
      client: MockClient((_) => throw StateError('Network must not be used')),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: MemoryCredentialVault(),
      api: api,
    );

    final statuses = await service
        .watchOutgoingMessageStatuses(
          accountId: 'account-a',
          roomToken: 'rooma123',
        )
        .first;

    expect(statuses, hasLength(1));
    expect(statuses.single.messageId, 120);
    expect(statuses.single.state, OutgoingMessageDeliveryState.sent);
  });

  test('live common-read scope update advances sent status to read', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await database.into(database.chatScopes).insert(_scope('119'));
    await database
        .into(database.textSendOperations)
        .insert(_operation(outboxState: 'completed', messageIds: const [120]));
    await database
        .into(database.cachedChatMessages)
        .insert(_message(messageId: 120));
    final api = HttpNextcloudApi(
      client: MockClient((_) => throw StateError('Network must not be used')),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: MemoryCredentialVault(),
      api: api,
    );
    final iterator = StreamIterator(
      service.watchOutgoingMessageStatuses(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ),
    );
    addTearDown(iterator.cancel);

    expect(
      await iterator.moveNext().timeout(const Duration(seconds: 2)),
      isTrue,
    );
    expect(iterator.current.single.state, OutgoingMessageDeliveryState.sent);

    await (database.update(database.chatScopes)..where(
          (scope) =>
              scope.accountId.equals('account-a') &
              scope.roomToken.equals('rooma123') &
              scope.scopeKey.equals('root'),
        ))
        .write(const ChatScopesCompanion(lastCommonRead: Value('120')));

    expect(
      await iterator.moveNext().timeout(const Duration(seconds: 2)),
      isTrue,
    );
    expect(iterator.current.single.state, OutgoingMessageDeliveryState.read);
  });
}

StoredOutgoingTextMessage _projection({
  required String outboxState,
  List<int> messageIds = const [],
  List<CachedChatMessage> confirmedMessages = const [],
  ChatCursor? lastCommonRead,
}) => StoredOutgoingTextMessage(
  operation: _operation(outboxState: outboxState, messageIds: messageIds),
  confirmedMessages: confirmedMessages,
  lastCommonRead: lastCommonRead,
);

ChatScopesCompanion _scope(String lastCommonRead) => ChatScopesCompanion.insert(
  accountId: 'account-a',
  roomToken: 'rooma123',
  scopeKey: 'root',
  threadId: const Value(null),
  historyCursor: '120',
  futureCursor: '120',
  lastCommonRead: lastCommonRead,
  lastReadMessage: 120,
  unreadMessages: 0,
  hasHistory: true,
  futureConverged: true,
  blocksJson: '[["120","120"]]',
);

StoredTextSendOperation _operation({
  required String outboxState,
  List<int> messageIds = const [],
}) => StoredTextSendOperation(
  accountId: 'account-a',
  operationId: '00000000-0000-4000-8000-000000000001',
  roomToken: 'rooma123',
  referenceId: '00000000-0000-4000-8000-000000000002',
  message: 'Synthetic outgoing message',
  replayContractRevision: 'talk-chat-text-send-f2958bb-f9b9e947-r2',
  enqueueSequence: 1,
  outboxState: outboxState,
  attemptCount: 1,
  messageIdsJson: jsonEncode(messageIds),
  duplicateRiskAcknowledged: false,
  createdAtMillis: 1,
  updatedAtMillis: 1,
);

CachedChatMessage _message({
  required int messageId,
  String actorId = 'fixture-user',
  String displayText = 'Synthetic outgoing message',
}) => CachedChatMessage(
  accountId: 'account-a',
  roomToken: 'rooma123',
  messageId: messageId,
  actorType: 'users',
  actorId: actorId,
  actorDisplayName: actorId,
  timestamp: 1770000120,
  systemMessage: '',
  messageType: 'comment',
  referenceId: '00000000-0000-4000-8000-000000000002',
  displayText: displayText,
  deleted: false,
  rawJson: '{}',
);
