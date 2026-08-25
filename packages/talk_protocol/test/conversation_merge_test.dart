import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final manifest = _readJsonObject(
    'contracts/conversation-list/fixtures/manifest.json',
  );
  final fixtureMetadata = <String, Map<String, Object?>>{
    for (final fixture in (manifest['fixtures']! as List<Object?>).map(
      _asObject,
    ))
      fixture['file']! as String: fixture,
  };
  final headerSets = _asObject(
    manifest['headerSets'],
  ).map((key, value) => MapEntry(key, _stringMap(value)));
  final cases =
      (_readJsonObject(
                'contracts/conversation-list/fixtures/merge.cases.json',
              )['cases']!
              as List<Object?>)
          .map(_asObject)
          .toList(growable: false);
  final compactRoomTemplate = _compactRoomTemplate();

  test('covers all executable merge scenarios', () {
    expect(cases, hasLength(14));
    expect(
      cases.fold<int>(
        0,
        (count, testCase) =>
            count + (testCase['steps']! as List<Object?>).length,
      ),
      19,
    );
  });

  group('conversation merge fixtures', () {
    for (final testCase in cases) {
      final id = testCase['id']! as String;
      test(id, () {
        var snapshot = _initialSnapshot(
          _asObject(testCase['initialAccounts']),
          compactRoomTemplate,
        );
        for (final step in (testCase['steps']! as List<Object?>).map(
          _asObject,
        )) {
          final accountId = AccountId.parse(step['accountId']);
          final before = snapshot;
          final current = snapshot.accounts[accountId]!;
          final otherAccounts = <AccountId, ConversationAccountState>{
            for (final entry in before.accounts.entries)
              if (entry.key != accountId) entry.key: entry.value,
          };
          final fixtureName = step['fixture']! as String;
          final fixture = fixtureMetadata[fixtureName]!;
          final mode = switch (step['mode']) {
            'full' => ConversationFetchMode.full,
            'incremental' => ConversationFetchMode.incremental,
            _ => throw StateError('Unknown merge mode'),
          };
          final request = ConversationListRequest(
            accountId: accountId,
            requestId: ConversationRequestId.parse(step['requestId']),
            server: current.server,
            mode: mode,
            includeLastMessage: false,
            cursor: mode == ConversationFetchMode.incremental
                ? current.cursor
                : null,
          );

          ConversationListResponse response;
          try {
            response = decodeConversationListResponse(
              request: request,
              statusCode: int.parse(fixture['status']! as String),
              json: _readJson(
                'contracts/conversation-list/fixtures/$fixtureName',
              ),
              headers: headerSets[step['headerSet']]!,
            );
          } on TalkProtocolException {
            expect(step['expectedOutcome'], 'rejected');
            expect(identical(snapshot, before), isTrue);
            _expectAccount(snapshot.accounts[accountId]!, step);
            continue;
          }

          if (response is! ConversationListSuccess) {
            expect(step['expectedOutcome'], 'rejected');
            expect(identical(snapshot, before), isTrue);
            _expectAccount(snapshot.accounts[accountId]!, step);
            continue;
          }

          final rawObservedAt = step['observedAt'];
          final plan = const ConversationMergePlanner().plan(
            snapshot: snapshot,
            response: response,
            observedAt: rawObservedAt == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    (rawObservedAt as int) * 1000,
                    isUtc: true,
                  ),
          );

          if (step['transaction'] == 'fail') {
            expect(step['expectedOutcome'], 'transaction-error');
            expect(plan.nextAccountState.cursor, isNot(current.cursor));
            expect(identical(snapshot, before), isTrue);
          } else {
            expect(step['transaction'], 'commit');
            snapshot = snapshot.apply(plan);
            expect(
              plan.outcome,
              step['expectedOutcome'] == 'applied'
                  ? ConversationMergeOutcome.applied
                  : ConversationMergeOutcome.confirmationRequired,
            );
          }

          _expectAccount(snapshot.accounts[accountId]!, step);
          for (final entry in otherAccounts.entries) {
            expect(
              identical(snapshot.accounts[entry.key], entry.value),
              isTrue,
            );
          }
        }
      });
    }
  });

  test('a plan cannot be applied twice after its account state changed', () {
    final accountId = AccountId.parse('account-a');
    final server = _serverForAccount(accountId);
    final snapshot = ConversationSnapshot(
      accounts: <AccountId, ConversationAccountState>{
        accountId: ConversationAccountState(
          server: server,
          rooms: <ConversationRoom>[
            _cachedRoom('stale999', compactRoomTemplate),
          ],
          cursor: ConversationCursor.parse('100'),
          configurationHash: ConversationConfigurationHash.parse(
            'fixture-hash-a',
          ),
        ),
      },
    );
    final request = ConversationListRequest(
      accountId: accountId,
      requestId: ConversationRequestId.parse('single-use-plan'),
      server: server,
      mode: ConversationFetchMode.full,
      includeLastMessage: false,
    );
    final response =
        decodeConversationListResponse(
              request: request,
              statusCode: 200,
              json: _readJson(
                'contracts/conversation-list/fixtures/'
                'conversations-compact.response.json',
              ),
              headers: headerSets['compact']!,
            )
            as ConversationListSuccess;
    final plan = const ConversationMergePlanner().plan(
      snapshot: snapshot,
      response: response,
    );
    expect(plan.upserts.map((room) => room.token.value), <String>['roomc789']);
    expect(plan.deleteTokens.map((token) => token.value), <String>{'stale999'});
    final updated = snapshot.apply(plan);

    expect(
      () => updated.apply(plan),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationMerge,
        ),
      ),
    );
  });

  test('rejects an incremental response planned from a stale cursor', () {
    final accountId = AccountId.parse('account-a');
    final server = _serverForAccount(accountId);
    final snapshot = ConversationSnapshot(
      accounts: <AccountId, ConversationAccountState>{
        accountId: ConversationAccountState(
          server: server,
          rooms: <ConversationRoom>[
            _cachedRoom('stale999', compactRoomTemplate),
          ],
          cursor: ConversationCursor.parse('101'),
          configurationHash: ConversationConfigurationHash.parse(
            'fixture-hash-a',
          ),
        ),
      },
    );
    final request = ConversationListRequest(
      accountId: accountId,
      requestId: ConversationRequestId.parse('stale-cursor'),
      server: server,
      mode: ConversationFetchMode.incremental,
      includeLastMessage: false,
      cursor: ConversationCursor.parse('100'),
    );
    final response =
        decodeConversationListResponse(
              request: request,
              statusCode: 200,
              json: _readJson(
                'contracts/conversation-list/fixtures/'
                'conversations-incremental.response.json',
              ),
              headers: headerSets['incremental']!,
            )
            as ConversationListSuccess;

    expect(
      () => const ConversationMergePlanner().plan(
        snapshot: snapshot,
        response: response,
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationMerge,
        ),
      ),
    );
  });

  test('rejects a conversation response originating from another account', () {
    final accountA = AccountId.parse('account-a');
    final accountB = AccountId.parse('account-b');
    final requestFromAccountB = ConversationListRequest(
      accountId: accountB,
      requestId: ConversationRequestId.parse('request-from-account-b'),
      server: _serverForAccount(accountB),
      mode: ConversationFetchMode.full,
      includeLastMessage: false,
    );
    final responseFromAccountB =
        decodeConversationListResponse(
              request: requestFromAccountB,
              statusCode: 200,
              json: _readJson(
                'contracts/conversation-list/fixtures/'
                'conversations-compact.response.json',
              ),
              headers: headerSets['compact']!,
            )
            as ConversationListSuccess;
    final snapshot = ConversationSnapshot(
      accounts: <AccountId, ConversationAccountState>{
        accountA: ConversationAccountState(
          server: _serverForAccount(accountA),
          rooms: const <ConversationRoom>[],
        ),
      },
    );

    expect(
      () => const ConversationMergePlanner().plan(
        snapshot: snapshot,
        response: responseFromAccountB,
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationMerge,
        ),
      ),
    );
  });

  test('rejects a response bound to another server origin', () {
    final accountId = AccountId.parse('account-a');
    final expectedServer = _serverForAccount(accountId);
    final requestFromOtherServer = ConversationListRequest(
      accountId: accountId,
      requestId: ConversationRequestId.parse('request-from-other-server'),
      server: ServerBase.parse('https://other.example.invalid'),
      mode: ConversationFetchMode.full,
      includeLastMessage: false,
    );
    final responseFromOtherServer =
        decodeConversationListResponse(
              request: requestFromOtherServer,
              statusCode: 200,
              json: _readJson(
                'contracts/conversation-list/fixtures/'
                'conversations-compact.response.json',
              ),
              headers: headerSets['compact']!,
            )
            as ConversationListSuccess;
    final snapshot = ConversationSnapshot(
      accounts: <AccountId, ConversationAccountState>{
        accountId: ConversationAccountState(
          server: expectedServer,
          rooms: const <ConversationRoom>[],
        ),
      },
    );

    expect(
      () => const ConversationMergePlanner().plan(
        snapshot: snapshot,
        response: responseFromOtherServer,
      ),
      throwsA(
        isA<TalkProtocolException>()
            .having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidConversationMerge,
            )
            .having((error) => error.path, 'path', r'$.server'),
      ),
    );
  });

  group('user status merge evidence', () {
    final accountId = AccountId.parse('account-a');
    final server = _serverForAccount(accountId);

    ConversationRoom previousRoom() {
      final json = _cloneRoom(compactRoomTemplate)
        ..['token'] = 'roomc789'
        ..['type'] = 1
        ..['status'] = 'online'
        ..['statusClearAt'] = 1770000120
        ..['statusIcon'] = '🟢'
        ..['statusMessage'] = 'Available';
      return ConversationRoom.fromJson(json);
    }

    ConversationSnapshot snapshot() => ConversationSnapshot(
      accounts: <AccountId, ConversationAccountState>{
        accountId: ConversationAccountState(
          server: server,
          rooms: <ConversationRoom>[previousRoom()],
          cursor: ConversationCursor.parse('100'),
          configurationHash: ConversationConfigurationHash.parse(
            'fixture-hash-a',
          ),
        ),
      },
    );

    ConversationListRequest request(ConversationFetchMode mode) =>
        ConversationListRequest(
          accountId: accountId,
          requestId: ConversationRequestId.parse('presence-${mode.name}'),
          server: server,
          mode: mode,
          includeLastMessage: false,
          includeStatus: true,
          cursor: mode == ConversationFetchMode.incremental
              ? ConversationCursor.parse('100')
              : null,
        );

    test('incremental absence preserves the previous status quartet', () {
      final delta = _cloneRoom(compactRoomTemplate)
        ..['token'] = 'roomc789'
        ..['type'] = 1;
      final response = _presenceResponse(
        request: request(ConversationFetchMode.incremental),
        room: delta,
        headers: headerSets['incremental']!,
      );

      final plan = const ConversationMergePlanner().plan(
        snapshot: snapshot(),
        response: response,
      );
      final room = plan.upserts.single;

      expect(room.status, 'online');
      expect(room.statusClearAt, 1770000120);
      expect(room.statusIcon, '🟢');
      expect(room.statusMessage, 'Available');
      expect(room.wire['status'], 'online');
      expect(
        plan.nextAccountState.rooms[room.token]!.wire,
        equals(room.wire),
      );
    });

    for (final explicitStatus in const <String>['', 'offline']) {
      test('incremental explicit "$explicitStatus" replaces status', () {
        final delta = _cloneRoom(compactRoomTemplate)
          ..['token'] = 'roomc789'
          ..['type'] = 1
          ..['status'] = explicitStatus
          ..['statusClearAt'] = null
          ..['statusIcon'] = null
          ..['statusMessage'] = null;
        final response = _presenceResponse(
          request: request(ConversationFetchMode.incremental),
          room: delta,
          headers: headerSets['incremental']!,
        );

        final plan = const ConversationMergePlanner().plan(
          snapshot: snapshot(),
          response: response,
        );
        final room = plan.upserts.single;

        expect(room.status, explicitStatus);
        expect(room.statusClearAt, isNull);
        expect(room.statusIcon, isNull);
        expect(room.statusMessage, isNull);
        expect(room.wire.containsKey('status'), isTrue);
      });
    }

    test('explicit null status is rejected by the v4 wire contract', () {
      final delta = _cloneRoom(compactRoomTemplate)
        ..['token'] = 'roomc789'
        ..['type'] = 1
        ..['status'] = null;

      expect(
        () => _presenceResponse(
          request: request(ConversationFetchMode.incremental),
          room: delta,
          headers: headerSets['incremental']!,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidConversationResponse,
          ),
        ),
      );
    });

    test('full response without status authoritatively clears it', () {
      final full = _cloneRoom(compactRoomTemplate)
        ..['token'] = 'roomc789'
        ..['type'] = 1;
      final response = _presenceResponse(
        request: request(ConversationFetchMode.full),
        room: full,
        headers: headerSets['full']!,
      );

      final plan = const ConversationMergePlanner().plan(
        snapshot: snapshot(),
        response: response,
      );
      final room = plan.upserts.single;

      expect(room.status, isNull);
      expect(room.hasUserStatusWire, isFalse);
      expect(room.wire.containsKey('statusMessage'), isFalse);
      expect(plan.nextAccountState.rooms[room.token]!.status, isNull);
    });
  });
}

