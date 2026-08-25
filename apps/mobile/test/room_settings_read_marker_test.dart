import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Covers the read marker the "mark as read" notification action drives.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()
      ..values['account-a'] = 'password-a'
      ..values['account-b'] = 'password-b';
    for (final accountId in <String>['account-a', 'account-b']) {
      await accounts.upsertAccount(
        accountId: accountId,
        serverUrl: accountId == 'account-a'
            ? 'https://a.example.invalid'
            : 'https://b.example.invalid',
        loginName: 'user-$accountId',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
    }
  });

  tearDown(() => database.close());

  Future<void> insertRoom({
    required String accountId,
    required String token,
    int? lastMessageId,
  }) async {
    final roomJson = Map<String, Object?>.from(_roomJson())..['token'] = token;
    final lastMessage = roomJson['lastMessage'];
    if (lastMessageId == null) {
      roomJson.remove('lastMessage');
    } else if (lastMessage is Map<String, Object?>) {
      roomJson['lastMessage'] = Map<String, Object?>.from(lastMessage)
        ..['token'] = token
        ..['id'] = lastMessageId;
    }
    final room = ConversationRoom.fromJson(roomJson);
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: accountId,
            token: room.token.value,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            rawJson: jsonEncode(roomJson),
          ),
        );
  }

  RoomSettingsService serviceWith(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return RoomSettingsService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
  }

  test('posts the cached last message id to the account server', () async {
    await insertRoom(
      accountId: 'account-a',
      token: 'rooma123',
      lastMessageId: 4242,
    );
    // The same token exists on the other account and server; the request must
    // never leak across that boundary.
    await insertRoom(
      accountId: 'account-b',
      token: 'rooma123',
      lastMessageId: 99,
    );
    final reads = <({Uri uri, String body, String? authorization})>[];

    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-read-marker',
                  'chat-read-last',
                ],
              ),
            ),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/chat/rooma123/read')) {
          reads.add((
            uri: request.url,
            body: request.body,
            authorization: request.headers['Authorization'],
          ));
          return http.Response(
            jsonEncode(_readOcs(lastReadMessage: 4242)),
            200,
          );
        }
        return http.Response('', 404);
      }),
    );

    await service.markConversationRead(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );

    expect(reads, hasLength(1));
    expect(reads.single.uri.host, 'a.example.invalid');
    expect(reads.single.body, 'lastReadMessage=4242');
    expect(
      reads.single.authorization,
      'Basic ${base64Encode(utf8.encode('user-account-a:password-a'))}',
    );
  });

  test('refuses a room whose cache has no last message', () async {
    await insertRoom(accountId: 'account-a', token: 'rooma123');
    final service = serviceWith(
      MockClient(
        (request) async => request.url.path.endsWith('/cloud/capabilities')
            ? http.Response(
                jsonEncode(
                  capabilitiesJson(
                    talkFeatures: const <String>[
                      'conversation-v4',
                      'chat-v2',
                      'chat-read-marker',
                      'chat-read-last',
                    ],
                  ),
                ),
                200,
              )
            : http.Response('', 404),
      ),
    );

    await expectLater(
      service.markConversationRead(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ),
      throwsA(
        isA<RoomSettingsException>().having(
          (error) => error.code,
          'code',
          RoomSettingsError.invalidResponse,
        ),
      ),
    );
  });

  test('surfaces an expired app password as a re-auth failure', () async {
    await insertRoom(
      accountId: 'account-a',
      token: 'rooma123',
      lastMessageId: 12,
    );
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-read-marker',
                  'chat-read-last',
                ],
              ),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'failure',
                'statuscode': 401,
                'message': 'Unauthorised',
              },
              'data': const <Object?>[],
            },
          }),
          401,
        );
      }),
    );

    await expectLater(
      service.markConversationRead(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ),
      throwsA(
        isA<RoomSettingsException>().having(
          (error) => error.code,
          'code',
          RoomSettingsError.reauthenticationRequired,
        ),
      ),
    );
  });

  test('maps a transport failure to a retryable network error', () async {
    await insertRoom(
      accountId: 'account-a',
      token: 'rooma123',
      lastMessageId: 12,
    );
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-read-marker',
                  'chat-read-last',
                ],
              ),
            ),
            200,
          );
        }
        throw http.ClientException('offline');
      }),
    );

    await expectLater(
      service.markConversationRead(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ),
      throwsA(
        isA<RoomSettingsException>().having(
          (error) => error.code,
          'code',
          RoomSettingsError.network,
        ),
      ),
    );
  });
}

Map<String, Object?> _roomJson() {
  final root =
      readFixtureJson('conversation-list/fixtures/conversations-full.response.json')!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Map<String, Object?> _readOcs({required int lastReadMessage}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'token': 'rooma123',
        'lastReadMessage': lastReadMessage,
        'lastCommonReadMessage': lastReadMessage,
        'unreadMessages': 0,
      },
    },
  };
}
