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
  final cases = (manifest['mergeCasesFiles']! as List<Object?>)
      .expand(
        (file) =>
            (_readObject(
                      'contracts/chat-messages/fixtures/${file! as String}',
                    )['cases']!
                    as List<Object?>)
                .map(_object),
      )
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

          if (step['expectedOutcome'] == 'rejected' ||
              step['expectedOutcome'] == 'stale') {
            expect(
              result.outcome,
              step['expectedOutcome'] == 'stale'
                  ? ChatMergeOutcome.stale
                  : ChatMergeOutcome.rejected,
            );
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

  group('common read invalidation', () {
    for (final policy in <String>[
      'private privacy',
      'missing capability',
      'federated room',
    ]) {
      test('$policy clears only the bound scope marker', () {
        final snapshot = _commonReadSnapshot();
        final accountA = snapshot.accounts[AccountId.parse('account-a')]!;
        final otherRoomKey = ChatScopeKey(
          roomToken: _token('roomb123'),
          threadId: null,
        );
        final otherRoom = accountA.scopes[otherRoomKey]!;
        final accountB = snapshot.accounts[AccountId.parse('account-b')]!;
        final profile = switch (policy) {
          'private privacy' => _commonReadProfile(readPrivacy: 1),
          'missing capability' => _commonReadProfile(
            readPrivacy: 0,
            commonReadFeature: false,
          ),
          'federated room' => _commonReadProfile(
            readPrivacy: 0,
            federated: true,
          ),
          _ => throw StateError('Unknown policy'),
        };

        final result = planChatGetMerge(
          snapshot,
          _notModifiedResponse(_commonReadRequest(snapshot, profile: profile)),
        );
        final candidate = result.plan!.commit(snapshot);

        expect(result.outcome, ChatMergeOutcome.converged);
        expect(
          candidate
              .accounts[AccountId.parse('account-a')]!
              .scopes[ChatScopeKey(
                roomToken: _token('rooma123'),
                threadId: null,
              )]!
              .lastCommonRead,
          isNull,
        );
        expect(
          identical(
            candidate
                .accounts[AccountId.parse('account-a')]!
                .scopes[otherRoomKey],
            otherRoom,
          ),
          isTrue,
        );
        expect(
          identical(candidate.accounts[AccountId.parse('account-b')], accountB),
          isTrue,
        );
      });
    }

    test('public policy restores only an authoritative server marker', () {
      var snapshot = _commonReadSnapshot();
      final privateRequest = _commonReadRequest(
        snapshot,
        profile: _commonReadProfile(readPrivacy: 1),
      );
      snapshot = planChatGetMerge(
        snapshot,
        _notModifiedResponse(privateRequest),
      ).plan!.commit(snapshot);

      final publicProfile = _commonReadProfile(readPrivacy: 0);
      final markerlessRequest = _commonReadRequest(
        snapshot,
        profile: publicProfile,
      );
      snapshot = planChatGetMerge(
        snapshot,
        _notModifiedResponse(markerlessRequest),
      ).plan!.commit(snapshot);
      final key = ChatScopeKey(roomToken: _token('rooma123'), threadId: null);
      expect(
        snapshot
            .accounts[AccountId.parse('account-a')]!
            .scopes[key]!
            .lastCommonRead,
        isNull,
      );

      final authoritativeRequest = _commonReadRequest(
        snapshot,
        profile: publicProfile,
      );
      final result = planChatGetMerge(
        snapshot,
        _commonReadResponse(authoritativeRequest, marker: '95'),
      );
      snapshot = result.plan!.commit(snapshot);

      expect(result.outcome, ChatMergeOutcome.commonReadUpdated);
      expect(
        snapshot
            .accounts[AccountId.parse('account-a')]!
            .scopes[key]!
            .lastCommonRead
            ?.value,
        '95',
      );
    });
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

ChatRuntimeSnapshot _commonReadSnapshot() => _snapshot(<String, Object?>{
  'account-a': <String, Object?>{
    'laneState': 'ready',
    'scopes': <String, Object?>{
      'rooma123#root': _rawCommonReadScope('90'),
      'roomb123#root': _rawCommonReadScope('70'),
    },
  },
  'account-b': <String, Object?>{
    'laneState': 'ready',
    'scopes': <String, Object?>{'rooma123#root': _rawCommonReadScope('80')},
  },
});

Map<String, Object?> _rawCommonReadScope(String lastCommonRead) =>
    <String, Object?>{
      'messageIds': <Object?>[100],
      'historyCursor': '100',
      'futureCursor': '100',
      'lastCommonRead': lastCommonRead,
      'lastReadMessage': 90,
      'unreadMessages': 0,
      'hasHistory': true,
      'futureConverged': true,
      'blocks': <Object?>[
        <Object?>['100', '100'],
      ],
    };

ChatFetchRequest _commonReadRequest(
  ChatRuntimeSnapshot snapshot, {
  required ChatCapabilityProfile profile,
}) {
  final account = snapshot.accounts[AccountId.parse('account-a')]!;
  final roomToken = _token('rooma123');
  final scope =
      account.scopes[ChatScopeKey(roomToken: roomToken, threadId: null)]!;
  return ChatFetchRequest(
    accountId: account.accountId,
    requestId: ChatRequestId.parse('common-read-request'),
    server: account.server,
    roomToken: roomToken,
    profile: profile,
    direction: ChatFetchDirection.future,
    cursor: scope.futureCursor,
    lastCommonRead: scope.lastCommonRead ?? ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
    futureConverged: true,
  );
}

ChatGetResponse _notModifiedResponse(ChatFetchRequest request) =>
    decodeChatGetResponse(
      request: request,
      statusCode: 304,
      body: Uint8List(0),
    );

ChatGetResponse _commonReadResponse(
  ChatFetchRequest request, {
  required String marker,
}) => decodeChatGetResponse(
  request: request,
  statusCode: 200,
  body: Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': <Object?>[],
        },
      }),
    ),
  ),
  headers: ChatResponseHeaders.fromMap(<String, String>{
    'X-Chat-Last-Common-Read': marker,
  }),
);

ChatCapabilityProfile _commonReadProfile({
  required int readPrivacy,
  bool commonReadFeature = true,
  bool federated = false,
  bool threads = false,
}) => ChatCapabilityProfile.fromSnapshot(
  CapabilitySnapshot.fromJson(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'version': <String, Object?>{
          'major': 34,
          'minor': 0,
          'micro': 1,
          'string': '34.0.1',
          'edition': '',
          'extendedSupport': false,
        },
        'capabilities': <String, Object?>{
          'spreed': <String, Object?>{
            'features': <Object?>[
              'chat-v2',
              if (commonReadFeature) 'chat-read-status',
              if (threads) 'threads',
            ],
            'config': <String, Object?>{
              'chat': <String, Object?>{'read-privacy': readPrivacy},
            },
            'version': '24.0.2',
          },
        },
      },
    },
  }, context: CapabilityContext.authenticated),
  federated: federated,
);

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
    profile: _commonReadProfile(readPrivacy: 0, threads: threadId != null),
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
  expect(actual.lastCommonRead?.value, expected['lastCommonRead']);
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
