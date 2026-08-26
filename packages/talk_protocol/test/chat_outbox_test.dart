import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final manifest = _readObject(
    'contracts/chat-messages/fixtures/manifest.json',
  );
  final fixtures = (manifest['fixtures']! as List<Object?>)
      .map(_object)
      .toList(growable: false);
  final headerSets = _object(
    manifest['headerSets'],
  ).map((key, value) => MapEntry(key, _stringMap(value)));
  final cases = (manifest['outboxCasesFiles']! as List<Object?>)
      .expand(
        (file) =>
            (_readObject(
                      'contracts/chat-messages/fixtures/${file! as String}',
                    )['cases']!
                    as List<Object?>)
                .map(_object),
      )
      .toList(growable: false);

  test('covers all executable outbox scenarios', () {
    expect(cases.length, 43);
    expect(
      cases.expand((testCase) => testCase['steps']! as List<Object?>).length,
      83,
    );
  });

  group('chat outbox fixtures', () {
    for (final testCase in cases) {
      final id = testCase['id']! as String;
      test(id, () {
        var snapshot = _snapshot(_object(testCase['initialAccounts']));
        final steps = (testCase['steps']! as List<Object?>).map(_object);
        for (final step in steps) {
          final before = snapshot;
          final accountId = AccountId.parse(step['accountId']);
          ChatOutboxResult? result;
          var actualOutcome = 'rejected';
          try {
            result = _applyStep(
              snapshot,
              accountId,
              step,
              fixtures,
              headerSets,
            );
            actualOutcome = _outcomeName(result.outcome);
          } on TalkProtocolException {
            result = null;
          }

          if (step['transaction'] == 'fail') {
            expect(result?.plan, isNotNull);
            snapshot = result!.plan!.discard(snapshot);
            actualOutcome = 'transaction-error';
          } else if (result?.plan != null) {
            snapshot = result!.plan!.commit(snapshot);
          }

          expect(actualOutcome, step['expectedOutcome']);
          final account = snapshot.accounts[accountId]!;
          expect(
            account.lane,
            step['expectedAccountLane'] == 'ready'
                ? ChatAccountLane.ready
                : ChatAccountLane.reauthenticationRequired,
          );
          if (step.containsKey('expectedCredentialGeneration')) {
            expect(
              account.credentialGeneration,
              step['expectedCredentialGeneration'],
            );
          }

          final expectedOperation = step['expectedOperation'];
          if (expectedOperation == null) {
            if (step['action'] == 'admit') {
              final rawOperation = _object(step['operation']);
              final rawId = rawOperation['operationId'];
              if (rawId is String && _isOperationId(rawId)) {
                expect(
                  account.operations.containsKey(ChatOperationId.parse(rawId)),
                  isFalse,
                );
              }
            }
          } else {
            final operationId = _stepOperationId(step, result);
            _expectOperation(
              account.operations[operationId]!,
              _object(expectedOperation),
            );
          }

          for (final entry in before.accounts.entries) {
            if (entry.key != accountId) {
              expect(
                identical(snapshot.accounts[entry.key], entry.value),
                isTrue,
              );
            }
          }
          if (result?.plan == null) {
            expect(identical(snapshot, before), isTrue);
          }
        }
      });
    }
  });

  test('outbox plan is single-use and source-bound', () {
    final snapshot = _snapshot(_object(cases.first['initialAccounts']));
    final step = _object((cases.first['steps']! as List<Object?>).first);
    final accountId = AccountId.parse(step['accountId']);
    final result = _applyStep(snapshot, accountId, step, fixtures, headerSets);
    final committed = result.plan!.commit(snapshot);
    expect(
      () => result.plan!.commit(committed),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidChatOutbox,
        ),
      ),
    );
  });
}

