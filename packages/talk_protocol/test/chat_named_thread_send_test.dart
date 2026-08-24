import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('named-thread send contract', () {
    test('keeps ordinary replies on replyTo and named threads on threadId', () {
      final ordinaryReply = _request(replyTo: 108, parentRoomToken: _roomToken);
      final namedThread = _request(threadId: 700);

      expect(ordinaryReply.formBody, <String, Object>{
        'message': _message,
        'referenceId': _referenceId.value,
        'replyTo': 108,
      });
      expect(namedThread.formBody, <String, Object>{
        'message': _message,
        'referenceId': _referenceId.value,
        'threadId': 700,
      });
    });

    test('confirms a named-thread response only in the requested thread', () {
      final request = _request(threadId: 700);
      final response = decodeChatSendResponse(
        request: request,
        statusCode: 201,
        body: _sendBody(threadId: 700),
      );

      expect(response.classification, ChatSendClassification.confirmed);
      expect(response.messageId, 120);
      expect(response.message!.threadId, 700);

      expect(
        () => decodeChatSendResponse(
          request: request,
          statusCode: 201,
          body: _sendBody(threadId: 701),
        ),
        _throwsCode(TalkProtocolErrorCode.invalidChatResponse),
      );
    });

    test('rejects the authoritative parent shape on a direct POST', () {
      final parent = _messageJson(id: 700, threadId: 700);

      expect(
        () => decodeChatSendResponse(
          request: _request(threadId: 700),
          statusCode: 201,
          body: _sendBody(threadId: 700, parent: parent),
        ),
        _throwsCode(TalkProtocolErrorCode.invalidChatResponse),
      );
    });

    test('rejects a thread response for a plain send', () {
      expect(
        () => decodeChatSendResponse(
          request: _request(),
          statusCode: 201,
          body: _sendBody(threadId: 700),
        ),
        _throwsCode(TalkProtocolErrorCode.invalidChatResponse),
      );
    });
  });

  group('named-thread outbox', () {
    test('admits, claims and confirms the durable thread binding', () {
      var snapshot = _snapshot();
      final admitted = admitTextSendOperation(
        snapshot,
        accountId: _accountId,
        authority: _authority(),
        draft: _draft(),
      );
      expect(admitted.outcome, ChatOutboxOutcome.queued);
      snapshot = admitted.plan!.commit(snapshot);
      expect(
        snapshot.accounts[_accountId]!.operations[_operationId]!.threadId,
        700,
      );

      final claimed = claimTextSendOperation(
        snapshot,
        accountId: _accountId,
        authority: _authority(),
        operationId: _operationId,
        now: 1,
      );
      expect(claimed.outcome, ChatOutboxOutcome.sending);
      snapshot = claimed.plan!.commit(snapshot);

      final operation =
          snapshot.accounts[_accountId]!.operations[_operationId]!;
      final response = decodeChatSendResponse(
        request: _requestFromOperation(operation),
        statusCode: 201,
        body: _sendBody(threadId: 700),
      );
      final completed = applyTextSendHttpResponse(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        response: response,
      );

      expect(completed.outcome, ChatOutboxOutcome.completed);
      final committed = completed.plan!.commit(snapshot);
      final finalOperation =
          committed.accounts[_accountId]!.operations[_operationId]!;
      expect(finalOperation.threadId, 700);
      expect(finalOperation.messageIds, <int>[120]);
    });

    test('binds HTTP and authoritative confirmation to room and thread', () {
      final operation = _operation(TextSendOutboxState.sending);
      final snapshot = _snapshot(operation: operation);

      for (final request in <ChatSendRequest>[
        _request(threadId: 701),
        _request(threadId: 700, roomToken: _otherRoomToken),
      ]) {
        final response = decodeChatSendResponse(
          request: request,
          statusCode: 201,
          body: _sendBody(
            threadId: request.threadId!,
            roomToken: request.roomToken,
          ),
        );
        final result = applyTextSendHttpResponse(
          snapshot,
          accountId: _accountId,
          operationId: _operationId,
          response: response,
        );
        expect(result.outcome, ChatOutboxOutcome.rejected);
        expect(result.plan, isNull);
      }

      final awaiting = _snapshot(
        operation: _operation(TextSendOutboxState.awaitingConfirmation),
      );
      for (final confirmation in <ChatMessageConfirmation>[
        _confirmation(threadId: 700),
        _confirmation(threadId: 701),
        _confirmation(threadId: 700, roomToken: _otherRoomToken),
        _confirmation(threadId: 700, accountId: AccountId.parse('account-b')),
        _confirmation(
          threadId: 700,
          server: ServerBase.parse('https://b.example.invalid'),
        ),
      ]) {
        final result = reconcileTextSendConfirmation(
          awaiting,
          accountId: _accountId,
          operationId: _operationId,
          confirmations: <ChatMessageConfirmation>[confirmation],
        );
        expect(result.outcome, ChatOutboxOutcome.unchanged);
        expect(result.plan, isNull);
      }

      final matched = reconcileTextSendConfirmation(
        awaiting,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[
          _confirmationFromJson(
            _messageJson(
              threadId: 700,
              parent: _messageJson(id: 700, threadId: 700),
            ),
          ),
        ],
      );
      expect(matched.outcome, ChatOutboxOutcome.completed);
    });

    test('does not reconcile a plain send from a thread message', () {
      final snapshot = _snapshot(
        operation: _operation(
          TextSendOutboxState.awaitingConfirmation,
          threadId: null,
        ),
      );

      final result = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[_confirmation(threadId: 700)],
      );

      expect(result.outcome, ChatOutboxOutcome.unchanged);
      expect(result.plan, isNull);
    });

    test('reconciles a plain root only when threadId equals message id', () {
      final snapshot = _snapshot(
        operation: _operation(
          TextSendOutboxState.awaitingConfirmation,
          threadId: null,
        ),
      );

      final matched = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[
          _confirmationFromJson(_messageJson(threadId: 120)),
        ],
      );
      expect(matched.outcome, ChatOutboxOutcome.completed);

      final foreignNamed = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[
          _confirmationFromJson(_messageJson(threadId: 700)),
        ],
      );
      expect(foreignNamed.outcome, ChatOutboxOutcome.unchanged);
      expect(foreignNamed.plan, isNull);
    });

    test('reconciles a same-room reply through its topmost thread root', () {
      final snapshot = _snapshot(
        operation: _operation(
          TextSendOutboxState.awaitingConfirmation,
          replyTo: 108,
          threadId: null,
          parentRoomToken: _roomToken,
        ),
      );
      final parent = _messageJson(id: 108, threadId: 77);
      final confirmation = _confirmationFromJson(
        _messageJson(id: 121, threadId: 77, parent: parent),
      );

      final result = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[confirmation],
      );

      expect(result.outcome, ChatOutboxOutcome.completed);
    });

    test('reconciles a private reply through its copied parent root', () {
      final sourceToken = _token('source789');
      final directToken = _token('direct456');
      final snapshot = _snapshot(
        operation: _operation(
          TextSendOutboxState.awaitingConfirmation,
          roomToken: directToken,
          replyTo: 333,
          threadId: null,
          replyToToken: sourceToken,
          parentRoomToken: sourceToken,
        ),
      );
      final parent = _messageJson(
        id: 1210,
        threadId: 0,
        roomToken: sourceToken,
        metadata: <String, Object?>{
          'replyToMessageId': 333,
          'replyToConversationToken': sourceToken.value,
        },
      );
      final confirmation = _confirmationFromJson(
        _messageJson(
          id: 122,
          threadId: 1210,
          roomToken: directToken,
          parent: parent,
        ),
      );

      final result = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[confirmation],
      );

      expect(result.outcome, ChatOutboxOutcome.completed);
    });

    test('rejects a deleted parent with the wrong named root id', () {
      final message = ChatMessage.fromJson(
        _messageJson(
          threadId: 700,
          parent: <String, Object?>{'id': 108, 'deleted': true},
        ),
      );
      final confirmation = ChatMessageConfirmation.fromMessage(
        message,
        accountId: _accountId,
        server: _server,
      );

      expect(confirmation.parentMessageId, 108);
      expect(confirmation.parentRoomToken, isNull);

      final snapshot = _snapshot(
        operation: _operation(TextSendOutboxState.awaitingConfirmation),
      );
      final result = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[confirmation],
      );

      expect(result.outcome, ChatOutboxOutcome.unchanged);
      expect(result.plan, isNull);
    });

    test('accepts a deleted named root only through its preserved id', () {
      final exactRoot = ChatMessage.fromJson(
        _messageJson(
          id: 702,
          threadId: 700,
          parent: <String, Object?>{'id': 700, 'deleted': true},
        ),
      );
      final mismatchedRoot = ChatMessage.fromJson(
        _messageJson(
          id: 703,
          threadId: 700,
          parent: <String, Object?>{'id': 701, 'deleted': true},
        ),
      );
      final snapshot = _snapshot(
        operation: _operation(TextSendOutboxState.awaitingConfirmation),
      );

      final matched = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[
          ChatMessageConfirmation.fromMessage(
            exactRoot,
            accountId: _accountId,
            server: _server,
          ),
        ],
      );
      expect(matched.outcome, ChatOutboxOutcome.completed);

      final rejected = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[
          ChatMessageConfirmation.fromMessage(
            mismatchedRoot,
            accountId: _accountId,
            server: _server,
          ),
        ],
      );
      expect(rejected.outcome, ChatOutboxOutcome.unchanged);
      expect(rejected.plan, isNull);
    });

    test('binds a full authoritative named parent to id, room and thread', () {
      final snapshot = _snapshot(
        operation: _operation(TextSendOutboxState.awaitingConfirmation),
      );
      final exactParent = _messageJson(id: 700, threadId: 700);
      final exact = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[
          _confirmationFromJson(
            _messageJson(id: 702, threadId: 700, parent: exactParent),
          ),
        ],
      );
      expect(exact.outcome, ChatOutboxOutcome.completed);

      final exactDeleted = reconcileTextSendConfirmation(
        snapshot,
        accountId: _accountId,
        operationId: _operationId,
        confirmations: <ChatMessageConfirmation>[
          _confirmationFromJson(
            _messageJson(
              id: 703,
              threadId: 700,
              parent: <String, Object?>{...exactParent, 'deleted': true},
            ),
          ),
        ],
      );
      expect(exactDeleted.outcome, ChatOutboxOutcome.completed);

      for (final parent in <Map<String, Object?>>[
        _messageJson(id: 701, threadId: 700),
        _messageJson(id: 700, threadId: 701),
        _messageJson(id: 700, threadId: 700, roomToken: _otherRoomToken),
      ]) {
        final rejected = reconcileTextSendConfirmation(
          snapshot,
          accountId: _accountId,
          operationId: _operationId,
          confirmations: <ChatMessageConfirmation>[
            _confirmationFromJson(
              _messageJson(id: 703, threadId: 700, parent: parent),
            ),
          ],
        );
        expect(rejected.outcome, ChatOutboxOutcome.unchanged);
        expect(rejected.plan, isNull);
      }
    });
  });

  group('named-thread replay security', () {
    test('rejects mixed reply branches and missing thread capability', () {
      expect(
        () =>
            _request(replyTo: 108, threadId: 700, parentRoomToken: _roomToken),
        _throwsCode(TalkProtocolErrorCode.invalidChatRequest),
      );
      expect(
        () => _request(threadId: 700, profile: _profile(threads: false)),
        _throwsCode(TalkProtocolErrorCode.invalidChatRequest),
      );
      expect(
        () => _draft(replyTo: 108, threadId: 700, parentRoomToken: _roomToken),
        _throwsCode(TalkProtocolErrorCode.invalidChatOutbox),
      );
      expect(
        () => _operation(
          TextSendOutboxState.queued,
          replyTo: 108,
          threadId: 700,
          parentRoomToken: _roomToken,
        ),
        _throwsCode(TalkProtocolErrorCode.invalidChatOutbox),
      );
    });

    test('requires current account, origin, generation, capability and r2', () {
      final snapshot = _snapshot();
      final authorities = <ChatTextSendAuthority>[
        _authority(accountId: AccountId.parse('account-b')),
        _authority(server: ServerBase.parse('https://b.example.invalid')),
        _authority(capabilityGeneration: 2),
        _authority(profile: _profile(threads: false)),
        _authority(
          replayContractRevision: 'talk-chat-text-send-f2958bb-f9b9e947-r1',
        ),
      ];
      for (final authority in authorities) {
        final result = admitTextSendOperation(
          snapshot,
          accountId: _accountId,
          authority: authority,
          draft: _draft(),
        );
        expect(result.outcome, ChatOutboxOutcome.rejected);
        expect(result.plan, isNull);
      }

      final staleDraft = admitTextSendOperation(
        snapshot,
        accountId: _accountId,
        authority: _authority(),
        draft: _draft(
          replayContractRevision: 'talk-chat-text-send-f2958bb-f9b9e947-r1',
        ),
      );
      expect(staleDraft.outcome, ChatOutboxOutcome.rejected);
      expect(staleDraft.plan, isNull);
    });
  });

  group('named-thread restart recovery', () {
    test(
      'preserves threadId and only replays under the current r2 authority',
      () {
        var snapshot = _snapshot(
          operation: _operation(TextSendOutboxState.sending),
        );
        final recovered = recoverTextSendAfterRestart(
          snapshot,
          accountId: _accountId,
          operationId: _operationId,
        );
        expect(recovered.outcome, ChatOutboxOutcome.awaitingConfirmation);
        snapshot = recovered.plan!.commit(snapshot);

        final persisted =
            snapshot.accounts[_accountId]!.operations[_operationId]!;
        final restored = _restoreOperation(persisted);
        expect(restored.threadId, 700);
        snapshot = _snapshot(operation: restored);

        final noThreadCapability = manuallyResendTextSend(
          snapshot,
          accountId: _accountId,
          authority: _authority(profile: _profile(threads: false)),
          operationId: _operationId,
          duplicateRiskAcknowledged: true,
        );
        expect(noThreadCapability.outcome, ChatOutboxOutcome.rejected);

        final replayed = manuallyResendTextSend(
          snapshot,
          accountId: _accountId,
          authority: _authority(),
          operationId: _operationId,
          duplicateRiskAcknowledged: true,
        );
        expect(replayed.outcome, ChatOutboxOutcome.sending);
        final committed = replayed.plan!.commit(snapshot);
        final replayOperation =
            committed.accounts[_accountId]!.operations[_operationId]!;
        final request = _requestFromOperation(replayOperation);
        expect(request.threadId, 700);
        expect(request.formBody, containsPair('threadId', 700));
        expect(request.formBody, isNot(contains('replyTo')));

        final stale = _restoreOperation(
          persisted,
          replayContractRevision: 'talk-chat-text-send-f2958bb-f9b9e947-r1',
        );
        final staleReplay = manuallyResendTextSend(
          _snapshot(operation: stale),
          accountId: _accountId,
          authority: _authority(),
          operationId: _operationId,
          duplicateRiskAcknowledged: true,
        );
        expect(staleReplay.outcome, ChatOutboxOutcome.rejected);
      },
    );
  });
}

