import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// Legacy `conversation-v4` servers (Talk v15) advertise the feature but their
/// `getRooms()` has no `modifiedSince` support, so they may answer without the
/// cursor and hash headers. A full fetch must accept that response as a plain
/// snapshot instead of failing, while incremental fetches stay strict.
void main() {
  const noHeaders = <String, String>{};
  const hashOnlyHeaders = <String, String>{
    'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
  };

  group('legacy snapshot response', () {
    test('a full fetch decodes rooms without cursor and hash', () {
      final response =
          _decode(requestId: 'legacy-without-headers', headers: noHeaders)
              as ConversationListSuccess;

      expect(response.rooms.length, 2);
      expect(response.cursor, isNull);
      expect(response.configurationHash, isNull);
      expect(response.federationInvites, isNull);
    });

    test('a full fetch keeps a hash-only response usable', () {
      final response =
          _decode(requestId: 'legacy-hash-only', headers: hashOnlyHeaders)
              as ConversationListSuccess;

      expect(response.cursor, isNull);
      expect(response.configurationHash?.value, 'fixture-hash-a');
    });

    test('an incremental fetch still requires the cursor profile', () {
      expect(
        () => _decode(
          requestId: 'incremental-without-headers',
          headers: noHeaders,
          cursor: ConversationCursor.parse('1724300001'),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidConversationHeaders,
          ),
        ),
      );
    });

    test('a malformed cursor stays rejected', () {
      expect(
        () => _decode(
          requestId: 'legacy-malformed-cursor',
          headers: const <String, String>{
            'X-Nextcloud-Talk-Modified-Before': '01724300001',
          },
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidConversationHeaders,
          ),
        ),
      );
    });
  });

  group('legacy snapshot merge', () {
    test('replaces the cache and clears the stored cursor', () {
      final accountId = AccountId.parse('legacy-account');
      final current = _state(accountId: accountId);
      expect(current.cursor, isNotNull);
      final response =
          _decode(
                requestId: 'legacy-merge',
                headers: noHeaders,
                accountId: accountId,
              )
              as ConversationListSuccess;

      final plan = const ConversationMergePlanner().plan(
        snapshot: ConversationSnapshot(accounts: {accountId: current}),
        response: response,
        observedAt: DateTime.utc(2026, 8, 28),
      );

      expect(plan.outcome, ConversationMergeOutcome.applied);
      expect(plan.upserts.map((room) => room.token.value), <String>[
        'rooma123',
        'roomb456',
      ]);
      expect(plan.deleteTokens.map((token) => token.value), <String>{
        'roomc789',
      });
      final next = plan.nextAccountState;
      expect(
        next.cursor,
        isNull,
        reason: 'a snapshot without a cursor may not fake incremental progress',
      );
      expect(next.configurationHash?.value, 'fixture-hash-a');
      expect(next.capabilityRefreshRequired, isFalse);

      // Callers pick the fetch mode from the stored cursor, so the next fetch
      // stays full; an incremental request cannot even be built.
      expect(
        () => _request(
          requestId: 'legacy-next',
          accountId: accountId,
          cursor: next.cursor,
          mode: ConversationFetchMode.incremental,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidConversationRequest,
          ),
        ),
      );
    });

    test('still detects a changed configuration hash', () {
      final accountId = AccountId.parse('legacy-account');
      final current = _state(accountId: accountId);
      final response =
          _decode(
                requestId: 'legacy-hash-change',
                headers: const <String, String>{
                  'X-Nextcloud-Talk-Hash': 'fixture-hash-b',
                },
                accountId: accountId,
              )
              as ConversationListSuccess;

      final plan = const ConversationMergePlanner().plan(
        snapshot: ConversationSnapshot(accounts: {accountId: current}),
        response: response,
        observedAt: DateTime.utc(2026, 8, 28),
      );

      expect(plan.nextAccountState.capabilityRefreshRequired, isTrue);
      expect(plan.nextAccountState.configurationHash?.value, 'fixture-hash-b');
    });

    test('a snapshot without a hash keeps the stored one', () {
      final accountId = AccountId.parse('legacy-account');
      final current = _state(accountId: accountId);
      final response =
          _decode(
                requestId: 'legacy-without-hash',
                headers: noHeaders,
                accountId: accountId,
              )
              as ConversationListSuccess;

      final plan = const ConversationMergePlanner().plan(
        snapshot: ConversationSnapshot(accounts: {accountId: current}),
        response: response,
        observedAt: DateTime.utc(2026, 8, 28),
      );

      expect(plan.nextAccountState.configurationHash, current.configurationHash);
      expect(plan.nextAccountState.capabilityRefreshRequired, isFalse);
    });
  });

  group('legacy snapshot profile', () {
    test('a snapshot probe does not activate the cursor profile', () {
      final profile = _profile(headers: hashOnlyHeaders);

      expect(profile.status, ConversationProfileStatus.unsupportedWireProfile);
      expect(profile.candidatePath, conversationV4Path);
      expect(profile.activePath, isNull);
      expect(profile.isActive, isFalse);
    });

    test('both headers still activate the cursor profile', () {
      final profile = _profile(
        headers: const <String, String>{
          'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
          'X-Nextcloud-Talk-Modified-Before': '1724300001',
        },
      );

      expect(profile.status, ConversationProfileStatus.cursorV4);
      expect(profile.activePath, conversationV4Path);
    });
  });
}