ChatOutboxResult _applyStep(
  ChatRuntimeSnapshot snapshot,
  AccountId accountId,
  Map<String, Object?> step,
  List<Map<String, Object?>> fixtures,
  Map<String, Map<String, String>> headerSets,
) {
  final action = step['action']! as String;
  if (action == 'admit') {
    final raw = _object(step['operation']);
    final account = snapshot.accounts[accountId]!;
    return admitTextSendOperation(
      snapshot,
      accountId: accountId,
      authority: _replayAuthority(account, step),
      draft: _draft(raw),
    );
  }
  if (action == 'reauthSucceeded') {
    final generation = step['credentialGeneration']! as int;
    return completeChatAccountReauthentication(
      snapshot,
      accountId: accountId,
      credentialGeneration: generation,
      capabilityGeneration: generation,
    );
  }

  final operationId = ChatOperationId.parse(step['operationId']);
  final account = snapshot.accounts[accountId]!;
  final authority = _replayAuthority(account, step);
  return switch (action) {
    'claim' => claimTextSendOperation(
      snapshot,
      accountId: accountId,
      authority: authority,
      operationId: operationId,
      now: step['now']! as int,
    ),
    'httpResponse' => applyTextSendHttpResponse(
      snapshot,
      accountId: accountId,
      operationId: operationId,
      response: _sendResponse(
        snapshot.accounts[accountId]!,
        operationId,
        step['fixture']! as String,
        fixtures,
        headerSets,
      ),
      now: step['now'] as int?,
    ),
    'transportError' => recordTextSendTransportFailure(
      snapshot,
      accountId: accountId,
      operationId: operationId,
      bodyState: step['bodyState'] == 'not-sent'
          ? ChatTransportBodyState.notSent
          : ChatTransportBodyState.possiblySent,
      nextAttemptAt: step['nextAttemptAt'] as int?,
    ),
    'restart' => recoverTextSendAfterRestart(
      snapshot,
      accountId: accountId,
      operationId: operationId,
    ),
    'authoritativeMessages' => reconcileTextSendConfirmation(
      snapshot,
      accountId: accountId,
      operationId: operationId,
      confirmations: _authoritativeConfirmations(
        snapshot.accounts[accountId]!,
        operationId,
        step['fixture']! as String,
        fixtures,
        headerSets,
      ),
    ),
    'authoritativeRelay' => reconcileTextSendConfirmation(
      snapshot,
      accountId: accountId,
      operationId: operationId,
      confirmations: <ChatMessageConfirmation>[
        _relayConfirmation(account, _object(step['message'])),
      ],
    ),
    'manualResend' => manuallyResendTextSend(
      snapshot,
      accountId: accountId,
      authority: authority,
      operationId: operationId,
      duplicateRiskAcknowledged: step['duplicateRiskAcknowledged']! as bool,
    ),
    'authFailure' => markChatAccountAuthenticationFailure(
      snapshot,
      accountId: accountId,
      operationId: operationId,
    ),
    _ => throw StateError('Unknown outbox action $action'),
  };
}

ChatSendResponse _sendResponse(
  ChatAccountState account,
  ChatOperationId operationId,
  String fixtureId,
  List<Map<String, Object?>> fixtures,
  Map<String, Map<String, String>> headerSets,
) {
  final fixture = fixtures.singleWhere((item) => item['id'] == fixtureId);
  final context = _object(fixture['context']);
  final parentToken = context['parentRoomToken'] == null
      ? null
      : _token(context['parentRoomToken']);
  final replyToken = context['replyToToken'] == null
      ? null
      : _token(context['replyToToken']);
  final request = ChatSendRequest.restored(
    accountId: account.accountId,
    requestId: ChatRequestId.parse('outbox-$fixtureId'),
    server: account.server,
    roomToken: _token(context['roomToken']),
    operationId: operationId,
    profile: ChatCapabilityProfile.fromTalkFeatures(<Object?>[
      'chat-v2',
      'chat-reference-id',
      'chat-replies',
      'private-reply',
      'threads',
    ], federated: false),
    message: 'Fixture response binding',
    referenceId: ChatReferenceId.parse(context['referenceId']),
    replyTo: context['replyTo'] as int?,
    threadId: context['threadId'] as int?,
    parentRoomToken: parentToken,
    replyToToken: replyToken,
  );
  return decodeChatSendResponse(
    request: request,
    statusCode: int.parse(fixture['status']! as String),
    body: _readBytes('contracts/chat-messages/fixtures/${fixture['file']}'),
    headers: ChatResponseHeaders.fromMap(_fixtureHeaders(fixture, headerSets)),
  );
}

