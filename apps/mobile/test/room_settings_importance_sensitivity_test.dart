import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'password-a';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
      talkFeatures: const <String>{
        'important-conversations',
        'sensitive-conversations',
      },
    );
  });

  tearDown(() => database.close());

  RoomSettingsService serviceWith(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return RoomSettingsService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: vault,
      api: api,
    );
  }

  test(
    'uses fresh exact capabilities and returns authoritative rooms',
    () async {
      final calls = <({String method, String path, String? authorization})>[];
      final service = serviceWith(
        MockClient((request) async {
          calls.add((
            method: request.method,
            path: request.url.path,
            authorization: request.headers['Authorization'],
          ));
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_capabilities()), 200);
          }
          if (request.url.path.endsWith('/important')) {
            return _roomResponse(isImportant: request.method == 'POST');
          }
          if (request.url.path.endsWith('/sensitive')) {
            return _roomResponse(isSensitive: request.method == 'POST');
          }
          return http.Response('', 404);
        }),
      );

      final important = await service.setImportant(
        accountId: 'account-a',
        roomToken: 'rooma123',
        important: true,
      );
      final sensitive = await service.setSensitive(
        accountId: 'account-a',
        roomToken: 'rooma123',
        sensitive: false,
      );

      expect(important.isImportant, isTrue);
      expect(sensitive.isSensitive, isFalse);
      expect(
        calls.map((call) => (call.method, call.path.split('/').last)).toList(),
        <(String, String)>[
          ('GET', 'capabilities'),
          ('POST', 'important'),
          ('DELETE', 'sensitive'),
        ],
      );
      expect(calls.map((call) => call.authorization).toSet(), <String>{
        'Basic ${base64Encode(utf8.encode('user-a:password-a'))}',
      });
    },
  );

  test('does not call either mutation without its exact capability', () async {
    for (final operation
        in <({String feature, Future<void> Function(RoomSettingsService) run})>[
          (
            feature: 'sensitive-conversations',
            run: (service) async {
              await service.setImportant(
                accountId: 'account-a',
                roomToken: 'rooma123',
                important: true,
              );
            },
          ),
          (
            feature: 'important-conversations',
            run: (service) async {
              await service.setSensitive(
                accountId: 'account-a',
                roomToken: 'rooma123',
                sensitive: true,
              );
            },
          ),
        ]) {
      var mutations = 0;
      final service = serviceWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(_capabilities(features: <String>[operation.feature])),
              200,
            );
          }
          mutations++;
          return _roomResponse();
        }),
      );

      await expectLater(
        operation.run(service),
        _throwsRoomSettingsError(RoomSettingsError.invalidResponse),
      );
      expect(mutations, 0);
    }
  });

  test(
    'maps classified sensitivity refusal without changing local state',
    () async {
      final service = serviceWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_capabilities()), 200);
          }
          if (request.url.path.endsWith('/sensitive')) {
            return _ocsResponse(
              statusCode: 400,
              status: 'failure',
              data: const <String, Object?>{'error': 'classified'},
            );
          }
          return http.Response('', 404);
        }),
      );

      await expectLater(
        service.setSensitive(
          accountId: 'account-a',
          roomToken: 'rooma123',
          sensitive: false,
        ),
        _throwsRoomSettingsError(RoomSettingsError.rejected),
      );
    },
  );

  test(
    'rejects a success room whose authoritative flag does not match',
    () async {
      final service = serviceWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_capabilities()), 200);
          }
          if (request.url.path.endsWith('/important')) {
            return _roomResponse(isImportant: false);
          }
          return http.Response('', 404);
        }),
      );

      await expectLater(
        service.setImportant(
          accountId: 'account-a',
          roomToken: 'rooma123',
          important: true,
        ),
        _throwsRoomSettingsError(RoomSettingsError.invalidResponse),
      );
    },
  );
}

Matcher _throwsRoomSettingsError(RoomSettingsError code) => throwsA(
  isA<RoomSettingsException>().having((error) => error.code, 'code', code),
);

Map<String, Object?> _capabilities({
  List<String> features = const <String>[
    'important-conversations',
    'sensitive-conversations',
  ],
}) {
  final payload = capabilitiesJson(talkFeatures: features);
  return payload;
}

http.Response _roomResponse({bool? isImportant, bool? isSensitive}) {
  final room = _roomJson();
  if (isImportant != null) room['isImportant'] = isImportant;
  if (isSensitive != null) room['isSensitive'] = isSensitive;
  return _ocsResponse(statusCode: 200, status: 'ok', data: room);
}

http.Response _ocsResponse({
  required int statusCode,
  required String status,
  Object? data = const <Object?>[],
}) => http.Response(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': status,
        'statuscode': statusCode,
        'message': status,
      },
      'data': data,
    },
  }),
  statusCode,
);

Map<String, Object?> _roomJson() {
  final response =
      jsonDecode(
            File(
              '${_repoRoot().path}/contracts/conversation-list/fixtures/'
              'conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
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
