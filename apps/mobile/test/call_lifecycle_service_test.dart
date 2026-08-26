import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/call_session_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test(
    'persists every mutation before dispatch and completes the lifecycle',
    () async {
      late _CallHarness harness;
      harness = await _CallHarness.create(
        onCall: (request, _) async {
          final row = await harness.database
              .select(harness.database.callLifecycleSessions)
              .getSingle();
          expect(row.phase, switch (request.method) {
            'POST' => CallLifecyclePhase.joining.name,
            'PUT' => CallLifecyclePhase.updating.name,
            'DELETE' => CallLifecyclePhase.leaving.name,
            _ => fail('Unexpected mutation ${request.method}'),
          });
          return _ocsResponse(200, <String, Object?>{});
        },
      );
      addTearDown(harness.dispose);

      final joined = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(joined.phase, CallLifecyclePhase.joined);
      expect(joined.confirmedFlags, CallInCallFlags.audioVideo());

      final updated = await harness.service.updateFlags(
        accountId: 'account-a',
        roomToken: 'rooma123',
        flags: CallInCallFlags.parse(3, requireJoined: true),
      );
      expect(updated.phase, CallLifecyclePhase.joined);
      expect(updated.confirmedFlags!.value, 3);

      await harness.service.leave(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(
        await harness.database
            .select(harness.database.callLifecycleSessions)
            .get(),
        isEmpty,
      );
      expect(harness.server.callMethods, <String>['POST', 'PUT', 'DELETE']);
    },
  );

  test(
    'reloads the conversation policy after refreshing its session',
    () async {
      late _CallHarness harness;
      harness = await _CallHarness.create(
        initialPermissions: 0,
        refresh: (accountId, roomToken) async {
          await harness.seedRoom(token: roomToken, permissions: 255);
          return ConversationSessionId.parse('session-$roomToken');
        },
      );
      addTearDown(harness.dispose);

      final state = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(state.phase, CallLifecyclePhase.joined);
      expect(harness.server.callMethods, <String>['POST']);
    },
  );

  test('rejects a room snapshot that drifted after session refresh', () async {
    final harness = await _CallHarness.create(
      refresh: (_, _) async => ConversationSessionId.parse('stale-session'),
      onCall: (_, _) async => _ocsResponse(200, <Object?>[]),
    );
    addTearDown(harness.dispose);

    await expectLater(
      harness.service.status(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.invalidResponse),
    );
    expect(harness.server.callMethods, isEmpty);
  });

  test('recovers an ambiguous join by GET without repeating POST', () async {
    final harness = await _CallHarness.create(
      onCall: (request, index) async {
        if (index == 0) {
          throw http.ClientException('synthetic disconnect');
        }
        expect(request.method, 'GET');
        return _ocsResponse(200, <Object?>[
          _peer(token: 'rooma123', sessionId: 'session-rooma123'),
        ]);
      },
    );
    addTearDown(harness.dispose);

    await expectLater(
      harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.uncertain),
    );
    expect(
      (await harness.database
              .select(harness.database.callLifecycleSessions)
              .getSingle())
          .phase,
      CallLifecyclePhase.uncertainJoin.name,
    );

    final recovered = await harness.newService().recover(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(recovered!.phase, CallLifecyclePhase.joined);
    expect(harness.server.callMethods, <String>['POST', 'GET']);
  });

  test(
    'recoverStatus reuses its recovery GET for the visible snapshot',
    () async {
      final harness = await _CallHarness.create(
        onCall: (request, _) async {
          expect(request.method, 'GET');
          return _ocsResponse(200, <Object?>[]);
        },
      );
      addTearDown(harness.dispose);

      final status = await harness.service.recoverStatus(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(status.ownSessionPresent, isFalse);
      expect(status.peers, isEmpty);
      expect(status.state, isNull);
      expect(harness.server.callMethods, <String>['GET']);
    },
  );

  test(
    'recoverStatus refreshes peers after retrying an uncertain leave',
    () async {
      final harness = await _CallHarness.create(
        onCall: (request, index) async {
          if (request.method == 'GET' && index == 1) {
            return _ocsResponse(200, <Object?>[
              _peer(token: 'rooma123', sessionId: 'session-rooma123'),
            ]);
          }
          if (request.method == 'GET') {
            return _ocsResponse(200, <Object?>[]);
          }
          return _ocsResponse(200, <String, Object?>{});
        },
      );
      addTearDown(harness.dispose);
      final joined = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      await harness.sessions.persist(
        joined
            .beginLeave(
              endForEveryone: false,
              updatedAt: DateTime.utc(2026, 8, 26, 12, 1),
            )
            .markUncertain(updatedAt: DateTime.utc(2026, 8, 26, 12, 1, 1)),
      );

      final status = await harness.newService().recoverStatus(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(status.ownSessionPresent, isFalse);
      expect(status.state, isNull);
      expect(harness.server.callMethods, <String>[
        'POST',
        'GET',
        'DELETE',
        'GET',
      ]);
    },
  );

  test('session refresh reauthentication purges durable call state', () async {
    final harness = await _CallHarness.create();
    addTearDown(harness.dispose);
    await harness.service.join(accountId: 'account-a', roomToken: 'rooma123');
    final service = CallLifecycleService(
      accounts: harness.accounts,
      chat: harness.chat,
      sessions: harness.sessions,
      credentials: harness.credentials,
      api: harness.api,
      refreshConversationSession: (_, _) async =>
          throw const CallLifecycleException(
            CallLifecycleError.reauthenticationRequired,
          ),
      now: _now,
    );

    await expectLater(
      service.recoverStatus(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.reauthenticationRequired),
    );

    expect(
      await harness.database
          .select(harness.database.callLifecycleSessions)
          .get(),
      isEmpty,
    );
    expect(
      (await harness.database
              .select(harness.database.chatCapabilities)
              .getSingle())
          .lane,
      ChatAccountLane.reauthenticationRequired.name,
    );
  });

  test(
    'restart keeps an in-flight update uncertain and never repeats PUT',
    () async {
      final harness = await _CallHarness.create(
        onCall: (request, _) async {
          if (request.method == 'GET') {
            return _ocsResponse(200, <Object?>[
              _peer(token: 'rooma123', sessionId: 'session-rooma123'),
            ]);
          }
          return _ocsResponse(200, <String, Object?>{});
        },
      );
      addTearDown(harness.dispose);

      final joined = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      await harness.sessions.persist(
        joined.beginUpdate(
          flags: CallInCallFlags.parse(3, requireJoined: true),
          updatedAt: DateTime.utc(2026, 8, 26, 12, 1),
        ),
      );

      final recovered = await harness.newService().recover(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(recovered!.phase, CallLifecyclePhase.uncertainUpdate);
      await expectLater(
        harness.service.updateFlags(
          accountId: 'account-a',
          roomToken: 'rooma123',
          flags: CallInCallFlags.audioVideo(),
        ),
        _lifecycleFailure(CallLifecycleError.uncertain),
      );
      expect(
        harness.server.callMethods.where((method) => method == 'PUT'),
        isEmpty,
      );
    },
  );

  test('ambiguous leave performs GET before its single safe retry', () async {
    final harness = await _CallHarness.create(
      onCall: (request, index) async {
        if (request.method == 'DELETE' && index == 1) {
          return _ocsResponse(503, <String, Object?>{});
        }
        if (request.method == 'GET') {
          return _ocsResponse(200, <Object?>[
            _peer(token: 'rooma123', sessionId: 'session-rooma123'),
          ]);
        }
        return _ocsResponse(200, <String, Object?>{});
      },
    );
    addTearDown(harness.dispose);
    await harness.service.join(accountId: 'account-a', roomToken: 'rooma123');

    await expectLater(
      harness.service.leave(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.uncertain),
    );
    await harness.service.leave(accountId: 'account-a', roomToken: 'rooma123');

    expect(harness.server.callMethods, <String>[
      'POST',
      'DELETE',
      'GET',
      'DELETE',
    ]);
    expect(
      await harness.database
          .select(harness.database.callLifecycleSessions)
          .get(),
      isEmpty,
    );
  });

  test('maps deterministic call failures and Talk recording consent', () async {
    final cases = <int, CallLifecycleError>{
      401: CallLifecycleError.reauthenticationRequired,
      403: CallLifecycleError.forbidden,
      404: CallLifecycleError.roomMissing,
      409: CallLifecycleError.conflict,
      429: CallLifecycleError.rateLimited,
    };
    for (final entry in cases.entries) {
      final harness = await _CallHarness.create(
        onCall: (_, _) async => _ocsResponse(entry.key, <String, Object?>{}),
      );
      try {
        await expectLater(
          harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
          _lifecycleFailure(entry.value),
          reason: '${entry.key}',
        );
      } finally {
        await harness.dispose();
      }
    }

    final consent = await _CallHarness.create(
      onCall: (_, _) async => _ocsFailure(400, 'consent'),
    );
    try {
      await expectLater(
        consent.service.join(accountId: 'account-a', roomToken: 'rooma123'),
        _lifecycleFailure(CallLifecycleError.consentRequired),
      );
    } finally {
      await consent.dispose();
    }
  });

  test(
    'purges persisted lifecycle state after capability authority drift',
    () async {
      final harness = await _CallHarness.create();
      addTearDown(harness.dispose);
      await harness.service.join(accountId: 'account-a', roomToken: 'rooma123');
      harness.server.extraFeature = true;

      final recovered = await harness.newService().recover(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(recovered, isNull);
      expect(harness.server.callMethods, <String>['POST']);
      expect(
        await harness.database
            .select(harness.database.callLifecycleSessions)
            .get(),
        isEmpty,
      );
    },
  );

  test('serializes one room while allowing another room to progress', () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondRoomStarted = Completer<void>();
    final harness = await _CallHarness.create(
      onCall: (request, _) async {
        if (request.url.path.endsWith('/rooma123')) {
          firstStarted.complete();
          await releaseFirst.future;
        } else if (request.url.path.endsWith('/roomb123')) {
          secondRoomStarted.complete();
        }
        return _ocsResponse(200, <String, Object?>{});
      },
    );
    addTearDown(harness.dispose);
    await harness.seedRoom(token: 'roomb123');

    final first = harness.service.join(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await firstStarted.future;
    final sameRoom = harness.service.join(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final otherRoom = harness.service.join(
      accountId: 'account-a',
      roomToken: 'roomb123',
    );
    await secondRoomStarted.future.timeout(const Duration(seconds: 2));
    await otherRoom;
    expect(
      harness.server.callRequests.where(
        (request) => request.url.path.endsWith('/rooma123'),
      ),
      hasLength(1),
    );

    releaseFirst.complete();
    await Future.wait(<Future<CallLifecycleState>>[first, sameRoom]);
    expect(harness.server.callMethods, <String>['POST', 'POST']);
  });
}

final class _CallHarness {
  _CallHarness({
    required this.database,
    required this.accounts,
    required this.chat,
    required this.sessions,
    required this.credentials,
    required this.api,
    required this.server,
    required this.refresh,
  }) : service = CallLifecycleService(
         accounts: accounts,
         chat: chat,
         sessions: sessions,
         credentials: credentials,
         api: api,
         refreshConversationSession: refresh,
         now: _now,
       );

  static Future<_CallHarness> create({
    _CallHandler? onCall,
    CallConversationSessionRefresh? refresh,
    int initialPermissions = 255,
  }) async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final chat = ChatRepository(database);
    final sessions = CallLifecycleSessionRepository(database);
    final credentials = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 8, 26),
    );
    credentials.values['account-a'] = 'fixture-password';
    final server = _CallServer(onCall: onCall);
    final api = HttpNextcloudApi(client: server.client, clock: _now);
    final resolvedRefresh =
        refresh ??
        (_, roomToken) async =>
            ConversationSessionId.parse('session-$roomToken');
    final harness = _CallHarness(
      database: database,
      accounts: accounts,
      chat: chat,
      sessions: sessions,
      credentials: credentials,
      api: api,
      server: server,
      refresh: resolvedRefresh,
    );
    await harness.seedRoom(token: 'rooma123', permissions: initialPermissions);
    return harness;
  }

  final AppDatabase database;
  final AccountRepository accounts;
  final ChatRepository chat;
  final CallLifecycleSessionRepository sessions;
  final MemoryCredentialVault credentials;
  final HttpNextcloudApi api;
  final _CallServer server;
  final CallConversationSessionRefresh refresh;
  final CallLifecycleService service;

  CallLifecycleService newService() => CallLifecycleService(
    accounts: accounts,
    chat: chat,
    sessions: sessions,
    credentials: credentials,
    api: api,
    refreshConversationSession: refresh,
    now: _now,
  );

  Future<void> seedRoom({required String token, int permissions = 255}) async {
    final root =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )!
            as Map<String, Object?>;
    final ocs = root['ocs']! as Map<String, Object?>;
    final rooms = ocs['data']! as List<Object?>;
    final wire = Map<String, Object?>.from(rooms.first! as Map<String, Object?>)
      ..addAll(<String, Object?>{
        'token': token,
        'sessionId': 'session-$token',
        'permissions': permissions,
        'participantType': 1,
        'lobbyState': 0,
        'canStartCall': true,
        'hasCall': false,
        'recordingConsent': 0,
      });
    final lastMessage = wire['lastMessage'];
    if (lastMessage is Map<String, Object?>) {
      wire['lastMessage'] = Map<String, Object?>.from(lastMessage)
        ..['token'] = token;
    }
    final room = ConversationRoom.fromJson(wire);
    await database
        .into(database.cachedConversations)
        .insertOnConflictUpdate(
          CachedConversationsCompanion.insert(
            accountId: 'account-a',
            token: token,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            roomName: Value(room.name),
            objectType: Value(room.objectType),
            avatarVersion: Value(room.avatarVersion),
            isCustomAvatar: Value(room.isCustomAvatar),
            rawJson: jsonEncode(wire),
          ),
        );
  }

  Future<void> dispose() async {
    api.close();
    await database.close();
  }
}

typedef _CallHandler =
    Future<http.Response> Function(http.Request request, int index);

final class _CallServer {
  _CallServer({_CallHandler? onCall})
    : _onCall =
          onCall ?? ((_, _) async => _ocsResponse(200, <String, Object?>{})) {
    client = MockClient(_handle);
  }

  final _CallHandler _onCall;
  late final MockClient client;
  final List<http.Request> callRequests = <http.Request>[];
  bool extraFeature = false;

  List<String> get callMethods =>
      callRequests.map((request) => request.method).toList(growable: false);

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path.contains('/cloud/capabilities')) {
      return http.Response(
        jsonEncode(_capabilities(extraFeature: extraFeature)),
        200,
      );
    }
    if (request.url.path.contains('/apps/spreed/api/v4/call/')) {
      final index = callRequests.length;
      callRequests.add(request);
      return _onCall(request, index);
    }
    fail('Unexpected request ${request.method} ${request.url}');
  }
}

