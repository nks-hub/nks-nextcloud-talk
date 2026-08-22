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
  final cases =
      (_readObject(
                'contracts/chat-messages/fixtures/merge.cases.json',
              )['cases']!
              as List<Object?>)
          .map(_object)
          .toList(growable: false);

  test('covers all executable merge scenarios', () {
    expect(cases.length, 23);
    expect(
      cases.expand((testCase) => testCase['steps']! as List<Object?>).length,
      25,
    );
  });

  group('chat merge fixtures', () {
    for (final testCase in cases) {
      final id = testCase['id']! as String;
      test(id, () {
        var snapshot = _snapshot(_object(testCase['initialAccounts']));
        final steps = (testCase['steps']! as List<Object?>).map(_object);
        for (final step in steps) {
          final before = snapshot;
          final accountId = AccountId.parse(step['accountId']);
          final account = snapshot.accounts[accountId]!;
          final roomToken = _token(step['roomToken']);
          final threadId = step['threadId'] as int?;
          final key = ChatScopeKey(roomToken: roomToken, threadId: threadId);

          ChatMergeResult result;
          try {
            result = step['kind'] == 'sync'
                ? planChatGetMerge(
                    snapshot,
                    _getResponse(step, account, fixtures, headerSets),
                  )
                : planChatReadMerge(
                    snapshot,
                    _readResponse(step, account, fixtures, headerSets),
                  );
          } on TalkProtocolException {
            expect(step['expectedOutcome'], 'rejected');
            expect(identical(snapshot, before), isTrue);
            continue;
          }

          if (step['expectedOutcome'] == 'rejected') {
            expect(result.outcome, ChatMergeOutcome.rejected);
            expect(result.plan, isNull);
            expect(identical(snapshot, before), isTrue);
            continue;
          }

          expect(result.outcome, _outcome(step['expectedOutcome']! as String));
          final plan = result.plan!;
          if (step['transaction'] == 'fail') {
            snapshot = plan.discard(snapshot);
            expect(step['expectedOutcome'], 'transaction-error');
            expect(identical(snapshot, before), isTrue);
            continue;
          }

          snapshot = plan.commit(snapshot);
          final expectedLane = step['expectedAccountLane'] == 'ready'
              ? ChatAccountLane.ready
              : ChatAccountLane.reauthenticationRequired;
          expect(snapshot.accounts[accountId]!.lane, expectedLane);
          final expectedScope = step['expectedScope'];
          if (expectedScope != null) {
            _expectScope(
              snapshot.accounts[accountId]!.scopes[key]!,
              _object(expectedScope),
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
          for (final entry in account.scopes.entries) {
            if (entry.key != key) {
              expect(
                identical(
                  snapshot.accounts[accountId]!.scopes[entry.key],
                  entry.value,
                ),
                isTrue,
              );
            }
          }
        }
      });
    }
  });

  test('merge plan is single-use and bound to its source snapshot', () {
    final snapshot = _snapshot(_object(cases.first['initialAccounts']));
    final step = _object((cases.first['steps']! as List<Object?>).first);
    final account = snapshot.accounts[AccountId.parse(step['accountId'])]!;
    final response = _getResponse(step, account, fixtures, headerSets);
    final plan = planChatGetMerge(snapshot, response).plan!;
    final committed = plan.commit(snapshot);

    expect(
      () => plan.commit(committed),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidChatMerge,
        ),
      ),
    );
  });
}

ChatGetResponse _getResponse(
  Map<String, Object?> step,
  ChatAccountState account,
  List<Map<String, Object?>> fixtures,
  Map<String, Map<String, String>> headerSets,
) {
  final fixture = fixtures.singleWhere((item) => item['id'] == step['fixture']);
  final direction = step['direction'] == 'history'
      ? ChatFetchDirection.history
      : ChatFetchDirection.future;
  final threadId = step['threadId'] as int?;
  final request = ChatFetchRequest(
    accountId: account.accountId,
    requestId: ChatRequestId.parse('merge-${step['fixture']}'),
    server: account.server,
    roomToken: _token(step['roomToken']),
    profile: ChatCapabilityProfile.fromTalkFeatures(<Object?>[
      'chat-v2',
      if (threadId != null) 'threads',
    ], federated: false),
    direction: direction,
    cursor: ChatCursor.parse(step['anchor']),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: direction == ChatFetchDirection.history,
    timeoutSeconds: 0,
    interactive: true,
    threadId: threadId,
  );
  return decodeChatGetResponse(
    request: request,
    statusCode: int.parse(fixture['status']! as String),
    body: fixture['status'] == '304'
        ? Uint8List(0)
        : _readBytes('contracts/chat-messages/fixtures/${fixture['file']}'),
    headers: ChatResponseHeaders.fromMap(_fixtureHeaders(fixture, headerSets)),
  );
}