final AccountId _accountId = AccountId.parse('account-a');
final ServerBase _server = ServerBase.parse('https://a.example.invalid');
final ConversationToken _roomToken = _token('rooma123');
final ConversationToken _otherRoomToken = _token('roomb123');
final ChatOperationId _operationId = ChatOperationId.parse(
  'aaaaaaaa-0000-4000-8000-000000000001',
);
final ChatReferenceId _referenceId = ChatReferenceId.parse(
  '11111111-1111-4111-8111-111111111111',
);
const String _message = 'Synthetic named-thread reply';

ChatCapabilityProfile _profile({bool threads = true}) =>
    ChatCapabilityProfile.fromTalkFeatures(<Object?>[
      'chat-v2',
      'chat-reference-id',
      'chat-replies',
      if (threads) 'threads',
    ], federated: false);

ChatTextSendAuthority _authority({
  AccountId? accountId,
  ServerBase? server,
  int capabilityGeneration = 1,
  ChatCapabilityProfile? profile,
  String replayContractRevision = textSendReplayContractRevision,
}) => ChatTextSendAuthority(
  accountId: accountId ?? _accountId,
  server: server ?? _server,
  capabilityGeneration: capabilityGeneration,
  profile: profile ?? _profile(),
  replayContractRevision: replayContractRevision,
);

