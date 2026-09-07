import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'conversation_creation_test_support.dart';
import 'test_support.dart';

void main() {
  late _PermissionServer server;
  setUp(() async {
    server = _PermissionServer();
    await server.prepare();
  });
  tearDown(() async {
    server.api.close();
    await server.database.close();
  });
  Matcher failure(RoomSettingsError code) =>
      throwsA(isA<RoomSettingsException>().having((e) => e.code, 'code', code));

  test(
    'changing even the same default requires confirmation and resets all overrides',
    () async {
      server.member['attendeePermissions'] = 129;
      final edit = await server.edit(PermissionEditKind.roomDefault);
      await expectLater(
        server.apply(edit, 0),
        failure(RoomSettingsError.rejected),
      );
      expect(server.mutations, isEmpty);
      final result = await server.apply(edit, 0, reset: true);
      expect(result.room.defaultPermissions, 0);
      expect(
        result.participants.every((p) => p.attendeePermissions == 0),
        isTrue,
      );
      expect(server.mutations.single.bodyFields, {'permissions': '0'});
      await expectLater(
        server.apply(edit, 0, reset: true),
        failure(RoomSettingsError.preconditionFailed),
      );
      expect(server.mutations, hasLength(1));
    },
  );

  test(
    'explicit no rights remains custom one instead of inherited zero',
    () async {
      final edit = await server.edit(PermissionEditKind.attendee);
      final result = await server.apply(edit, 1);
      final member = result.participants.singleWhere((p) => p.attendeeId == 17);
      expect(member.attendeePermissions, 1);
      expect(member.permissions, 1);
      expect(server.mutations.single.bodyFields, {
        'attendeeId': '17',
        'method': 'set',
        'permissions': '1',
      });
    },
  );

  test('attendee reset remains possible under a forced mask', () async {
    server.forced = {'permissions': 128};
    server.room['defaultPermissions'] = 129;
    server.member['attendeePermissions'] = 129;
    final edit = await server.edit(PermissionEditKind.attendee);
    final result = await server.apply(edit, 0);
    final member = result.participants.singleWhere((p) => p.attendeeId == 17);
    expect(member.attendeePermissions, 0);
    expect(member.permissions, 129);
  });

  test(
    'mention update verifies the room value without resetting overrides',
    () async {
      server.member['attendeePermissions'] = 1;
      final result = await server.apply(
        await server.edit(PermissionEditKind.mentions),
        1,
      );
      expect(result.room.mentionPermissions, 1);
      expect(result.participants.last.attendeePermissions, 1);
      expect(server.mutations.single.bodyFields, {'mentionPermissions': '1'});
    },
  );

  test(
    'unknown current values cannot be silently replaced by a supported subset',
    () async {
      server.room['defaultPermissions'] = 1024;
      await expectLater(
        server.edit(PermissionEditKind.roomDefault),
        failure(RoomSettingsError.invalidResponse),
      );
      server.room['defaultPermissions'] = 0;
      server.member['attendeePermissions'] = 1024;
      await expectLater(
        server.edit(PermissionEditKind.attendee),
        failure(RoomSettingsError.invalidResponse),
      );
      server.member['attendeePermissions'] = 0;
      server.room['mentionPermissions'] = 2;
      await expectLater(
        server.edit(PermissionEditKind.mentions),
        failure(RoomSettingsError.invalidResponse),
      );
      expect(server.mutations, isEmpty);
    },
  );

  test('moderator loss and unsupported capabilities stop mutation', () async {
    final edit = await server.edit(PermissionEditKind.attendee);
    server.room['participantType'] = 3;
    await expectLater(
      server.apply(edit, 129),
      failure(RoomSettingsError.forbidden),
    );
    server.room['participantType'] = 1;
    server.features.remove('publishing-permissions');
    await expectLater(
      server.apply(edit, 129),
      failure(RoomSettingsError.forbidden),
    );
    expect(server.mutations, isEmpty);
  });

  test(
    'guest moderators can edit masks but not the logged-in-only mention setting',
    () async {
      server.room['participantType'] = 6;
      server.people.first['participantType'] = 6;
      expect(
        await server.edit(PermissionEditKind.roomDefault),
        isA<RoomPermissionEdit>(),
      );
      expect(
        await server.edit(PermissionEditKind.attendee),
        isA<RoomPermissionEdit>(),
      );
      await expectLater(
        server.edit(PermissionEditKind.mentions),
        failure(RoomSettingsError.forbidden),
      );
    },
  );

  test(
    'moderators, aggregate actors and unidentified targets cannot receive overrides',
    () async {
      final initial = Map<String, Object?>.from(server.member);
      for (final fields in <Map<String, Object?>>[
        {'participantType': 1},
        {'participantType': 2},
        {'participantType': 6},
        {'participantType': 7},
        {'actorType': 'groups'},
        {'actorType': 'circles'},
        {'actorType': 'future_actor'},
        {'actorId': ''},
      ]) {
        server.member
          ..clear()
          ..addAll(initial)
          ..addAll(fields);
        await expectLater(
          server.edit(PermissionEditKind.attendee),
          failure(RoomSettingsError.forbidden),
        );
      }
      expect(server.mutations, isEmpty);
    },
  );

  test('direct, classified and federated rooms fail closed', () async {
    final initial = Map<String, Object?>.from(server.room);
    for (final fields in <Map<String, Object?>>[
      {'type': 1},
      {'type': 6},
      {'attributes': 4},
      {'remoteServer': 'https://remote.example.invalid'},
    ]) {
      server.room
        ..clear()
        ..addAll(initial)
        ..addAll(fields);
      await expectLater(
        server.edit(PermissionEditKind.roomDefault),
        failure(RoomSettingsError.forbidden),
      );
    }
    expect(server.mutations, isEmpty);
  });

  test(
    'breakout rooms reject default and mention administration but allow attendee rights',
    () async {
      server.room['objectType'] = 'room';
      await expectLater(
        server.edit(PermissionEditKind.roomDefault),
        failure(RoomSettingsError.forbidden),
      );
      await expectLater(
        server.edit(PermissionEditKind.mentions),
        failure(RoomSettingsError.forbidden),
      );
      expect(
        await server.edit(PermissionEditKind.attendee),
        isA<RoomPermissionEdit>(),
      );
    },
  );

  test(
    'self-joined membership conversion requires its own confirmation',
    () async {
      server.member['participantType'] = 5;
      final edit = await server.edit(PermissionEditKind.attendee);
      expect(edit.makesRegularMember, isTrue);
      await expectLater(
        server.apply(edit, 0),
        failure(RoomSettingsError.rejected),
      );
      expect(server.mutations, isEmpty);
      final result = await server.apply(edit, 0, membership: true);
      final member = result.participants.singleWhere((p) => p.attendeeId == 17);
      expect(member.participantType, 3);
      expect(member.attendeePermissions, 0);
    },
  );

  test(
    'a different actor under the same attendee id needs a fresh edit',
    () async {
      final edit = await server.edit(PermissionEditKind.attendee);
      server.member['actorId'] = 'different-person';
      await expectLater(
        server.apply(edit, 129),
        failure(RoomSettingsError.preconditionFailed),
      );
      expect(server.mutations, isEmpty);
    },
  );

  test('a removed attendee cannot be edited', () async {
    final edit = await server.edit(PermissionEditKind.attendee);
    server.people.removeLast();
    await expectLater(
      server.apply(edit, 129),
      failure(RoomSettingsError.roomMissing),
    );
    expect(server.mutations, isEmpty);
  });

  test(
    'changed target permissions require review instead of overwriting them',
    () async {
      final edit = await server.edit(PermissionEditKind.attendee);
      server.member['attendeePermissions'] = 5;
      await expectLater(
        server.apply(edit, 129),
        failure(RoomSettingsError.preconditionFailed),
      );
      expect(server.mutations, isEmpty);
    },
  );

  test(
    'changed forcing and inherited server defaults require review',
    () async {
      final edit = await server.edit(PermissionEditKind.mentions);
      server.forced = {'mentionPermissions': 1};
      await expectLater(
        server.apply(edit, 1),
        failure(RoomSettingsError.preconditionFailed),
      );
      server.forced = null;
      server.defaultMask = 129;
      await expectLater(
        server.apply(edit, 1),
        failure(RoomSettingsError.preconditionFailed),
      );
      expect(server.mutations, isEmpty);
    },
  );

  test(
    'changed credentials and account selection stop a prepared operation',
    () async {
      final edit = await server.edit(PermissionEditKind.attendee);
      server.vault.values['account-a'] = 'changed';
      await expectLater(
        server.apply(edit, 129),
        failure(RoomSettingsError.accountMissing),
      );
      server.vault.values['account-a'] = 'fixture-password';
      await server.accounts.upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://second.example.invalid',
        loginName: 'other',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
      await expectLater(
        server.apply(edit, 129),
        failure(RoomSettingsError.accountMissing),
      );
      expect(server.mutations, isEmpty);
    },
  );

  test(
    'a prepared edit cannot be transferred to another service instance',
    () async {
      final edit = await server.edit(PermissionEditKind.attendee);
      final other = RoomSettingsService(
        accounts: server.accounts,
        chat: ChatRepository(server.database),
        credentials: server.vault,
        api: server.api,
      );
      await expectLater(
        other.applyPermissionEdit(edit: edit, value: 129),
        failure(RoomSettingsError.preconditionFailed),
      );
      expect(server.mutations, isEmpty);
    },
  );

  test('owner invalidation before dispatch makes no write', () async {
    final edit = await server.edit(PermissionEditKind.attendee);
    await expectLater(
      server.service.applyPermissionEdit(
        edit: edit,
        value: 129,
        isCurrent: () => false,
      ),
      failure(RoomSettingsError.accountMissing),
    );
    expect(server.mutations, isEmpty);
  });

  test(
    'a stale acknowledgment is checked against fresh room and participant state',
    () async {
      server.staleRoomAck = true;
      server.member['attendeePermissions'] = 5;
      final result = await server.apply(
        await server.edit(PermissionEditKind.roomDefault),
        128,
        reset: true,
      );
      expect(result.room.defaultPermissions, 129);
      expect(result.participants.last.attendeePermissions, 0);
    },
  );

  test(
    'unreset attendee overrides make a default update unconfirmed',
    () async {
      server.member['attendeePermissions'] = 5;
      server.keepOverrides = true;
      final edit = await server.edit(PermissionEditKind.roomDefault);
      await expectLater(
        server.apply(edit, 128, reset: true),
        failure(RoomSettingsError.ambiguous),
      );
      await expectLater(
        server.apply(edit, 128, reset: true),
        failure(RoomSettingsError.preconditionFailed),
      );
      expect(server.mutations, hasLength(1));
    },
  );

  test(
    'an empty readback list cannot prove that all overrides were reset',
    () async {
      final edit = await server.edit(PermissionEditKind.roomDefault);
      server.mutate = (_) async {
        server.room['defaultPermissions'] = 129;
        server.people.clear();
        return _success(server.room);
      };
      await expectLater(
        server.apply(edit, 128, reset: true),
        failure(RoomSettingsError.ambiguous),
      );
    },
  );

  test('a success carrying another actor cannot update the row', () async {
    server.mutate = (_) async => _success([
      {...server.member, 'actorId': 'unexpected-actor'},
    ]);
    final edit = await server.edit(PermissionEditKind.attendee);
    await expectLater(
      server.apply(edit, 129),
      failure(RoomSettingsError.ambiguous),
    );
    expect(server.mutations, hasLength(1));
  });

  for (final code in [400, 403, 404, 429, 503]) {
    test(
      'classifies HTTP $code without automatically repeating a write',
      () async {
        server.mutate = (_) async => _failure(code);
        final edit = await server.edit(PermissionEditKind.attendee);
        await expectLater(
          server.apply(edit, 129),
          failure(switch (code) {
            400 => RoomSettingsError.rejected,
            403 => RoomSettingsError.forbidden,
            404 => RoomSettingsError.roomMissing,
            429 => RoomSettingsError.rateLimited,
            _ => RoomSettingsError.ambiguous,
          }),
        );
        expect(server.mutations, hasLength(1));
      },
    );
  }

  test(
    'readback transport failure cannot be presented as a confirmed edit',
    () async {
      server.failReadback = true;
      final edit = await server.edit(PermissionEditKind.attendee);
      await expectLater(
        server.apply(edit, 129),
        failure(RoomSettingsError.ambiguous),
      );
      expect(server.mutations, hasLength(1));
    },
  );

  test(
    'permission and public-access mutations share the same in-flight guard',
    () async {
      final started = Completer<void>();
      final pending = Completer<http.Response>();
      server.mutate = (request) {
        started.complete();
        return pending.future;
      };
      final edit = await server.edit(PermissionEditKind.attendee);
      final change = server.apply(edit, 129);
      await started.future;
      await expectLater(
        server.service.setPublic(
          accountId: 'account-a',
          roomToken: 'rooma123',
          public: true,
        ),
        failure(RoomSettingsError.rejected),
      );
      await expectLater(
        server.apply(edit, 129),
        failure(RoomSettingsError.preconditionFailed),
      );
      server.member['attendeePermissions'] = 129;
      pending.complete(_success([server.member]));
      await change;
      expect(server.mutations, hasLength(1));
    },
  );
  test(
    'owner invalidation after dispatch cannot return a stale success',
    () async {
      final started = Completer<void>();
      final pending = Completer<http.Response>();
      var current = true;
      server.mutate = (_) {
        started.complete();
        return pending.future;
      };
      final edit = await server.edit(PermissionEditKind.attendee);
      final change = server.service.applyPermissionEdit(
        edit: edit,
        value: 129,
        isCurrent: () => current,
      );
      await started.future;
      final outcome = expectLater(change, failure(RoomSettingsError.ambiguous));
      current = false;
      server.member['attendeePermissions'] = 129;
      pending.complete(_success([server.member]));
      await outcome;
      await expectLater(
        server.apply(edit, 129),
        failure(RoomSettingsError.preconditionFailed),
      );
      expect(server.mutations, hasLength(1));
    },
  );
}