ConversationListRequest _request({
  required String requestId,
  AccountId? accountId,
  ConversationFetchMode mode = ConversationFetchMode.full,
  ConversationCursor? cursor,
}) {
  return ConversationListRequest(
    accountId: accountId ?? AccountId.parse('legacy-account'),
    requestId: ConversationRequestId.parse(requestId),
    server: ServerBase.parse('https://cloud.example.invalid'),
    mode: mode,
    includeLastMessage: true,
    cursor: cursor,
  );
}

ConversationListResponse _decode({
  required String requestId,
  required Map<String, String> headers,
  AccountId? accountId,
  ConversationCursor? cursor,
  String fixture = 'conversations-full.response.json',
}) {
  return decodeConversationListResponse(
    request: _request(
      requestId: requestId,
      accountId: accountId,
      mode: cursor == null
          ? ConversationFetchMode.full
          : ConversationFetchMode.incremental,
      cursor: cursor,
    ),
    statusCode: 200,
    json: _readJson('contracts/conversation-list/fixtures/$fixture'),
    headers: headers,
  );
}

ConversationProfile _profile({required Map<String, String> headers}) {
  return resolveConversationProfile(
    capabilities: CapabilitySnapshot.fromJson(
      _capabilityEnvelope(),
      context: CapabilityContext.authenticated,
    ),
    probe: ConversationProfileProbe(
      request: _request(requestId: 'legacy-probe'),
      statusCode: 200,
      json: _readJson(
        'contracts/conversation-list/fixtures/conversations-full.response.json',
      ),
      headers: headers,
    ),
  );
}

/// Cache of an account that previously synced through the cursor-v4 profile.
ConversationAccountState _state({required AccountId accountId}) {
  final seeded =
      _decode(
            requestId: 'legacy-seed',
            headers: const <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
              'X-Nextcloud-Talk-Modified-Before': '1724300201',
            },
            accountId: accountId,
            fixture: 'conversations-compact.response.json',
          )
          as ConversationListSuccess;

  return ConversationAccountState(
    server: ServerBase.parse('https://cloud.example.invalid'),
    rooms: seeded.rooms,
    cursor: seeded.cursor,
    configurationHash: seeded.configurationHash,
  );
}

Map<String, Object?> _capabilityEnvelope() {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'version': <String, Object?>{
          'major': 15,
          'minor': 0,
          'micro': 8,
          'string': '15.0.8',
          'edition': '',
        },
        'capabilities': <String, Object?>{
          'spreed': <String, Object?>{
            'features': <Object?>['conversation-v4'],
          },
        },
      },
    },
  };
}

Object? _readJson(String relativePath) {
  return jsonDecode(
    File('${_repoRoot().path}/$relativePath').readAsStringSync(),
  );
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