ChatSendRequest _request({
  int? replyTo,
  int? threadId,
  ConversationToken? roomToken,
  ConversationToken? parentRoomToken,
  ChatCapabilityProfile? profile,
}) => ChatSendRequest(
  accountId: _accountId,
  requestId: ChatRequestId.parse('named-thread-send'),
  server: _server,
  roomToken: roomToken ?? _roomToken,
  operationId: _operationId,
  profile: profile ?? _profile(),
  message: _message,
  referenceId: _referenceId,
  replyTo: replyTo,
  threadId: threadId,
  parentRoomToken: parentRoomToken,
);

ChatSendRequest _requestFromOperation(TextSendOutboxOperation operation) =>
    ChatSendRequest.restored(
      accountId: _accountId,
      requestId: ChatRequestId.parse('named-thread-replay'),
      server: _server,
      roomToken: operation.roomToken,
      operationId: operation.operationId,
      profile: _profile(),
      message: operation.message,
      referenceId: operation.referenceId,
      replyTo: operation.replyTo,
      threadId: operation.threadId,
      parentRoomToken: operation.parentRoomToken,
      replyToToken: operation.replyToToken,
    );

TextSendOutboxDraft _draft({
  int? replyTo,
  int? threadId = 700,
  ConversationToken? parentRoomToken,
  String replayContractRevision = textSendReplayContractRevision,
}) => TextSendOutboxDraft(
  operationId: _operationId,
  operationKind: 'textSend',
  roomToken: _roomToken,
  referenceId: _referenceId,
  message: _message,
  replayContractRevision: replayContractRevision,
  enqueueSequence: 1,
  replyTo: replyTo,
  threadId: threadId,
  replyToToken: null,
  parentRoomToken: parentRoomToken,
);