final class _PermissionServer {
  final database = openTestDatabase();
  final vault = MemoryCredentialVault()
    ..values['account-a'] = 'fixture-password';
  late final accounts = AccountRepository(database);
  late final HttpNextcloudApi api;
  late final RoomSettingsService service;
  final features = {
    'conversation-permissions',
    'publishing-permissions',
    'mention-permissions',
    'chat-permission',
    'react-permission',
  };
  Map<String, int>? forced;
  int defaultMask = 502;
  late Map<String, Object?> room;
  final people = <Map<String, Object?>>[
    _person(1, 'alice', 1),
    _person(17, 'person-a', 3),
  ];
  Map<String, Object?> get member => people.last;
  final mutations = <http.Request>[];
  late Future<http.Response> Function(http.Request) mutate;
  bool staleRoomAck = false;
  bool keepOverrides = false;
  bool failReadback = false;

  Future<void> prepare() async {
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    final envelope = createdConversation()['ocs'] as Map;
    room = Map<String, Object?>.from(envelope['data'] as Map)
      ..addAll({
        'token': 'rooma123',
        'type': 2,
        'participantType': 1,
        'defaultPermissions': 0,
        'attributes': 0,
        'objectType': '',
        'mentionPermissions': 0,
      });
    mutate = _mutate;
    api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.method != 'GET') {
          mutations.add(request);
          return mutate(request);
        }
        if (failReadback && mutations.isNotEmpty) {
          throw http.ClientException('Readback failed');
        }
        if (request.url.path.endsWith('/capabilities')) return _capabilities();
        if (request.url.path.endsWith('/presets/room')) {
          return _success([
            {
              'identifier': 'default',
              'name': '',
              'description': '',
              'parameters': {'roomType': 2},
            },
            {
              'identifier': 'forced',
              'name': '',
              'description': '',
              'parameters': forced ?? <String, int>{},
            },
          ]);
        }
        if (request.url.path.endsWith('/room')) return _success([room]);
        if (request.url.path.endsWith('/participants')) {
          return _success(_participants());
        }
        throw StateError('Unexpected test request');
      }),
    );
    service = RoomSettingsService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: vault,
      api: api,
    );
  }

  Future<RoomPermissionEdit> edit(PermissionEditKind kind) =>
      service.preparePermissionEdit(
        accountId: 'account-a',
        roomToken: 'rooma123',
        kind: kind,
        attendeeId: kind == PermissionEditKind.attendee ? 17 : null,
      );

  Future<RoomPermissionEditResult> apply(
    RoomPermissionEdit edit,
    int value, {
    bool reset = false,
    bool membership = false,
  }) => service.applyPermissionEdit(
    edit: edit,
    value: value,
    confirmResetOverrides: reset,
    confirmRegularMembership: membership,
  );

  http.Response _capabilities() {
    final root =
        readFixtureJson(
              'client-bootstrap/fixtures/capabilities-authenticated.response.json',
            )!
            as Map<String, Object?>;
    final ocs = root['ocs']! as Map<String, Object?>;
    final data = ocs['data']! as Map<String, Object?>;
    final caps = data['capabilities']! as Map<String, Object?>;
    caps['spreed'] = {
      'features': [...features, if (forced != null) 'conversation-presets'],
      'config': {
        'permissions': {
          'max-default': 510,
          'max-custom': 511,
          'default': defaultMask,
        },
      },
    };
    return http.Response(jsonEncode(root), 200);
  }

  List<Map<String, Object?>> _participants() => people.map((person) {
    final raw = person['attendeePermissions'] as int;
    final roomDefault = room['defaultPermissions'] as int;
    return {
      ...person,
      'permissions': const {1, 2, 6}.contains(person['participantType'])
          ? 510
          : raw != 0
          ? raw
          : roomDefault != 0
          ? roomDefault
          : defaultMask,
    };
  }).toList();

  Future<http.Response> _mutate(http.Request request) async {
    expect(request.method, 'PUT');
    final before = Map<String, Object?>.from(room);
    if (request.url.path.endsWith('/permissions/default')) {
      room['defaultPermissions'] = normalizePermissionSet(
        int.parse(request.bodyFields['permissions']!),
      );
      if (!keepOverrides) {
        for (final p in people) {
          p['attendeePermissions'] = 0;
        }
      }
      return _success(staleRoomAck ? before : room);
    }
    if (request.url.path.endsWith('/mention-permissions')) {
      room['mentionPermissions'] = int.parse(
        request.bodyFields['mentionPermissions']!,
      );
      return _success(room);
    }
    expect(request.url.path, endsWith('/attendees/permissions'));
    expect(request.bodyFields['method'], 'set');
    final id = int.parse(request.bodyFields['attendeeId']!);
    final target = people.singleWhere((p) => p['attendeeId'] == id);
    target['attendeePermissions'] = normalizePermissionSet(
      int.parse(request.bodyFields['permissions']!),
    );
    if (target['participantType'] == 5) target['participantType'] = 3;
    return _success(
      _participants().where((p) => p['attendeeId'] == id).toList(),
    );
  }
}

Map<String, Object?> _person(int id, String actor, int role) => {
  'attendeeId': id,
  'actorType': 'users',
  'actorId': actor,
  'displayName': actor,
  'participantType': role,
  'lastPing': 0,
  'sessionIds': <String>[],
  'permissions': 502,
  'attendeePermissions': 0,
  'inCall': 0,
};

http.Response _success(Object? data) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200},
      'data': data,
    },
  }),
  200,
);
http.Response _failure(int status) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': 'failure', 'statuscode': status},
      'data': <Object?>[],
    },
  }),
  status,
);
