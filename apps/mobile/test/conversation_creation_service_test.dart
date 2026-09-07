import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'conversation_creation_test_support.dart';
import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault credentials;
  late HttpNextcloudApi api;
  late HttpNewConversationService service;
  late Map<String, dynamic> capabilities;
  late List<Map<String, Object?>> presets;
  late List<http.Request> posts;
  late Future<http.Response> Function(http.Request) create;
  Future<void> Function()? onCapabilityRead;

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
    capabilities = creationCapabilities();
    presets = creationPresets();
    posts = [];
    onCapabilityRead = null;
    create = (_) async => http.Response(jsonEncode(createdConversation()), 201);
    api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          posts.add(request);
          return create(request);
        }
        if (request.url.path.endsWith('/capabilities')) {
          await onCapabilityRead?.call();
          return http.Response(jsonEncode(capabilities), 200);
        }
        expect(request.url.path, endsWith('/presets/room'));
        return http.Response(
          jsonEncode({
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200},
              'data': presets,
            },
          }),
          200,
        );
      }),
    );
    service = HttpNewConversationService(
      accounts: accounts,
      credentials: credentials,
      api: api,
    );
  });
  tearDown(() async {
    api.close();
    await database.close();
  });

  Matcher error(NewConversationError code) => throwsA(
    isA<NewConversationException>().having((e) => e.code, 'code', code),
  );

  test(
    'sends preset values forced last and preserves exact initial password',
    () async {
      final options = await service.prepareCreation(accountId: 'account-a');
      final result = await service.createPreparedConversation(
        options: options,
        roomName: ' Webinar room ',
        presetIdentifier: 'webinar',
        userParameters: {'permissions': 511},
        password: '  secret  ',
      );
      expect(result.roomToken.value, isNotEmpty);
      expect(posts.single.bodyFields, containsPair('roomType', '3'));
      expect(posts.single.bodyFields, containsPair('permissions', '129'));
      expect(posts.single.bodyFields, containsPair('lobbyState', '1'));
      expect(posts.single.bodyFields, containsPair('password', '  secret  '));
      expect(posts.single.bodyFields, containsPair('preset', 'webinar'));
      expect(posts.single.headers['authorization'], isNot(contains('secret')));
    },
  );

  test(
    'global recording policy is separate from the stored preset preference',
    () async {
      final config =
          capabilities['ocs']['data']['capabilities']['spreed']['config']
              as Map;
      config['call'] = {'recording-consent': 0};
      final options = await service.prepareCreation(accountId: 'account-a');
      expect(options.recordingConsentPolicy, 0);
      await service.createPreparedConversation(
        options: options,
        roomName: 'Room',
        presetIdentifier: 'webinar',
        password: 'secret',
      );
      expect(posts.single.bodyFields['recordingConsent'], '1');
    },
  );

  test('changed global recording policy requires another review', () async {
    final config =
        capabilities['ocs']['data']['capabilities']['spreed']['config'] as Map;
    config['call'] = {'recording-consent': 0};
    final options = await service.prepareCreation(accountId: 'account-a');
    config['call'] = {'recording-consent': 1};
    await expectLater(
      service.createPreparedConversation(options: options, roomName: 'Room'),
      error(NewConversationError.contextChanged),
    );
    expect(posts, isEmpty);
  });

  test('returns the created room when only some invitations failed', () async {
    create = (_) async =>
        http.Response(jsonEncode(createdConversation(status: 202)), 202);
    final options = await service.prepareCreation(accountId: 'account-a');
    final result = await service.createPreparedConversation(
      options: options,
      roomName: 'Room',
    );
    expect(result.roomToken.value, isNotEmpty);
    expect(result.failedInvitationCount, 1);
    await expectLater(
      service.createPreparedConversation(options: options, roomName: 'Room'),
      error(NewConversationError.ambiguous),
    );
    expect(posts, hasLength(1));
  });

  test(
    'rejects a missing forced password without dispatching create',
    () async {
      capabilities = creationCapabilities(force: true);
      final options = await service.prepareCreation(accountId: 'account-a');
      await expectLater(
        service.createPreparedConversation(
          options: options,
          roomName: 'Room',
          presetIdentifier: 'webinar',
        ),
        error(NewConversationError.passwordRequired),
      );
      expect(posts, isEmpty);
    },
  );

  test(
    'a legacy server keeps creation body and strips private-room password',
    () async {
      capabilities = creationCapabilities(
        presets: false,
        password: false,
        all: false,
      );
      final options = await service.prepareCreation(accountId: 'account-a');
      await service.createPreparedConversation(
        options: options,
        roomName: 'Room',
        password: 'never-send',
        userParameters: {'roomType': 2},
      );
      expect(posts.single.bodyFields, {'roomType': '2', 'roomName': 'Room'});
    },
  );

  test(
    'force policy without password capability cannot expose a public room',
    () async {
      capabilities = creationCapabilities(
        presets: false,
        password: false,
        all: false,
        force: true,
      );
      final options = await service.prepareCreation(accountId: 'account-a');
      await expectLater(
        service.createPreparedConversation(
          options: options,
          roomName: 'Room',
          userParameters: {'roomType': 3},
        ),
        error(NewConversationError.unsupported),
      );
      expect(posts, isEmpty);
    },
  );

  test('fresh changed policy must be reviewed before dispatch', () async {
    final options = await service.prepareCreation(accountId: 'account-a');
    presets = creationPresets(forcedPermissions: 389);
    await expectLater(
      service.createPreparedConversation(options: options, roomName: 'Room'),
      error(NewConversationError.contextChanged),
    );
    expect(posts, isEmpty);
  });

  test(
    'changed credentials during fresh preparation cannot dispatch',
    () async {
      final options = await service.prepareCreation(accountId: 'account-a');
      onCapabilityRead = () async {
        credentials.values['account-a'] = 'changed';
      };
      await expectLater(
        service.createPreparedConversation(options: options, roomName: 'Room'),
        error(NewConversationError.contextChanged),
      );
      expect(posts, isEmpty);
    },
  );

  test('account switch and owner invalidation cannot dispatch', () async {
    final options = await service.prepareCreation(accountId: 'account-a');
    await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://second.example.invalid',
      loginName: 'bob',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    await expectLater(
      service.createPreparedConversation(options: options, roomName: 'Room'),
      error(NewConversationError.contextChanged),
    );
    await expectLater(
      service.createPreparedConversation(
        options: options,
        roomName: 'Room',
        isCurrent: () => false,
      ),
      error(NewConversationError.cancelled),
    );
    expect(posts, isEmpty);
  });

  test('unknown forced policy refuses the whole preparation', () async {
    presets.last['parameters'] = {'futureSecuritySetting': 1};
    await expectLater(
      service.prepareCreation(accountId: 'account-a'),
      error(NewConversationError.invalidResponse),
    );
    expect(posts, isEmpty);
  });

  test(
    'safe password-policy refusal can be corrected without a blind retry',
    () async {
      create = (_) async => http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 400},
            'data': {
              'error': 'password',
              'message': 'Use at least ten characters.',
            },
          },
        }),
        400,
      );
      final options = await service.prepareCreation(accountId: 'account-a');
      await expectLater(
        service.createPreparedConversation(
          options: options,
          roomName: 'Room',
          presetIdentifier: 'webinar',
          password: 'short',
        ),
        throwsA(
          isA<NewConversationException>()
              .having(
                (e) => e.code,
                'code',
                NewConversationError.passwordRequired,
              )
              .having(
                (e) => e.safeMessage,
                'hint',
                'Use at least ten characters.',
              ),
        ),
      );
      expect(posts, hasLength(1));
      create = (_) async =>
          http.Response(jsonEncode(createdConversation()), 201);
      await service.createPreparedConversation(
        options: options,
        roomName: 'Room',
        presetIdentifier: 'webinar',
        password: 'longer-secret',
      );
      expect(posts, hasLength(2));
    },
  );

  test('a policy response echoing the password is not shown', () async {
    create = (_) async => http.Response(
      jsonEncode({
        'ocs': {
          'meta': {'status': 'failure', 'statuscode': 400},
          'data': {'error': 'password', 'message': 'Rejected private-secret'},
        },
      }),
      400,
    );
    final options = await service.prepareCreation(accountId: 'account-a');
    await expectLater(
      service.createPreparedConversation(
        options: options,
        roomName: 'Room',
        presetIdentifier: 'webinar',
        password: 'private-secret',
      ),
      throwsA(
        isA<NewConversationException>()
            .having((e) => e.safeMessage, 'hint', isNull)
            .having(
              (e) => e.toString(),
              'diagnostics',
              isNot(contains('private-secret')),
            ),
      ),
    );
  });

  for (final failure in ['disconnect', '503', 'malformed']) {
    test('never repeats an ambiguous $failure create', () async {
      create = (_) async {
        if (failure == 'disconnect') throw http.ClientException('Disconnected');
        return http.Response(
          failure == '503' ? '' : '{}',
          failure == '503' ? 503 : 201,
        );
      };
      final options = await service.prepareCreation(accountId: 'account-a');
      await expectLater(
        service.createPreparedConversation(options: options, roomName: 'Room'),
        error(NewConversationError.ambiguous),
      );
      await expectLater(
        service.createPreparedConversation(options: options, roomName: 'Room'),
        error(NewConversationError.ambiguous),
      );
      expect(posts, hasLength(1));
    });
  }

  test('two simultaneous creates dispatch only once', () async {
    final pending = Completer<http.Response>();
    create = (_) => pending.future;
    final options = await service.prepareCreation(accountId: 'account-a');
    final first = service.createPreparedConversation(
      options: options,
      roomName: 'Room',
    );
    await expectLater(
      service.createPreparedConversation(options: options, roomName: 'Room'),
      error(NewConversationError.ambiguous),
    );
    pending.complete(http.Response(jsonEncode(createdConversation()), 201));
    await first;
    expect(posts, hasLength(1));
  });
}
