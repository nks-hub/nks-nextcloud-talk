import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('rejects case-insensitive duplicate response headers', () {
    expect(
      () => ChatResponseHeaders.fromEntries(const [
        MapEntry('X-Chat-Last-Given', '1'),
        MapEntry('x-chat-last-given', '2'),
      ]),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidChatHeaders,
        ),
      ),
    );
  });

  test('binds a response to the exact immutable request', () {
    final request = _fetchRequest(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse('https://a.example.invalid'),
      direction: ChatFetchDirection.history,
      cursor: '109',
    );
    final response = decodeChatGetResponse(
      request: request,
      statusCode: 200,
      body: _fixtureBytes('chat-history.response.json'),
      headers: ChatResponseHeaders.fromMap(const {
        'X-Chat-Last-Given': '103',
        'X-Chat-Last-Common-Read': '100',
      }),
    );

    expect(identical(response.request, request), isTrue);
  });

  test('deeply freezes wire data and response collections', () {
    final response = _historyResponse();
    final message = response.messages.first;

    expect(() => response.messages.add(message), throwsUnsupportedError);
    expect(() => response.messages[0] = message, throwsUnsupportedError);
    expect(() => message.wire['message'] = 'changed', throwsUnsupportedError);
    expect(message.messageParameters.clear, throwsUnsupportedError);
  });

  test('redacts messages, tokens, references and dynamic parameter keys', () {
    final raw = _fixtureObject('chat-history.response.json');
    final ocs = _object(raw['ocs']);
    final data = ocs['data']! as List<Object?>;
    final message = _object(data.first);
    message['messageParameters'] = <String, Object?>{
      'private-dynamic-key': <String, Object?>{'type': ''},
    };

    TalkProtocolException? captured;
    try {
      decodeChatGetResponse(
        request: _fetchRequest(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse('https://a.example.invalid'),
          direction: ChatFetchDirection.history,
          cursor: '109',
        ),
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(jsonEncode(raw))),
        headers: ChatResponseHeaders.fromMap(const {
          'X-Chat-Last-Given': '103',
        }),
      );
    } on TalkProtocolException catch (error) {
      captured = error;
    }
    expect(captured, isNotNull);
    expect(captured!.path, contains('<member>'));
    expect(captured.toString(), isNot(contains('private-dynamic-key')));
    expect(captured.toString(), isNot(contains('Synthetic newest')));

    final response = _historyResponse();
    final value =
        '${response.toString()} ${response.messages.first} '
        '${response.messages.first.wire}';
    expect(value, isNot(contains('rooma123')));
    expect(value, isNot(contains('Synthetic newest history message')));

    final send = ChatSendRequest(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('send-redaction'),
      server: ServerBase.parse('https://a.example.invalid'),
      roomToken: _token('rooma123'),
      operationId: ChatOperationId.parse(
        'aaaaaaaa-0000-4000-8000-000000000001',
      ),
      profile: _sendProfile(),
      message: 'Private message body',
      referenceId: ChatReferenceId.parse(
        '11111111-1111-4111-8111-111111111111',
      ),
    );
    expect(send.toString(), isNot(contains('Private message body')));
    expect(send.toString(), isNot(contains('11111111')));

    final parameter = ChatRichObjectParameter.fromJson(<String, Object?>{
      'type': 'private\r\nforged-log-entry',
      'id': 'private-id',
      'name': 'Private name',
      'link': 'https://example.invalid/private',
    });
    expect(parameter.toString(), 'ChatRichObjectParameter(<redacted>)');
  });

  test('enforces response byte, UTF-8, depth and node budgets', () {
    final request = _fetchRequest(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse('https://a.example.invalid'),
      direction: ChatFetchDirection.future,
      cursor: '0',
    );
    for (final body in <Uint8List>[
      Uint8List(chatMaximumResponseBytes + 1),
      Uint8List.fromList(const [0xff]),
    ]) {
      expect(
        () => decodeChatGetResponse(
          request: request,
          statusCode: 200,
          body: body,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    }

    Object? nested = 'leaf';
    for (var index = 0; index < chatJsonMaximumDepth + 2; index++) {
      nested = <String, Object?>{'node': nested};
    }
    final deepBody = _ocsBody(<Object?>[nested]);
    expect(
      () => decodeChatGetResponse(
        request: request,
        statusCode: 200,
        body: deepBody,
      ),
      throwsA(isA<TalkProtocolException>()),
    );

    final wideBody = _ocsBody(List<Object?>.filled(chatJsonMaximumNodes, null));
    expect(wideBody.length, lessThan(chatMaximumResponseBytes));
    expect(
      () => decodeChatGetResponse(
        request: request,
        statusCode: 200,
        body: wideBody,
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('requires an actually empty HTTP 304 body', () {
    expect(
      () => decodeChatGetResponse(
        request: _fetchRequest(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse('https://a.example.invalid'),
          direction: ChatFetchDirection.future,
          cursor: '0',
        ),
        statusCode: 304,
        body: Uint8List.fromList(utf8.encode('null')),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('rejects cross-account and cross-origin merge binding', () {
    final accountId = AccountId.parse('account-a');
    final server = ServerBase.parse('https://a.example.invalid');
    final snapshot = _snapshot(accountId: accountId, server: server);
    final wrongAccountResponse = decodeChatGetResponse(
      request: _fetchRequest(
        accountId: AccountId.parse('account-b'),
        server: server,
        direction: ChatFetchDirection.history,
        cursor: '109',
      ),
      statusCode: 200,
      body: _fixtureBytes('chat-history.response.json'),
      headers: ChatResponseHeaders.fromMap(const {
        'X-Chat-Last-Given': '103',
        'X-Chat-Last-Common-Read': '100',
      }),
    );
    final wrongOriginResponse = decodeChatGetResponse(
      request: _fetchRequest(
        accountId: accountId,
        server: ServerBase.parse('https://b.example.invalid'),
        direction: ChatFetchDirection.history,
        cursor: '109',
      ),
      statusCode: 200,
      body: _fixtureBytes('chat-history.response.json'),
      headers: ChatResponseHeaders.fromMap(const {
        'X-Chat-Last-Given': '103',
        'X-Chat-Last-Common-Read': '100',
      }),
    );

    expect(
      planChatGetMerge(snapshot, wrongAccountResponse).outcome,
      ChatMergeOutcome.rejected,
    );
    expect(
      planChatGetMerge(snapshot, wrongOriginResponse).outcome,
      ChatMergeOutcome.rejected,
    );
  });

  test('rejects cross-account and cross-origin outbox confirmations', () {
    final accountId = AccountId.parse('account-a');
    final otherAccountId = AccountId.parse('account-b');
    final server = ServerBase.parse('https://a.example.invalid');
    final otherServer = ServerBase.parse('https://b.example.invalid');
    final operation = _textSendOperation(TextSendOutboxState.sending);
    final snapshot = _snapshot(
      accountId: accountId,
      server: server,
      operation: operation,
    );

    for (final response in <ChatSendResponse>[
      _sendSuccessResponse(
        accountId: otherAccountId,
        server: server,
        operation: operation,
      ),
      _sendSuccessResponse(
        accountId: accountId,
        server: otherServer,
        operation: operation,
      ),
    ]) {
      final result = applyTextSendHttpResponse(
        snapshot,
        accountId: accountId,
        operationId: operation.operationId,
        response: response,
      );
      expect(result.outcome, ChatOutboxOutcome.rejected);
      expect(result.plan, isNull);
    }

    for (final confirmation in <ChatMessageConfirmation>[
      _confirmation(accountId: otherAccountId, server: server),
      _confirmation(accountId: accountId, server: otherServer),
    ]) {
      final result = reconcileTextSendConfirmation(
        snapshot,
        accountId: accountId,
        operationId: operation.operationId,
        confirmations: <ChatMessageConfirmation>[confirmation],
      );
      expect(result.outcome, ChatOutboxOutcome.unchanged);
      expect(result.plan, isNull);
    }
  });

  test('blocks restored sends with stale replay authority', () {
    final accountId = AccountId.parse('account-a');
    final server = ServerBase.parse('https://a.example.invalid');
    final otherServer = ServerBase.parse('https://b.example.invalid');
    final readOnlyProfile = ChatCapabilityProfile.fromTalkFeatures(<Object?>[
      'chat-v2',
    ], federated: false);
    final queued = _textSendOperation(TextSendOutboxState.queued);
    final queuedSnapshot = _snapshot(
      accountId: accountId,
      server: server,
      operation: queued,
    );

    for (final authority in <ChatTextSendAuthority>[
      _authority(accountId: accountId, server: otherServer),
      _authority(
        accountId: accountId,
        server: server,
        profile: readOnlyProfile,
      ),
      _authority(accountId: accountId, server: server, capabilityGeneration: 2),
    ]) {
      final result = claimTextSendOperation(
        queuedSnapshot,
        accountId: accountId,
        authority: authority,
        operationId: queued.operationId,
        now: 1,
      );
      expect(result.outcome, ChatOutboxOutcome.rejected);
      expect(result.plan, isNull);
    }

    final staleQueued = _textSendOperation(
      TextSendOutboxState.queued,
      replayContractRevision: 'obsolete-contract',
    );
    final staleClaim = claimTextSendOperation(
      _snapshot(accountId: accountId, server: server, operation: staleQueued),
      accountId: accountId,
      authority: _authority(accountId: accountId, server: server),
      operationId: staleQueued.operationId,
      now: 1,
    );
    expect(staleClaim.outcome, ChatOutboxOutcome.rejected);
    expect(staleClaim.plan, isNull);

    final currentAwaiting = _textSendOperation(
      TextSendOutboxState.awaitingConfirmation,
    );
    final staleAwaiting = _textSendOperation(
      TextSendOutboxState.awaitingConfirmation,
      replayContractRevision: 'obsolete-contract',
    );
    for (final binding in <(TextSendOutboxOperation, ChatTextSendAuthority)>[
      (currentAwaiting, _authority(accountId: accountId, server: otherServer)),
      (
        currentAwaiting,
        _authority(
          accountId: accountId,
          server: server,
          profile: readOnlyProfile,
        ),
      ),
      (
        currentAwaiting,
        _authority(
          accountId: accountId,
          server: server,
          capabilityGeneration: 2,
        ),
      ),
      (staleAwaiting, _authority(accountId: accountId, server: server)),
    ]) {
      final awaitingSnapshot = _snapshot(
        accountId: accountId,
        server: server,
        operation: binding.$1,
      );
      final result = manuallyResendTextSend(
        awaitingSnapshot,
        accountId: accountId,
        authority: binding.$2,
        operationId: binding.$1.operationId,
        duplicateRiskAcknowledged: true,
      );
      expect(result.outcome, ChatOutboxOutcome.rejected);
      expect(result.plan, isNull);
    }
  });

  test('rejects text-send authority bound to another account', () {
    final accountId = AccountId.parse('account-a');
    final server = ServerBase.parse('https://a.example.invalid');
    final foreignAuthority = _authority(
      accountId: AccountId.parse('account-b'),
      server: server,
    );
    final queued = _textSendOperation(TextSendOutboxState.queued);

    final admission = admitTextSendOperation(
      _snapshot(accountId: accountId, server: server),
      accountId: accountId,
      authority: foreignAuthority,
      draft: TextSendOutboxDraft(
        operationId: queued.operationId,
        operationKind: 'textSend',
        roomToken: queued.roomToken,
        referenceId: queued.referenceId,
        message: 'Private pending message',
        replayContractRevision: textSendReplayContractRevision,
        enqueueSequence: 1,
        replyTo: null,
        threadId: null,
        replyToToken: null,
        parentRoomToken: null,
      ),
    );
    expect(admission.outcome, ChatOutboxOutcome.rejected);
    expect(admission.plan, isNull);

    final claim = claimTextSendOperation(
      _snapshot(accountId: accountId, server: server, operation: queued),
      accountId: accountId,
      authority: foreignAuthority,
      operationId: queued.operationId,
      now: 1,
    );
    expect(claim.outcome, ChatOutboxOutcome.rejected);
    expect(claim.plan, isNull);

    final awaiting = _textSendOperation(
      TextSendOutboxState.awaitingConfirmation,
    );
    final resend = manuallyResendTextSend(
      _snapshot(accountId: accountId, server: server, operation: awaiting),
      accountId: accountId,
      authority: foreignAuthority,
      operationId: awaiting.operationId,
      duplicateRiskAcknowledged: true,
    );
    expect(resend.outcome, ChatOutboxOutcome.rejected);
    expect(resend.plan, isNull);
  });

  test('rejects a reply-shaped confirmation for a non-reply send', () {
    final request = ChatSendRequest(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('non-reply-parent'),
      server: ServerBase.parse('https://a.example.invalid'),
      roomToken: _token('rooma123'),
      operationId: ChatOperationId.parse(
        'aaaaaaaa-0000-4000-8000-000000000001',
      ),
      profile: _sendProfile(),
      message: 'Private message body',
      referenceId: ChatReferenceId.parse(
        '22222222-2222-4222-8222-222222222222',
      ),
    );

    expect(
      () => decodeChatSendResponse(
        request: request,
        statusCode: 201,
        body: _fixtureBytes('send-reply-success.response.json'),
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidChatResponse,
        ),
      ),
    );
  });

  test('commits message merge and outbox reconciliation atomically', () {
    final accountId = AccountId.parse('account-a');
    final server = ServerBase.parse('https://a.example.invalid');
    final snapshot = _snapshot(
      accountId: accountId,
      server: server,
      futureCursor: '115',
      operation: TextSendOutboxOperation(
        operationId: ChatOperationId.parse(
          'aaaaaaaa-0000-4000-8000-000000000001',
        ),
        roomToken: _token('rooma123'),
        referenceId: ChatReferenceId.parse(
          '11111111-1111-4111-8111-111111111111',
        ),
        message: 'Private pending message',
        replayContractRevision: textSendReplayContractRevision,
        enqueueSequence: 1,
        state: TextSendOutboxState.awaitingConfirmation,
        attemptCount: 1,
        messageIds: const [],
        duplicateRiskAcknowledged: false,
        errorClass: 'ambiguous-transport',
        nextAttemptAt: null,
        replyTo: null,
        threadId: null,
        replyToToken: null,
        parentRoomToken: null,
      ),
    );
    final request = _fetchRequest(
      accountId: accountId,
      server: server,
      direction: ChatFetchDirection.future,
      cursor: '115',
    );
    final response = decodeChatGetResponse(
      request: request,
      statusCode: 200,
      body: _fixtureBytes('chat-send-confirmation.response.json'),
      headers: ChatResponseHeaders.fromMap(const {
        'X-Chat-Last-Given': '120',
        'X-Chat-Last-Common-Read': '110',
      }),
    );

    final result = planChatGetMerge(snapshot, response);
    expect(result.plan!.messageUpserts.length, 1);
    final committed = result.plan!.commit(snapshot);
    final account = committed.accounts[accountId]!;
    final scope = account
        .scopes[ChatScopeKey(roomToken: _token('rooma123'), threadId: null)]!;
    final operation = account.operations.values.single;
    expect(scope.futureCursor.value, '120');
    expect(scope.messageIds, <int>[109, 115, 120]);
    expect(operation.state, TextSendOutboxState.completed);
    expect(operation.messageIds, <int>[120]);

    final rollbackPlan = planChatGetMerge(snapshot, response).plan!;
    final rolledBack = rollbackPlan.discard(snapshot);
    expect(identical(rolledBack, snapshot), isTrue);
    expect(
      rolledBack.accounts[accountId]!.operations.values.single.state,
      TextSendOutboxState.awaitingConfirmation,
    );
  });
}

ChatGetResponse _historyResponse() => decodeChatGetResponse(
  request: _fetchRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://a.example.invalid'),
    direction: ChatFetchDirection.history,
    cursor: '109',
  ),
  statusCode: 200,
  body: _fixtureBytes('chat-history.response.json'),
  headers: ChatResponseHeaders.fromMap(const {
    'X-Chat-Last-Given': '103',
    'X-Chat-Last-Common-Read': '100',
  }),
);

ChatRuntimeSnapshot _snapshot({
  required AccountId accountId,
  required ServerBase server,
  String futureCursor = '109',
  TextSendOutboxOperation? operation,
}) {
  final roomToken = _token('rooma123');
  final history = ChatCursor.parse('109');
  final future = ChatCursor.parse(futureCursor);
  final scope = ChatScopeState(
    messageIds: <int>[109, if (futureCursor != '109') int.parse(futureCursor)],
    historyCursor: history,
    futureCursor: future,
    lastCommonRead: ChatCursor.parse('100'),
    lastReadMessage: 109,
    unreadMessages: 0,
    hasHistory: true,
    futureConverged: false,
    blocks: <ChatBlock>[ChatBlock(start: history, end: future)],
  );
  return ChatRuntimeSnapshot(
    accounts: <AccountId, ChatAccountState>{
      accountId: ChatAccountState(
        accountId: accountId,
        server: server,
        lane: ChatAccountLane.ready,
        credentialGeneration: 1,
        capabilityGeneration: 1,
        scopes: <ChatScopeKey, ChatScopeState>{
          ChatScopeKey(roomToken: roomToken, threadId: null): scope,
        },
        operations: operation == null
            ? const {}
            : <ChatOperationId, TextSendOutboxOperation>{
                operation.operationId: operation,
              },
      ),
    },
  );
}

ChatFetchRequest _fetchRequest({
  required AccountId accountId,
  required ServerBase server,
  required ChatFetchDirection direction,
  required String cursor,
}) => ChatFetchRequest(
  accountId: accountId,
  requestId: ChatRequestId.parse('security-request'),
  server: server,
  roomToken: _token('rooma123'),
  profile: ChatCapabilityProfile.fromTalkFeatures(<Object?>[
    'chat-v2',
  ], federated: false),
  direction: direction,
  cursor: ChatCursor.parse(cursor),
  lastCommonRead: ChatCursor.parse('100'),
  limit: 200,
  includeLastKnown: direction == ChatFetchDirection.history,
  timeoutSeconds: 0,
  interactive: true,
);

ChatCapabilityProfile _sendProfile() => ChatCapabilityProfile.fromTalkFeatures(
  <Object?>['chat-v2', 'chat-reference-id'],
  federated: false,
);

ChatTextSendAuthority _authority({
  required AccountId accountId,
  required ServerBase server,
  int capabilityGeneration = 1,
  ChatCapabilityProfile? profile,
}) => ChatTextSendAuthority(
  accountId: accountId,
  server: server,
  capabilityGeneration: capabilityGeneration,
  profile: profile ?? _sendProfile(),
  replayContractRevision: textSendReplayContractRevision,
);

TextSendOutboxOperation _textSendOperation(
  TextSendOutboxState state, {
  String replayContractRevision = textSendReplayContractRevision,
}) => TextSendOutboxOperation(
  operationId: ChatOperationId.parse('aaaaaaaa-0000-4000-8000-000000000001'),
  roomToken: _token('rooma123'),
  referenceId: ChatReferenceId.parse('11111111-1111-4111-8111-111111111111'),
  message: 'Private pending message',
  replayContractRevision: replayContractRevision,
  enqueueSequence: 1,
  state: state,
  attemptCount: state == TextSendOutboxState.queued ? 0 : 1,
  messageIds: const [],
  duplicateRiskAcknowledged: false,
  errorClass: state == TextSendOutboxState.awaitingConfirmation
      ? 'ambiguous-transport'
      : null,
  nextAttemptAt: null,
  replyTo: null,
  threadId: null,
  replyToToken: null,
  parentRoomToken: null,
);

ChatSendResponse _sendSuccessResponse({
  required AccountId accountId,
  required ServerBase server,
  required TextSendOutboxOperation operation,
}) => decodeChatSendResponse(
  request: ChatSendRequest.restored(
    accountId: accountId,
    requestId: ChatRequestId.parse('outbox-binding'),
    server: server,
    roomToken: operation.roomToken,
    operationId: operation.operationId,
    profile: _sendProfile(),
    message: operation.message,
    referenceId: operation.referenceId,
  ),
  statusCode: 201,
  body: _fixtureBytes('send-success.response.json'),
);

ChatMessageConfirmation _confirmation({
  required AccountId accountId,
  required ServerBase server,
}) => ChatMessageConfirmation(
  accountId: accountId,
  server: server,
  messageId: 120,
  roomToken: _token('rooma123'),
  referenceId: '11111111-1111-4111-8111-111111111111',
  parentMessageId: null,
  parentRoomToken: null,
  parentThreadId: null,
  parentDeleted: false,
  replyToMessageId: null,
  replyToRoomToken: null,
  threadId: 120,
);

Uint8List _ocsBody(Object? data) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': data,
      },
    }),
  ),
);

Map<String, Object?> _fixtureObject(String filename) =>
    _object(jsonDecode(utf8.decode(_fixtureBytes(filename))));

Uint8List _fixtureBytes(String filename) => File(
  '${_repoRoot().path}/contracts/chat-messages/fixtures/$filename',
).readAsBytesSync();

Map<String, Object?> _object(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

ConversationToken _token(Object? value) => ConversationToken.parse(
  value,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidChatResponse,
);

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/chat-messages/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
