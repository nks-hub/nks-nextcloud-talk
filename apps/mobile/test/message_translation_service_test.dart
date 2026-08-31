import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/message_translation_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'app-password';
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await _insertConversation(database, account);
  });

  tearDown(() => database.close());

  test('loads languages and translates exact account-bound text', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _jsonResponse(_capabilities(translation: true));
      }
      if (request.url.path.endsWith('/translation/languages')) {
        return _jsonResponse(
          _ocs({
            'languages': [
              {
                'from': 'en',
                'fromLabel': 'English',
                'to': 'cs',
                'toLabel': 'Čeština',
              },
            ],
            'languageDetection': true,
          }),
        );
      }
      if (request.url.path.endsWith('/translation/translate')) {
        expect(jsonDecode(request.body), {
          'text': 'Hello {user}',
          'fromLanguage': null,
          'toLanguage': 'cs',
        });
        return _jsonResponse(_ocs({'text': 'Ahoj {user}', 'from': 'en'}));
      }
      return http.Response('', 404);
    });
    final service = _service(accounts, vault, client);

    final languages = await service.languages(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final translated = await service.translate(
      accountId: 'account-a',
      roomToken: 'rooma123',
      text: 'Hello {user}',
      fromLanguage: null,
      toLanguage: 'cs',
    );

    expect(languages.languages.single.to, 'cs');
    expect(translated.text, 'Ahoj {user}');
    expect(requests, hasLength(3));
    expect(
      requests.every((request) => request.headers['authorization'] != null),
      isTrue,
    );
  });

  test('fails closed before language access without capability', () async {
    var translationRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _jsonResponse(_capabilities(translation: false));
      }
      translationRequests++;
      return http.Response('', 500);
    });

    await expectLater(
      _service(
        accounts,
        vault,
        client,
      ).languages(accountId: 'account-a', roomToken: 'rooma123'),
      throwsA(
        isA<MessageTranslationException>().having(
          (error) => error.code,
          'code',
          MessageTranslationError.unsupported,
        ),
      ),
    );
    expect(translationRequests, 0);
  });

  test('rejects a cached room token mismatch before translation', () async {
    await (database.delete(database.cachedConversations)).go();
    final account = (await accounts.getAccount('account-a'))!;
    await _insertConversation(database, account, rawTokenOverride: 'other123');
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('', 500);
    });

    await expectLater(
      _service(
        accounts,
        vault,
        client,
      ).languages(accountId: 'account-a', roomToken: 'rooma123'),
      throwsA(
        isA<MessageTranslationException>().having(
          (error) => error.code,
          'code',
          MessageTranslationError.invalidResponse,
        ),
      ),
    );
    expect(requests, 0);
  });

  for (final entry in const {
    400: MessageTranslationError.invalidInput,
    401: MessageTranslationError.reauthenticationRequired,
    412: MessageTranslationError.unsupported,
    429: MessageTranslationError.rateLimited,
    500: MessageTranslationError.serviceUnavailable,
    503: MessageTranslationError.serviceUnavailable,
  }.entries) {
    test('maps translate HTTP ${entry.key}', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(translation: true));
        }
        return http.Response('', entry.key);
      });

      await expectLater(
        _service(accounts, vault, client).translate(
          accountId: 'account-a',
          roomToken: 'rooma123',
          text: 'Hello',
          fromLanguage: 'en',
          toLanguage: 'cs',
        ),
        throwsA(
          isA<MessageTranslationException>().having(
            (error) => error.code,
            'code',
            entry.value,
          ),
        ),
      );
    });
  }
}

HttpMessageTranslationService _service(
  AccountRepository accounts,
  MemoryCredentialVault vault,
  http.Client client,
) => HttpMessageTranslationService(
  accounts: accounts,
  credentials: vault,
  api: HttpNextcloudApi(client: client),
);

Future<void> _insertConversation(
  AppDatabase database,
  StoredAccount account, {
  String? rawTokenOverride,
}) async {
  final roomJson = _roomJson();
  final storedToken = roomJson['token']! as String;
  if (rawTokenOverride != null) {
    roomJson['token'] = rawTokenOverride;
    roomJson['lastMessage'] = null;
  }
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: account.id,
          token: storedToken,
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
          rawJson: jsonEncode(roomJson),
        ),
      );
}

Map<String, Object?> _roomJson() {
  final root =
      jsonDecode(
            File(
              '../../contracts/conversation-list/fixtures/'
              'conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Map<String, Object?> _capabilities({required bool translation}) {
  final json = capabilitiesJson();
  final ocs = json['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['config'] = <String, Object?>{
    'chat': <String, Object?>{'has-translation-providers': translation},
  };
  return json;
}

Map<String, Object?> _ocs(Object? data) => {
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': data,
  },
};

http.Response _jsonResponse(Object? body, {int statusCode = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