ChatReadResponse _readResponse(
  Map<String, Object?> step,
  ChatAccountState account,
  List<Map<String, Object?>> fixtures,
  Map<String, Map<String, String>> headerSets,
) {
  final fixture = fixtures.singleWhere((item) => item['id'] == step['fixture']);
  final context = _object(fixture['context']);
  final profile = ChatCapabilityProfile.fromTalkFeatures(<Object?>[
    'chat-v2',
    'chat-read-marker',
    'chat-read-last',
    'chat-unread',
  ], federated: false);
  final roomToken = _token(step['roomToken']);
  final request = step['kind'] == 'read'
      ? ChatSetReadMarkerRequest(
          accountId: account.accountId,
          requestId: ChatRequestId.parse('merge-${step['fixture']}'),
          server: account.server,
          roomToken: roomToken,
          profile: profile,
          lastReadMessage: context['lastReadMessage']! as int,
        )
      : ChatMarkUnreadRequest(
          accountId: account.accountId,
          requestId: ChatRequestId.parse('merge-${step['fixture']}'),
          server: account.server,
          roomToken: roomToken,
          profile: profile,
        );
  return decodeChatReadResponse(
    request: request,
    statusCode: int.parse(fixture['status']! as String),
    body: _readBytes('contracts/chat-messages/fixtures/${fixture['file']}'),
    headers: ChatResponseHeaders.fromMap(_fixtureHeaders(fixture, headerSets)),
  );
}

ChatRuntimeSnapshot _snapshot(Map<String, Object?> rawAccounts) {
  final accounts = <AccountId, ChatAccountState>{};
  for (final entry in rawAccounts.entries) {
    final accountId = AccountId.parse(entry.key);
    final rawAccount = _object(entry.value);
    final scopes = <ChatScopeKey, ChatScopeState>{};
    for (final scopeEntry in _object(rawAccount['scopes']).entries) {
      final separator = scopeEntry.key.lastIndexOf('#');
      final roomToken = _token(scopeEntry.key.substring(0, separator));
      final rawThread = scopeEntry.key.substring(separator + 1);
      final key = ChatScopeKey(
        roomToken: roomToken,
        threadId: rawThread == 'root' ? null : int.parse(rawThread),
      );
      scopes[key] = _scope(_object(scopeEntry.value));
    }
    accounts[accountId] = ChatAccountState(
      accountId: accountId,
      server: ServerBase.parse('https://${entry.key}.example.invalid'),
      lane: rawAccount['laneState'] == 'ready'
          ? ChatAccountLane.ready
          : ChatAccountLane.reauthenticationRequired,
      credentialGeneration: 1,
      capabilityGeneration: 1,
      scopes: scopes,
      operations: const {},
    );
  }
  return ChatRuntimeSnapshot(accounts: accounts);
}

ChatScopeState _scope(Map<String, Object?> value) {
  return ChatScopeState(
    messageIds: (value['messageIds']! as List<Object?>).cast<int>(),
    historyCursor: ChatCursor.parse(value['historyCursor']),
    futureCursor: ChatCursor.parse(value['futureCursor']),
    lastCommonRead: ChatCursor.parse(value['lastCommonRead']),
    lastReadMessage: value['lastReadMessage']! as int,
    unreadMessages: value['unreadMessages']! as int,
    hasHistory: value['hasHistory']! as bool,
    futureConverged: value['futureConverged']! as bool,
    blocks: (value['blocks']! as List<Object?>).map((rawBlock) {
      final block = rawBlock! as List<Object?>;
      return ChatBlock(
        start: ChatCursor.parse(block[0]),
        end: ChatCursor.parse(block[1]),
      );
    }),
  );
}

void _expectScope(ChatScopeState actual, Map<String, Object?> expected) {
  expect(actual.messageIds, expected['messageIds']);
  expect(actual.historyCursor.value, expected['historyCursor']);
  expect(actual.futureCursor.value, expected['futureCursor']);
  expect(actual.lastCommonRead.value, expected['lastCommonRead']);
  expect(actual.lastReadMessage, expected['lastReadMessage']);
  expect(actual.unreadMessages, expected['unreadMessages']);
  expect(actual.hasHistory, expected['hasHistory']);
  expect(actual.futureConverged, expected['futureConverged']);
  final expectedBlocks = (expected['blocks']! as List<Object?>)
      .map((raw) => raw! as List<Object?>)
      .map((block) => <String>[block[0]! as String, block[1]! as String])
      .toList(growable: false);
  expect(
    actual.blocks
        .map((block) => <String>[block.start.value, block.end.value])
        .toList(growable: false),
    expectedBlocks,
  );
}

ChatMergeOutcome _outcome(String value) => switch (value) {
  'applied' => ChatMergeOutcome.applied,
  'common-read-updated' => ChatMergeOutcome.commonReadUpdated,
  'history-exhausted' => ChatMergeOutcome.historyExhausted,
  'converged' => ChatMergeOutcome.converged,
  'read-applied' => ChatMergeOutcome.readApplied,
  'unread-applied' => ChatMergeOutcome.unreadApplied,
  'reauth-required' => ChatMergeOutcome.reauthenticationRequired,
  'transaction-error' => ChatMergeOutcome.applied,
  _ => throw StateError('Unknown merge outcome'),
};

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
  code: TalkProtocolErrorCode.invalidChatMerge,
);

Map<String, Object?> _readObject(String relativePath) {
  return _object(
    jsonDecode(File('${_repoRoot().path}/$relativePath').readAsStringSync()),
  );
}

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