List<ChatMessageConfirmation> _authoritativeConfirmations(
  ChatAccountState account,
  ChatOperationId operationId,
  String fixtureId,
  List<Map<String, Object?>> fixtures,
  Map<String, Map<String, String>> headerSets,
) {
  final operation = account.operations[operationId]!;
  final fixture = fixtures.singleWhere((item) => item['id'] == fixtureId);
  final request = ChatFetchRequest(
    accountId: account.accountId,
    requestId: ChatRequestId.parse('reconcile-$fixtureId'),
    server: account.server,
    roomToken: operation.roomToken,
    profile: ChatCapabilityProfile.fromTalkFeatures(<Object?>[
      'chat-v2',
      if (operation.threadId != null) 'threads',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('0'),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
    threadId: operation.threadId,
  );
  final response = decodeChatGetResponse(
    request: request,
    statusCode: int.parse(fixture['status']! as String),
    body: fixture['status'] == '304'
        ? Uint8List(0)
        : _readBytes('contracts/chat-messages/fixtures/${fixture['file']}'),
    headers: ChatResponseHeaders.fromMap(_fixtureHeaders(fixture, headerSets)),
  );
  expect(<ChatGetClassification>{
    ChatGetClassification.messages,
    ChatGetClassification.invisibleCursorAdvance,
    ChatGetClassification.commonReadOnly,
    ChatGetClassification.notModified,
  }, contains(response.classification));
  return response.messages
      .map(
        (message) => ChatMessageConfirmation.fromMessage(
          message,
          accountId: response.request.accountId,
          server: response.request.server,
        ),
      )
      .toList(growable: false);
}

ChatMessageConfirmation _relayConfirmation(
  ChatAccountState account,
  Map<String, Object?> value,
) {
  final parent = value['parent'] == null ? null : _object(value['parent']);
  return ChatMessageConfirmation(
    accountId: account.accountId,
    server: account.server,
    messageId: value['id']! as int,
    roomToken: _token(value['token']),
    referenceId: value['referenceId']! as String,
    parentMessageId: parent?['id'] as int?,
    parentRoomToken: parent?['token'] == null ? null : _token(parent!['token']),
    parentThreadId: parent?['threadId'] as int?,
    parentDeleted: parent?['deleted'] == true,
    replyToMessageId: null,
    replyToRoomToken: null,
    threadId: value['threadId'] as int?,
  );
}

ChatCapabilityProfile _replayProfile(Map<String, Object?> step) =>
    ChatCapabilityProfile.fromTalkFeatures(
      step['capabilities'] ??
          const <Object?>[
            'chat-v2',
            'chat-reference-id',
            'chat-replies',
            'private-reply',
            'threads',
          ],
      federated: step['federated'] as bool? ?? false,
    );

ChatTextSendAuthority _replayAuthority(
  ChatAccountState account,
  Map<String, Object?> step,
) => ChatTextSendAuthority(
  accountId: account.accountId,
  server: account.server,
  capabilityGeneration: account.capabilityGeneration,
  profile: _replayProfile(step),
  replayContractRevision: textSendReplayContractRevision,
);

TextSendOutboxDraft _draft(Map<String, Object?> value) {
  return TextSendOutboxDraft(
    operationId: ChatOperationId.parse(value['operationId']),
    operationKind: value['operationKind']! as String,
    roomToken: _token(value['roomToken']),
    referenceId: ChatReferenceId.parse(value['referenceId']),
    message: value['message']! as String,
    replayContractRevision: value['replayContractRevision']! as String,
    enqueueSequence: value['enqueueSequence']! as int,
    replyTo: value['replyTo'] as int?,
    threadId: value['threadId'] as int?,
    replyToToken: value['replyToToken'] == null
        ? null
        : _token(value['replyToToken']),
    parentRoomToken: value['parentRoomToken'] == null
        ? null
        : _token(value['parentRoomToken']),
  );
}

ChatRuntimeSnapshot _snapshot(Map<String, Object?> rawAccounts) {
  final accounts = <AccountId, ChatAccountState>{};
  for (final entry in rawAccounts.entries) {
    final accountId = AccountId.parse(entry.key);
    final raw = _object(entry.value);
    final operations = <ChatOperationId, TextSendOutboxOperation>{};
    for (final item in raw['operations']! as List<Object?>) {
      final rawOperation = _object(item);
      final operation = _operationFromJson(rawOperation);
      operations[operation.operationId] = operation;
    }
    accounts[accountId] = ChatAccountState(
      accountId: accountId,
      server: ServerBase.parse('https://${entry.key}.example.invalid'),
      lane: raw['laneState'] == 'ready'
          ? ChatAccountLane.ready
          : ChatAccountLane.reauthenticationRequired,
      credentialGeneration: raw['credentialGeneration'] as int? ?? 1,
      capabilityGeneration: raw['capabilityGeneration'] as int? ?? 1,
      scopes: const {},
      operations: operations,
    );
  }
  return ChatRuntimeSnapshot(accounts: accounts);
}

TextSendOutboxOperation _operationFromJson(Map<String, Object?> value) {
  if (value['operationKind'] != 'textSend') {
    throw StateError('Fixture initial state has an unknown operation kind');
  }
  return TextSendOutboxOperation(
    operationId: ChatOperationId.parse(value['operationId']),
    roomToken: _token(value['roomToken']),
    referenceId: ChatReferenceId.parse(value['referenceId']),
    message: value['message']! as String,
    replayContractRevision: value['replayContractRevision']! as String,
    enqueueSequence: value['enqueueSequence']! as int,
    state: _state(value['state']! as String),
    attemptCount: value['attemptCount']! as int,
    messageIds: ((value['messageIds'] as List<Object?>?) ?? const [])
        .cast<int>(),
    duplicateRiskAcknowledged:
        value['duplicateRiskAcknowledged'] as bool? ?? false,
    errorClass: value['errorClass'] as String?,
    nextAttemptAt: value['nextAttemptAt'] as int?,
    replyTo: value['replyTo'] as int?,
    threadId: value['threadId'] as int?,
    replyToToken: value['replyToToken'] == null
        ? null
        : _token(value['replyToToken']),
    parentRoomToken: value['parentRoomToken'] == null
        ? null
        : _token(value['parentRoomToken']),
  );
}

void _expectOperation(
  TextSendOutboxOperation actual,
  Map<String, Object?> expected,
) {
  expect(actual.state.name, expected['state']);
  expect(actual.attemptCount, expected['attemptCount']);
  expect(actual.messageIds, expected['messageIds']);
  expect(
    actual.duplicateRiskAcknowledged,
    expected['duplicateRiskAcknowledged'],
  );
  expect(actual.errorClass, expected['errorClass']);
  expect(actual.nextAttemptAt, expected['nextAttemptAt']);
  expect(actual.replyTo, expected['replyTo']);
  expect(actual.threadId, expected['threadId']);
  expect(actual.replyToToken?.value, expected['replyToToken']);
  expect(actual.parentRoomToken?.value, expected['parentRoomToken']);
}

ChatOperationId _stepOperationId(
  Map<String, Object?> step,
  ChatOutboxResult? result,
) {
  if (result?.operationId != null) {
    return result!.operationId!;
  }
  final rawId =
      step['operationId'] ?? _object(step['operation'])['operationId'];
  return ChatOperationId.parse(rawId);
}

String _outcomeName(ChatOutboxOutcome outcome) => switch (outcome) {
  ChatOutboxOutcome.queued => 'queued',
  ChatOutboxOutcome.sending => 'sending',
  ChatOutboxOutcome.retryable => 'retryable',
  ChatOutboxOutcome.awaitingConfirmation => 'awaiting-confirmation',
  ChatOutboxOutcome.completed => 'completed',
  ChatOutboxOutcome.failed => 'failed',
  ChatOutboxOutcome.reauthenticationRequired => 'reauth-required',
  ChatOutboxOutcome.reauthenticationSucceeded => 'reauth-succeeded',
  ChatOutboxOutcome.ambiguousMatch => 'ambiguous-match',
  ChatOutboxOutcome.conflictAfterCompletion => 'conflict-after-completion',
  ChatOutboxOutcome.unchanged => 'unchanged',
  ChatOutboxOutcome.rejected => 'rejected',
};

TextSendOutboxState _state(String value) => switch (value) {
  'queued' => TextSendOutboxState.queued,
  'sending' => TextSendOutboxState.sending,
  'retryable' => TextSendOutboxState.retryable,
  'awaitingConfirmation' => TextSendOutboxState.awaitingConfirmation,
  'failed' => TextSendOutboxState.failed,
  'completed' => TextSendOutboxState.completed,
  _ => throw StateError('Unknown outbox state'),
};

bool _isOperationId(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);

Map<String, String> _fixtureHeaders(
  Map<String, Object?> fixture,
  Map<String, Map<String, String>> headerSets,
) {
  final headerSet = fixture['headerSet'];
  return headerSet == null ? const {} : headerSets[headerSet]!;
}

ConversationToken _token(Object? value) => ConversationToken.parse(
  value,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidChatOutbox,
);

Map<String, Object?> _readObject(String relativePath) => _object(
  jsonDecode(File('${_repoRoot().path}/$relativePath').readAsStringSync()),
);

Uint8List _readBytes(String relativePath) =>
    File('${_repoRoot().path}/$relativePath').readAsBytesSync();

Map<String, Object?> _object(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

Map<String, String> _stringMap(Object? value) =>
    (value! as Map<Object?, Object?>).map(
      (key, item) => MapEntry(key! as String, item! as String),
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
