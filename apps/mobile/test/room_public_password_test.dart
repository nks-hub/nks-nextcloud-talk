import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'conversation_creation_test_support.dart';
import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault credentials;
  late HttpNextcloudApi api;
  late RoomSettingsService service;
  late Map<String, dynamic> capabilities;
  late Map<String, Object?> room;
  late List<http.Request> mutations;
  late Future<http.Response> Function(http.Request) mutate;
  var emptySuccess = false;
  var failReadback = false;
  late String token;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    credentials = MemoryCredentialVault()..values['account-a'] = 'app-password';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    capabilities = creationCapabilities(force: true);
    final fixture = createdConversation()['ocs'] as Map;
    room = Map<String, Object?>.from(fixture['data'] as Map)
      ..addAll({
        'participantType': 1,
        'type': 2,
        'hasPassword': false,
        'attributes': 0,
      });
    token = room['token'] as String;
    mutations = [];
    emptySuccess = false;
    failReadback = false;
    mutate = (request) async {
      final public = request.method == 'POST';
      room['type'] = public ? 3 : 2;
      room['hasPassword'] =
          public &&
          request.body.isNotEmpty &&
          (request.bodyFields['password']?.isNotEmpty ?? false);
      return success(emptySuccess ? <Object?>[] : room);
    };
    api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (request.url.path.endsWith('/room') && request.method == 'GET') {
          if (failReadback && mutations.isNotEmpty) {
            throw http.ClientException('Readback failed');
          }
          return success([room]);
        }
        expect(request.url.path, endsWith('/room/$token/public'));
        mutations.add(request);
        return mutate(request);
      }),
    );
    service = RoomSettingsService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: credentials,
      api: api,
    );
  });
  tearDown(() async {
    api.close();
    await database.close();
  });

  Matcher error(RoomSettingsError code) =>
      throwsA(isA<RoomSettingsException>().having((e) => e.code, 'code', code));

  test(
    'required password and public state are sent in one atomic POST',
    () async {
      final access = await service.preparePublicChange(
        accountId: 'account-a',
        roomToken: token,
      );
      expect(access.forcePasswords, isTrue);
      final changed = await service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: true,
        password: '  protected  ',
        prepared: access,
      );
      expect(changed.type, 3);
      expect(changed.hasPassword, isTrue);
      expect(mutations.single.method, 'POST');
      expect(mutations.single.bodyFields, {'password': '  protected  '});
    },
  );

  test(
    'fresh GET confirms password when the mutation response has stale metadata',
    () async {
      mutate = (_) async {
        room['type'] = 3;
        room['hasPassword'] = true;
        return success({...room, 'hasPassword': false});
      };
      final result = await service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: true,
        password: 'protected',
      );
      expect(result.type, 3);
      expect(result.hasPassword, isTrue);
      expect(mutations, hasLength(1));
    },
  );

  test(
    'making a room private preserves the password metadata returned by the server',
    () async {
      room['type'] = 3;
      room['hasPassword'] = true;
      mutate = (_) async {
        room['type'] = 2;
        return success(room);
      };
      final result = await service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: false,
      );
      expect(result.type, 2);
      expect(result.hasPassword, isTrue);
      expect(mutations.single.method, 'DELETE');
    },
  );

  test(
    'an existing public room needs the separate password operation',
    () async {
      room['type'] = 3;
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'new-password',
        ),
        error(RoomSettingsError.preconditionFailed),
      );
      expect(mutations, isEmpty);
      expect(room['hasPassword'], isFalse);
    },
  );

  for (final password in <String?>[null, '']) {
    test(
      'a missing forced password never makes a public room ($password)',
      () async {
        await expectLater(
          service.setPublic(
            accountId: 'account-a',
            roomToken: token,
            public: true,
            password: password,
          ),
          error(RoomSettingsError.preconditionFailed),
        );
        expect(mutations, isEmpty);
        expect(room['type'], 2);
      },
    );
  }

  test(
    'missing password capability fails closed only when policy requires it',
    () async {
      capabilities = creationCapabilities(password: false, force: true);
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'secret',
        ),
        error(RoomSettingsError.preconditionFailed),
      );
      expect(mutations, isEmpty);
      capabilities = creationCapabilities(password: false, force: false);
      await service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: true,
      );
      expect(mutations.single.body, isEmpty);
      expect(room['type'], 3);
      expect(room['hasPassword'], isFalse);
    },
  );

  for (final role in [1, 2, 3, 6]) {
    test(
      'public transition admits only owner and authenticated moderator: $role',
      () async {
        room['participantType'] = role;
        final future = service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'secret',
        );
        if (role == 1 || role == 2) {
          await future;
          expect(mutations, hasLength(1));
        } else {
          await expectLater(future, error(RoomSettingsError.forbidden));
          expect(mutations, isEmpty);
        }
      },
    );
  }

  test(
    'revoked moderator role is checked again after the password prompt',
    () async {
      final access = await service.preparePublicChange(
        accountId: 'account-a',
        roomToken: token,
      );
      room['participantType'] = 3;
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'secret',
          prepared: access,
        ),
        error(RoomSettingsError.forbidden),
      );
      expect(mutations, isEmpty);
    },
  );

  test(
    'changed policy requires fresh user review and does not apply silently',
    () async {
      final access = await service.preparePublicChange(
        accountId: 'account-a',
        roomToken: token,
      );
      capabilities = creationCapabilities(force: false);
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'secret',
          prepared: access,
        ),
        error(RoomSettingsError.preconditionFailed),
      );
      expect(mutations, isEmpty);
    },
  );

  test(
    'invalid password does not change type and a secret echo is suppressed',
    () async {
      mutate = (_) async => http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 400},
            'data': {'message': 'Password private-secret was rejected'},
          },
        }),
        400,
      );
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'private-secret',
        ),
        throwsA(
          isA<RoomSettingsException>()
              .having((e) => e.code, 'code', RoomSettingsError.rejected)
              .having((e) => e.message, 'hint', isNull),
        ),
      );
      expect(room['type'], 2);
      expect(mutations, hasLength(1));
    },
  );

  test(
    'a bodyless success is verified by authoritative room readback',
    () async {
      emptySuccess = true;
      final changed = await service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: true,
        password: 'protected',
      );
      expect(changed.type, 3);
      expect(changed.hasPassword, isTrue);
      expect(mutations, hasLength(1));
      final closed = await service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: false,
      );
      expect(closed.type, 2);
      expect(closed.hasPassword, isFalse);
      expect(mutations.last.method, 'DELETE');
    },
  );

  test(
    'readback failure is uncertain and the same prepared operation is not repeated',
    () async {
      emptySuccess = true;
      failReadback = true;
      final access = await service.preparePublicChange(
        accountId: 'account-a',
        roomToken: token,
      );
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'protected',
          prepared: access,
        ),
        error(RoomSettingsError.ambiguous),
      );
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'protected',
          prepared: access,
        ),
        error(RoomSettingsError.rejected),
      );
      expect(mutations, hasLength(1));
    },
  );

  test(
    'a competing publication cannot pretend to set the supplied password',
    () async {
      final access = await service.preparePublicChange(
        accountId: 'account-a',
        roomToken: token,
      );
      room['type'] = 3;
      await expectLater(
        service.setPublic(
          accountId: 'account-a',
          roomToken: token,
          public: true,
          password: 'protected',
          prepared: access,
        ),
        error(RoomSettingsError.preconditionFailed),
      );
      expect(mutations, isEmpty);
    },
  );

  test('account and credential changes prevent dispatch', () async {
    final access = await service.preparePublicChange(
      accountId: 'account-a',
      roomToken: token,
    );
    credentials.values['account-a'] = 'changed';
    await expectLater(
      service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: true,
        password: 'protected',
        prepared: access,
      ),
      error(RoomSettingsError.accountMissing),
    );
    await expectLater(
      service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: true,
        isCurrent: () => false,
      ),
      error(RoomSettingsError.accountMissing),
    );
    expect(mutations, isEmpty);
  });

  test('two concurrent transitions cannot send two POST requests', () async {
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    mutate = (_) {
      started.complete();
      return pending.future;
    };
    final first = service.setPublic(
      accountId: 'account-a',
      roomToken: token,
      public: true,
      password: 'protected',
    );
    await expectLater(
      service.setPublic(
        accountId: 'account-a',
        roomToken: token,
        public: true,
        password: 'protected',
      ),
      error(RoomSettingsError.rejected),
    );
    await started.future;
    room.addAll({'type': 3, 'hasPassword': true});
    pending.complete(success(room));
    await first;
    expect(mutations, hasLength(1));
  });
}

http.Response success(Object data) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200},
      'data': data,
    },
  }),
  200,
);
