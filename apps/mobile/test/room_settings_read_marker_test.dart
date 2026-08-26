import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
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
      chat: ChatRepository(database),
      credentials: vault,
      api: api,
    );
  }

  test(
    'posts and persists the explicitly visible account-room message',
    () async {
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
              jsonEncode(_readOcs(lastReadMessage: 4241)),
              200,
            );
          }
          return http.Response('', 404);
        }),
      );

      await service.markConversationRead(
        accountId: 'account-a',
        roomToken: 'rooma123',
        lastReadMessage: 4241,
      );

      expect(reads, hasLength(1));
      expect(reads.single.uri.host, 'a.example.invalid');
      expect(reads.single.body, 'lastReadMessage=4241');
      expect(
        reads.single.authorization,
        'Basic ${base64Encode(utf8.encode('user-account-a:password-a'))}',
      );
      final storedA = await accounts.getConversation(
        accountId: 'account-a',
        token: 'rooma123',
      );
      final storedB = await accounts.getConversation(
        accountId: 'account-b',
        token: 'rooma123',
      );
      final wireA = jsonDecode(storedA!.rawJson) as Map<String, Object?>;
      final wireB = jsonDecode(storedB!.rawJson) as Map<String, Object?>;
      expect(storedA.unreadMessages, 0);
      expect(wireA['lastReadMessage'], 4241);
      expect(wireA['lastCommonReadMessage'], 4241);
      expect(wireB['lastReadMessage'], isNot(4241));
      final scope = await ChatRepository(
        database,
      ).getScope(accountId: 'account-a', roomToken: 'rooma123', threadId: null);
      expect(scope?.lastReadMessage, 4241);
      expect(scope?.lastCommonRead, '4241');
    },
  );

  test('serializes auto-read and mark-unread for the same room', () async {
    await insertRoom(
      accountId: 'account-a',
      token: 'rooma123',
      lastMessageId: 20,
    );
    final firstReadStarted = Completer<void>();
    final firstReadResponse = Completer<http.Response>();
    final operations = <String>[];
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
                  'chat-unread',
                ],
              ),
            ),
            200,
          );
        }
        if (request.method == 'POST') {
          final target = int.parse(
            Uri.splitQueryString(request.body)['lastReadMessage']!,
          );
          operations.add('read:$target');
          firstReadStarted.complete();
          return firstReadResponse.future;
        }
        if (request.method == 'DELETE') {
          operations.add('unread');
          return http.Response(
            jsonEncode(_readOcs(lastReadMessage: 19, unreadMessages: 1)),
            200,
          );
        }
        return http.Response('', 404);
      }),
    );

    final read = service.markConversationRead(
      accountId: 'account-a',
      roomToken: 'rooma123',
      lastReadMessage: 20,
    );
    await firstReadStarted.future;
    final unread = service.markConversationUnread(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await Future<void>.delayed(Duration.zero);
    expect(operations, ['read:20']);

    firstReadResponse.complete(
      http.Response(jsonEncode(_readOcs(lastReadMessage: 20)), 200),
    );
    await Future.wait([read, unread]);
    expect(operations, ['read:20', 'unread']);
    final scope = await ChatRepository(
      database,
    ).getScope(accountId: 'account-a', roomToken: 'rooma123', threadId: null);
    expect(scope?.lastReadMessage, 19);
    expect(scope?.unreadMessages, 1);
  });

  test('serializes mark-unread before a later read in the same room', () async {
    await insertRoom(
      accountId: 'account-a',
      token: 'rooma123',
      lastMessageId: 20,
    );
    final unreadStarted = Completer<void>();
    final unreadResponse = Completer<http.Response>();
    final operations = <String>[];
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
                  'chat-unread',
                ],
              ),
            ),
            200,
          );
        }
        if (request.method == 'DELETE') {
          operations.add('unread');
          unreadStarted.complete();
          return unreadResponse.future;
        }
        if (request.method == 'POST') {
          final target = int.parse(
            Uri.splitQueryString(request.body)['lastReadMessage']!,
          );
          operations.add('read:$target');
          return http.Response(
            jsonEncode(_readOcs(lastReadMessage: target)),
            200,
          );
        }
        return http.Response('', 404);
      }),
    );

    final unread = service.markConversationUnread(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await unreadStarted.future;
    final read = service.markConversationRead(
      accountId: 'account-a',
      roomToken: 'rooma123',
      lastReadMessage: 20,
    );
    await Future<void>.delayed(Duration.zero);
    expect(operations, ['unread']);

    unreadResponse.complete(
      http.Response(
        jsonEncode(_readOcs(lastReadMessage: 19, unreadMessages: 1)),
        200,
      ),
    );
    await Future.wait([unread, read]);
    expect(operations, ['unread', 'read:20']);
    final scope = await ChatRepository(
      database,
    ).getScope(accountId: 'account-a', roomToken: 'rooma123', threadId: null);
    expect(scope?.lastReadMessage, 20);
    expect(scope?.unreadMessages, 0);
  });

  test('does not serialize read markers across account boundaries', () async {
    for (final accountId in <String>['account-a', 'account-b']) {
      await insertRoom(
        accountId: accountId,
        token: 'rooma123',
        lastMessageId: 20,
      );
    }
    final accountAStarted = Completer<void>();
    final accountAResponse = Completer<http.Response>();
    final hosts = <String>[];
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
        hosts.add(request.url.host);
        if (request.url.host == 'a.example.invalid') {
          accountAStarted.complete();
          return accountAResponse.future;
        }
        return http.Response(jsonEncode(_readOcs(lastReadMessage: 20)), 200);
      }),
    );

    final accountARead = service.markConversationRead(
      accountId: 'account-a',
      roomToken: 'rooma123',
      lastReadMessage: 20,
    );
    await accountAStarted.future;
    await service.markConversationRead(
      accountId: 'account-b',
      roomToken: 'rooma123',
      lastReadMessage: 20,
    );
    expect(hosts, ['a.example.invalid', 'b.example.invalid']);

    accountAResponse.complete(
      http.Response(jsonEncode(_readOcs(lastReadMessage: 20)), 200),
    );
    await accountARead;
  });

  test('does not serialize different rooms on the same account', () async {
    for (final roomToken in <String>['rooma123', 'roomb123']) {
      await insertRoom(
        accountId: 'account-a',
        token: roomToken,
        lastMessageId: 20,
      );
    }
    final roomAStarted = Completer<void>();
    final roomAResponse = Completer<http.Response>();
    final rooms = <String>[];
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
        final roomToken = request.url.path.contains('/chat/rooma123/read')
            ? 'rooma123'
            : 'roomb123';
        rooms.add(roomToken);
        if (roomToken == 'rooma123') {
          roomAStarted.complete();
          return roomAResponse.future;
        }
        return http.Response(
          jsonEncode(_readOcs(lastReadMessage: 20, roomToken: roomToken)),
          200,
        );
      }),
    );

    final roomARead = service.markConversationRead(
      accountId: 'account-a',
      roomToken: 'rooma123',
      lastReadMessage: 20,
    );
    await roomAStarted.future;
    await service.markConversationRead(
      accountId: 'account-a',
      roomToken: 'roomb123',
      lastReadMessage: 20,
    );
    expect(rooms, ['rooma123', 'roomb123']);

    roomAResponse.complete(
      http.Response(jsonEncode(_readOcs(lastReadMessage: 20)), 200),
    );
    await roomARead;
  });

  test('maps a database write failure and releases the room lane', () async {
    await insertRoom(
      accountId: 'account-a',
      token: 'rooma123',
      lastMessageId: 12,
    );
    var reads = 0;
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
        reads++;
        return http.Response(jsonEncode(_readOcs(lastReadMessage: 12)), 200);
      }),
    );
    await database.customStatement('''
      CREATE TRIGGER fail_read_marker_conversation_update
      BEFORE UPDATE ON cached_conversations
      BEGIN
        SELECT RAISE(ABORT, 'forced read marker rollback');
      END
    ''');

    await expectLater(
      service.markConversationRead(
        accountId: 'account-a',
        roomToken: 'rooma123',
        lastReadMessage: 12,
      ),
      throwsA(
        isA<RoomSettingsException>().having(
          (error) => error.code,
          'code',
          RoomSettingsError.invalidResponse,
        ),
      ),
    );
    await database.customStatement(
      'DROP TRIGGER fail_read_marker_conversation_update',
    );
    await service.markConversationRead(
      accountId: 'account-a',
      roomToken: 'rooma123',
      lastReadMessage: 12,
    );
    expect(reads, 2);
  });

  test(
    'propagates preparation StateError and releases the room lane',
    () async {
      await insertRoom(
        accountId: 'account-a',
        token: 'rooma123',
        lastMessageId: 12,
      );

      Future<void> setPayloadToken(String token) async {
        final conversation = await accounts.getConversation(
          accountId: 'account-a',
          token: 'rooma123',
        );
        final payload =
            jsonDecode(conversation!.rawJson) as Map<String, Object?>
              ..['token'] = token;
        final lastMessage = payload['lastMessage'];
        if (lastMessage is Map<String, Object?>) {
          payload['lastMessage'] = Map<String, Object?>.from(lastMessage)
            ..['token'] = token;
        }
        await (database.update(database.cachedConversations)..where(
              (row) =>
                  row.accountId.equals('account-a') &
                  row.token.equals('rooma123'),
            ))
            .write(
              CachedConversationsCompanion(rawJson: Value(jsonEncode(payload))),
            );
      }

      await setPayloadToken('wrongroom');
      var reads = 0;
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
          reads++;
          return http.Response(jsonEncode(_readOcs(lastReadMessage: 12)), 200);
        }),
      );

      await expectLater(
        service.markConversationRead(
          accountId: 'account-a',
          roomToken: 'rooma123',
          lastReadMessage: 12,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Conversation token does not match its payload',
          ),
        ),
      );
      expect(reads, 0);

      await setPayloadToken('rooma123');
      await service.markConversationRead(
        accountId: 'account-a',
        roomToken: 'rooma123',
        lastReadMessage: 12,
      );
      expect(reads, 1);
    },
  );

  test(
    'propagates programming errors and still releases the room lane',
    () async {
      await insertRoom(
        accountId: 'account-a',
        token: 'rooma123',
        lastMessageId: 12,
      );
      var reads = 0;
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
          reads++;
          if (reads == 1) {
            await (database.update(database.chatScopes)..where(
                  (scope) =>
                      scope.accountId.equals('account-a') &
                      scope.roomToken.equals('rooma123') &
                      scope.scopeKey.equals('network-root'),
                ))
                .write(
                  const ChatScopesCompanion(scopeKey: Value('invalid-scope')),
                );
          }
          return http.Response(jsonEncode(_readOcs(lastReadMessage: 12)), 200);
        }),
      );

      await expectLater(
        service.markConversationRead(
          accountId: 'account-a',
          roomToken: 'rooma123',
          lastReadMessage: 12,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Stored chat scope key is invalid',
          ),
        ),
      );
      await (database.delete(database.chatScopes)..where(
            (scope) =>
                scope.accountId.equals('account-a') &
                scope.roomToken.equals('rooma123') &
                scope.scopeKey.equals('invalid-scope'),
          ))
          .go();

      await service.markConversationRead(
        accountId: 'account-a',
        roomToken: 'rooma123',
        lastReadMessage: 12,
      );
      expect(reads, 2);
    },
  );

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

  test('maps a rejected local read merge to invalid response', () async {
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
        if (request.method == 'POST' &&
            request.url.path.endsWith('/chat/rooma123/read')) {
          await (database.delete(
            database.chatScopes,
          )..where((scope) => scope.accountId.equals('account-a'))).go();
          return http.Response(jsonEncode(_readOcs(lastReadMessage: 12)), 200);
        }
        return http.Response('', 404);
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
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Map<String, Object?> _readOcs({
  required int lastReadMessage,
  int unreadMessages = 0,
  String roomToken = 'rooma123',
}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'token': roomToken,
        'lastReadMessage': lastReadMessage,
        'lastCommonReadMessage': lastReadMessage,
        'unreadMessages': unreadMessages,
      },
    },
  };
}