TextSendOutboxOperation _operation(
  TextSendOutboxState state, {
  ConversationToken? roomToken,
  int? replyTo,
  int? threadId = 700,
  ConversationToken? replyToToken,
  ConversationToken? parentRoomToken,
}) => TextSendOutboxOperation(
  operationId: _operationId,
  roomToken: roomToken ?? _roomToken,
  referenceId: _referenceId,
  message: _message,
  replayContractRevision: textSendReplayContractRevision,
  enqueueSequence: 1,
  state: state,
  attemptCount: state == TextSendOutboxState.queued ? 0 : 1,
  messageIds: const [],
  duplicateRiskAcknowledged: false,
  errorClass: state == TextSendOutboxState.awaitingConfirmation
      ? 'process-interrupted'
      : null,
  nextAttemptAt: null,
  replyTo: replyTo,
  threadId: threadId,
  replyToToken: replyToToken,
  parentRoomToken: parentRoomToken,
);

TextSendOutboxOperation _restoreOperation(
  TextSendOutboxOperation source, {
  String? replayContractRevision,
}) => TextSendOutboxOperation(
  operationId: source.operationId,
  roomToken: source.roomToken,
  referenceId: source.referenceId,
  message: source.message,
  replayContractRevision:
      replayContractRevision ?? source.replayContractRevision,
  enqueueSequence: source.enqueueSequence,
  state: source.state,
  attemptCount: source.attemptCount,
  messageIds: source.messageIds,
  duplicateRiskAcknowledged: source.duplicateRiskAcknowledged,
  errorClass: source.errorClass,
  nextAttemptAt: source.nextAttemptAt,
  replyTo: source.replyTo,
  threadId: source.threadId,
  replyToToken: source.replyToToken,
  parentRoomToken: source.parentRoomToken,
);