Map<String, Object?> _capabilities({
  required bool extraFeature,
}) => <String, Object?>{
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
            'conversation-v4',
            'conversation-permissions',
            'in-call-flags',
            'silent-call',
            'recording-consent',
            if (extraFeature) 'synthetic-capability-drift',
          ],
          'features-local': <Object?>[],
          'config': <String, Object?>{
            'call': <String, Object?>{'enabled': true, 'recording-consent': 0},
          },
          'version': '24.0.2',
        },
      },
    },
  },
};

http.Response _ocsResponse(int statusCode, Object? data) => http.Response(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': statusCode == 200 ? 'ok' : 'failure',
        'statuscode': statusCode,
        'message': statusCode == 200 ? 'OK' : 'Rejected',
      },
      'data': data,
    },
  }),
  statusCode,
);

http.Response _ocsFailure(int statusCode, String error) =>
    _ocsResponse(statusCode, <String, Object?>{'error': error});

Map<String, Object?> _peer({
  required String token,
  required String sessionId,
}) => <String, Object?>{
  'actorType': 'users',
  'actorId': 'fixture-user',
  'displayName': 'Fixture User',
  'token': token,
  'lastPing': 1770000000,
  'sessionId': sessionId,
};

DateTime _now() => DateTime.utc(2026, 8, 26, 12);

Matcher _lifecycleFailure(CallLifecycleError code) => throwsA(
  isA<CallLifecycleException>().having((error) => error.code, 'code', code),
);