ConversationListSuccess _presenceResponse({
  required ConversationListRequest request,
  required Map<String, Object?> room,
  required Map<String, String> headers,
}) {
  return decodeConversationListResponse(
        request: request,
        statusCode: 200,
        json: <String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'ok',
              'statuscode': 200,
              'message': 'OK',
            },
            'data': <Object?>[room],
          },
        },
        headers: headers,
      )
      as ConversationListSuccess;
}

Map<String, Object?> _cloneRoom(Map<String, Object?> room) {
  return _asObject(jsonDecode(jsonEncode(room)));
}

ConversationSnapshot _initialSnapshot(
  Map<String, Object?> rawAccounts,
  Map<String, Object?> compactRoomTemplate,
) {
  final accounts = <AccountId, ConversationAccountState>{};
  for (final entry in rawAccounts.entries) {
    final accountId = AccountId.parse(entry.key);
    final rawAccount = _asObject(entry.value);
    final rawCursor = rawAccount['cursor'];
    final rawHash = rawAccount['configurationHash'];
    accounts[accountId] = ConversationAccountState(
      server: _serverForAccount(accountId),
      rooms: (rawAccount['roomTokens']! as List<Object?>).cast<String>().map(
        (token) => _cachedRoom(token, compactRoomTemplate),
      ),
      cursor: rawCursor == null
          ? null
          : ConversationCursor.parse(
              rawCursor,
              code: TalkProtocolErrorCode.invalidConversationMerge,
            ),
      configurationHash: rawHash == null
          ? null
          : ConversationConfigurationHash.parse(
              rawHash,
              code: TalkProtocolErrorCode.invalidConversationMerge,
            ),
    );
  }
  return ConversationSnapshot(accounts: accounts);
}