ChatRuntimeSnapshot _snapshot({TextSendOutboxOperation? operation}) =>
    ChatRuntimeSnapshot(
      accounts: <AccountId, ChatAccountState>{
        _accountId: ChatAccountState(
          accountId: _accountId,
          server: _server,
          lane: ChatAccountLane.ready,
          credentialGeneration: 1,
          capabilityGeneration: 1,
          scopes: const {},
          operations: operation == null
              ? const {}
              : <ChatOperationId, TextSendOutboxOperation>{
                  operation.operationId: operation,
                },
        ),
      },
    );

ChatMessageConfirmation _confirmation({
  required int threadId,
  AccountId? accountId,
  ServerBase? server,
  ConversationToken? roomToken,
}) => ChatMessageConfirmation(
  accountId: accountId ?? _accountId,
  server: server ?? _server,
  messageId: 120,
  roomToken: roomToken ?? _roomToken,
  referenceId: _referenceId.value,
  parentMessageId: null,
  parentRoomToken: null,
  parentThreadId: null,
  parentDeleted: false,
  replyToMessageId: null,
  replyToRoomToken: null,
  threadId: threadId,
);

ChatMessageConfirmation _confirmationFromJson(Map<String, Object?> json) =>
    ChatMessageConfirmation.fromMessage(
      ChatMessage.fromJson(json),
      accountId: _accountId,
      server: _server,
    );

Uint8List _sendBody({
  required int threadId,
  ConversationToken? roomToken,
  Object? parent,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 201,
          'message': 'OK',
        },
        'data': _messageJson(
          threadId: threadId,
          roomToken: roomToken,
          parent: parent,
        ),
      },
    }),
  ),
);

Map<String, Object?> _messageJson({
  int id = 120,
  required int threadId,
  ConversationToken? roomToken,
  Map<String, Object?>? metadata,
  Object? parent,
}) => <String, Object?>{
  'id': id,
  'token': (roomToken ?? _roomToken).value,
  'actorType': 'users',
  'actorId': 'user-a',
  'actorDisplayName': 'User A',
  'timestamp': 1724300120,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': _referenceId.value,
  'message': _message,
  'messageParameters': <String, Object?>{},
  'markdown': true,
  'reactions': <String, Object?>{},
  'threadId': threadId,
  'metaData': ?metadata,
  'parent': ?parent,
};

Matcher _throwsCode(TalkProtocolErrorCode code) => throwsA(
  isA<TalkProtocolException>().having((error) => error.code, 'code', code),
);

ConversationToken _token(Object? value) => ConversationToken.parse(
  value,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidChatOutbox,
);