ServerBase _serverForAccount(AccountId accountId) {
  return ServerBase.parse('https://${accountId.value}.example.invalid');
}

ConversationRoom _cachedRoom(
  String token,
  Map<String, Object?> compactRoomTemplate,
) {
  final clone = _asObject(jsonDecode(jsonEncode(compactRoomTemplate)));
  clone['token'] = token;
  clone.remove('lastMessage');
  return ConversationRoom.fromJson(clone);
}

Map<String, Object?> _compactRoomTemplate() {
  final root = _readJsonObject(
    'contracts/conversation-list/fixtures/'
    'conversations-compact.response.json',
  );
  final ocs = _asObject(root['ocs']);
  return _asObject((ocs['data']! as List<Object?>).single);
}

void _expectAccount(
  ConversationAccountState account,
  Map<String, Object?> step,
) {
  final expected = _asObject(step['expectedAccount']);
  final actualTokens = account.rooms.keys.map((token) => token.value).toList()
    ..sort();
  expect(
    actualTokens,
    (expected['roomTokens']! as List<Object?>).cast<String>(),
  );
  expect(account.cursor?.value, expected['cursor']);
  expect(account.configurationHash?.value, expected['configurationHash']);
  expect(
    account.emptyConfirmation?.requestId.value,
    expected['emptyConfirmationRequestId'],
  );
  expect(
    account.capabilityRefreshRequired,
    expected['capabilityRefreshRequired'],
  );
}

Object? _readJson(String relativePath) {
  final file = File('${_repoRoot().path}/$relativePath');
  return jsonDecode(file.readAsStringSync());
}

Map<String, Object?> _readJsonObject(String relativePath) {
  return _asObject(_readJson(relativePath));
}

Map<String, Object?> _asObject(Object? value) {
  return (value! as Map<Object?, Object?>).cast<String, Object?>();
}

Map<String, String> _stringMap(Object? value) {
  return (value! as Map<Object?, Object?>).cast<String, String>();
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/conversation-list/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
