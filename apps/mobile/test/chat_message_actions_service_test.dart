import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_message_actions_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late MemoryCredentialVault credentials;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    credentials = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    credentials.values['account-a'] = 'fixture-app-password-never-use';
    await _insertRoom(database, _roomJson());
    await _insertMessage(
      database,
      id: 5,
      actorId: 'fixture-user',
      message: 'Original text',
    );
  });

  tearDown(() => database.close());

  // Nextcloud Talk sends PERMISSIONS_DEFAULT (0) in `attendeePermissions`
  // whenever a participant has no per-attendee override, which is the normal
  // case; the effective value lives in `permissions`. Reading the override
  // instead silently closed every permission-gated action, so reactions were
  // unreachable for every ordinary user even though the server allowed them.
  test('only a moderator may delete somebody else\'s message', () async {
    // Measured against Nextcloud 34 before this was wired: the owner of a room
    // deleted a message written by another participant and the server answered
    // 200, turning it into a `message_deleted` notice. An ordinary participant
    // has no such right, so the two roles must not share one flag.
    for (final (participantType, expected) in const <(int, bool)>[
      (1, true), // owner
      (2, true), // moderator
      (6, true), // guest moderator
      (3, false), // ordinary user
      (4, false), // guest
    ]) {
      final room = _roomJson()
        ..['permissions'] = 510
        ..['attendeePermissions'] = 0
        ..['participantType'] = participantType;
      await _insertRoom(database, room);

      final api = _api((request) async {
        expect(request.url.path, endsWith('/capabilities'));
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const ['chat-v2', 'delete-messages'],
            ),
          ),
          200,
        );
      });
      addTearDown(api.close);
      final service = ChatMessageActionsService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      final profile = await service.resolveProfile(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(
        profile.delete,
        isTrue,
        reason: 'everybody may still delete their own message',
      );
      expect(
        profile.deleteAny,
        expected,
        reason: 'participant type $participantType',
      );
    }
  });

  test(
    'offline, the profile comes from the features stored with the account',
    () async {
      // An app started without a network must still offer Reply, Edit and
      // Delete; the server's features are already on the account row.
      await accounts.updateCapabilities('account-a', const {
        'chat-v2',
        'chat-reference-id',
        'chat-replies',
        'edit-messages',
        'delete-messages',
        'reactions',
        'react-permission',
      }, serverThemeColor: null);
      final room = _roomJson()
        ..['permissions'] = 510
        ..['attendeePermissions'] = 0;
      await _insertRoom(database, room);
      final api = _api(
        (request) async => throw http.ClientException('offline'),
      );
      addTearDown(api.close);
      final service = ChatMessageActionsService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      final profile = await service.resolveProfile(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(profile.reply, isTrue);
      expect(profile.edit, isTrue);
      expect(profile.delete, isTrue);
      expect(profile.canReact, isTrue);
      expect(
        profile.scheduled,
        isFalse,
        reason: 'local features need the server',
      );
    },
  );

  test(
    'offline without stored features still reports the network error',
    () async {
      final api = _api(
        (request) async => throw http.ClientException('offline'),
      );
      addTearDown(api.close);
      final service = ChatMessageActionsService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      await expectLater(
        service.resolveProfile(accountId: 'account-a', roomToken: 'rooma123'),
        throwsA(isA<ChatMessageActionException>()),
      );
    },
  );

  test('the default participant may react', () async {
    // PERMISSIONS_MAX_DEFAULT: every permission granted without an override.
    const maxDefaultPermissions = 510;
    final room = _roomJson()
      ..['permissions'] = maxDefaultPermissions
      ..['attendeePermissions'] = 0;
    await _insertRoom(database, room);

    final api = _api((request) async {
      expect(request.url.path, endsWith('/capabilities'));
      return http.Response(
        jsonEncode(
          capabilitiesJson(
            talkFeatures: const ['chat-v2', 'reactions', 'react-permission'],
          ),
        ),
        200,
      );
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    final profile = await service.resolveProfile(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(profile.reactions, isTrue);
    expect(profile.canReact, isTrue);
  });

  test(
    'a participant whose override withholds the react bit may not react',
    () async {
      final room = _roomJson()
        // PERMISSIONS_CUSTOM plus chat, deliberately without PERMISSIONS_REACT.
        ..['permissions'] = 1 | 128
        ..['attendeePermissions'] = 1 | 128;
      await _insertRoom(database, room);

      final api = _api((request) async {
        expect(request.url.path, endsWith('/capabilities'));
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const ['chat-v2', 'reactions', 'react-permission'],
            ),
          ),
          200,
        );
      });
      addTearDown(api.close);
      final service = ChatMessageActionsService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      final profile = await service.resolveProfile(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(profile.reactions, isTrue);
      expect(profile.canReact, isFalse);
    },
  );

  // Verified live against Nextcloud 34.0.1 on 2026-08-26: with `readOnly` set,
  // the server answers edit, delete, react and send alike with `403`. The
  // composer and the reaction picker already hide themselves for a read-only
  // room, but the action sheet still offered Edit and Delete, so both requests
  // were leaving the device only to come back refused.
  test(
    'a read-only room refuses edit and delete without any request',
    () async {
      await _insertRoom(database, _roomJson()..['readOnly'] = 1);

      var mutations = 0;
      final api = _api((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                talkFeatures: const [
                  'chat-v2',
                  'edit-messages',
                  'delete-messages',
                ],
              ),
            ),
            200,
          );
        }
        mutations++;
        return http.Response('{}', 200);
      });
      addTearDown(api.close);
      final service = ChatMessageActionsService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      await expectLater(
        () => service.editMessage(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 5,
          message: 'Updated text',
        ),
        throwsA(
          isA<ChatMessageActionException>().having(
            (error) => error.code,
            'code',
            ChatMessageActionError.actionUnsupported,
          ),
        ),
      );
      await expectLater(
        () => service.deleteMessage(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 5,
        ),
        throwsA(
          isA<ChatMessageActionException>().having(
            (error) => error.code,
            'code',
            ChatMessageActionError.actionUnsupported,
          ),
        ),
      );
      expect(mutations, 0);

      // The cached message stays exactly as it was: a refused action must not
      // leave a locally edited or locally deleted row behind.
      final stored = await chat.getMessage(
        accountId: 'account-a',
        roomToken: 'rooma123',
        messageId: 5,
      );
      expect(stored!.displayText, 'Original text');
      expect(stored.deleted, isFalse);
    },
  );

  test('edits an own message and persists the authoritative text', () async {
    final api = _api((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(talkFeatures: const ['chat-v2', 'edit-messages']),
          ),
          200,
        );
      }
      expect(request.method, 'PUT');
      expect(request.url.path, endsWith('/chat/rooma123/5'));
      expect(request.bodyFields['message'], 'Updated text');
      return http.Response(
        jsonEncode(
          _mutationResponseJson(editedMessageId: 5, message: 'Updated text'),
        ),
        200,
      );
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.editMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
      message: 'Updated text',
    );

    final stored = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
    );
    expect(stored, isNotNull);
    expect(stored!.displayText, 'Updated text');
    final wire = jsonDecode(stored.rawJson) as Map<String, Object?>;
    expect(wire['message'], 'Updated text');
    expect(stored.deleted, isFalse);
  });

  test('projects an edited parent into cached replies', () async {
    await _insertMessage(
      database,
      id: 6,
      actorId: 'other-user',
      message: 'Reply text',
      parent: _messageWire(
        id: 5,
        actorId: 'fixture-user',
        message: 'Original text',
      ),
    );
    final api = _api((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(talkFeatures: const ['chat-v2', 'edit-messages']),
          ),
          200,
        );
      }
      return http.Response(
        jsonEncode(
          _mutationResponseJson(editedMessageId: 5, message: 'Updated text'),
        ),
        200,
      );
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.editMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
      message: 'Updated text',
    );

    final storedReply = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 6,
    );
    final reply = ChatMessage.fromJson(jsonDecode(storedReply!.rawJson));
    expect(reply.parent, isA<ChatFullParent>());
    expect((reply.parent! as ChatFullParent).message.message, 'Updated text');
  });

  test('editing is refused without the edit-messages capability', () async {
    final api = _api((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode(capabilitiesJson(talkFeatures: const ['chat-v2'])),
          200,
        );
      }
      fail('the mutation must not be sent when the capability is missing');
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await expectLater(
      () => service.editMessage(
        accountId: 'account-a',
        roomToken: 'rooma123',
        messageId: 5,
        message: 'Updated text',
      ),
      throwsA(
        isA<ChatMessageActionException>().having(
          (error) => error.code,
          'code',
          ChatMessageActionError.actionUnsupported,
        ),
      ),
    );

    final stored = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
    );
    expect(stored!.displayText, 'Original text');
  });

  test('deletes a message and marks it deleted locally', () async {
    final api = _api((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const ['chat-v2', 'delete-messages'],
            ),
          ),
          200,
        );
      }
      expect(request.method, 'DELETE');
      expect(request.url.path, endsWith('/chat/rooma123/5'));
      return http.Response(
        jsonEncode(_mutationResponseJson(editedMessageId: 5, deleted: true)),
        200,
      );
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.deleteMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
    );

    final stored = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
    );
    expect(stored!.deleted, isTrue);
  });

  test('projects a deleted parent into cached replies', () async {
    await _insertMessage(
      database,
      id: 6,
      actorId: 'other-user',
      message: 'Reply text',
      parent: _messageWire(
        id: 5,
        actorId: 'fixture-user',
        message: 'Original text',
      ),
    );
    final api = _api((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const ['chat-v2', 'delete-messages'],
            ),
          ),
          200,
        );
      }
      return http.Response(
        jsonEncode(_mutationResponseJson(editedMessageId: 5, deleted: true)),
        200,
      );
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.deleteMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
    );

    final storedReply = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 6,
    );
    final reply = ChatMessage.fromJson(jsonDecode(storedReply!.rawJson));
    expect(reply.parent, isA<ChatFullParent>());
    final parent = (reply.parent! as ChatFullParent).message;
    expect(parent.deleted, isTrue);
    expect(parent.message, isEmpty);
  });

  test('adds a reaction and records the aggregate self-membership', () async {
    final api = _api((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(talkFeatures: const ['chat-v2', 'reactions']),
          ),
          200,
        );
      }
      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/reaction/rooma123/5'));
      expect(request.bodyFields['reaction'], '👍');
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(
            _reactionResponseJson({
              '👍': ['fixture-user'],
            }),
          ),
        ),
        200,
      );
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.addReaction(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
      reaction: '👍',
    );

    final stored = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
    );
    final wire = jsonDecode(stored!.rawJson) as Map<String, Object?>;
    expect(wire['reactions'], {'👍': 1});
    expect(wire['reactionsSelf'], ['👍']);
  });

  test('removing a reaction clears it from the cached message', () async {
    await _insertMessage(
      database,
      id: 6,
      actorId: 'someone-else',
      message: 'Reacted message',
      reactions: const {'👍': 1},
      reactionsSelf: const ['👍'],
    );
    final api = _api((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(talkFeatures: const ['chat-v2', 'reactions']),
          ),
          200,
        );
      }
      expect(request.method, 'DELETE');
      expect(request.url.path, endsWith('/reaction/rooma123/6'));
      return http.Response(jsonEncode(_reactionResponseJson(const {})), 200);
    });
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.deleteReaction(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 6,
      reaction: '👍',
    );

    final stored = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 6,
    );
    final wire = jsonDecode(stored!.rawJson) as Map<String, Object?>;
    expect(wire['reactions'], isEmpty);
    expect(wire['reactionsSelf'], isEmpty);
  });

  test('an expired session is reported as reauthentication required', () async {
    final api = _api(
      (_) async => http.Response(jsonEncode(<String, Object?>{}), 401),
    );
    addTearDown(api.close);
    final service = ChatMessageActionsService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await expectLater(
      () => service.deleteMessage(
        accountId: 'account-a',
        roomToken: 'rooma123',
        messageId: 5,
      ),
      throwsA(
        isA<ChatMessageActionException>().having(
          (error) => error.code,
          'code',
          ChatMessageActionError.reauthenticationRequired,
        ),
      ),
    );

    final stored = await chat.getMessage(
      accountId: 'account-a',
      roomToken: 'rooma123',
      messageId: 5,
    );
    expect(
      stored!.displayText,
      'Original text',
      reason: 'a rejected request must never change the cached message',
    );
  });
}

HttpNextcloudApi _api(
  Future<http.Response> Function(http.Request request) handler,
) {
  return HttpNextcloudApi(client: MockClient(handler));
}

Map<String, Object?> _mutationResponseJson({
  required int editedMessageId,
  String message = '',
  bool deleted = false,
  String roomToken = 'rooma123',
}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': _messageWire(
        id: 900 + editedMessageId,
        actorId: 'fixture-user',
        message: deleted ? '' : 'message_edited',
        systemMessage: deleted ? 'message_deleted' : 'message_edited',
        roomToken: roomToken,
        parent: _messageWire(
          id: editedMessageId,
          actorId: 'fixture-user',
          message: message,
          deleted: deleted,
          roomToken: roomToken,
        ),
      ),
    },
  };
}

Map<String, Object?> _reactionResponseJson(
  Map<String, List<String>> reactionsByActor,
) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        for (final entry in reactionsByActor.entries)
          entry.key: [
            for (final actorId in entry.value)
              <String, Object?>{
                'actorType': 'users',
                'actorId': actorId,
                'actorDisplayName': actorId,
                'timestamp': 1724300000,
              },
          ],
      },
    },
  };
}

Map<String, Object?> _messageWire({
  required int id,
  required String actorId,
  required String message,
  String systemMessage = '',
  bool deleted = false,
  String roomToken = 'rooma123',
  Map<String, Object?>? parent,
}) {
  return <String, Object?>{
    'id': id,
    'token': roomToken,
    'actorType': 'users',
    'actorId': actorId,
    'actorDisplayName': actorId,
    'timestamp': 1724300000,
    'systemMessage': systemMessage,
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$id',
    'message': message,
    'messageParameters': const <String, Object?>{},
    'markdown': false,
    'reactions': const <String, Object?>{},
    'reactionsSelf': const <Object?>[],
    'deleted': deleted ? true : null,
    'parent': ?parent,
  };
}

Future<void> _insertMessage(
  AppDatabase database, {
  required int id,
  required String actorId,
  required String message,
  Map<String, Object?> reactions = const {},
  List<Object?> reactionsSelf = const [],
  Map<String, Object?>? parent,
}) {
  final wire =
      _messageWire(id: id, actorId: actorId, message: message, parent: parent)
        ..['reactions'] = reactions
        ..['reactionsSelf'] = reactionsSelf;
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: id,
          actorType: 'users',
          actorId: actorId,
          actorDisplayName: actorId,
          timestamp: 1724300000,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-$id',
          displayText: message,
          deleted: false,
          rawJson: jsonEncode(wire),
        ),
      );
}

Map<String, Object?> _roomJson() {
  final response =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
  room['token'] = 'rooma123';
  room['readOnly'] = 0;
  room.remove('remoteServer');
  return room;
}

Future<void> _insertRoom(AppDatabase database, Map<String, Object?> roomJson) {
  final room = ConversationRoom.fromJson(roomJson);
  return database
      .into(database.cachedConversations)
      .insertOnConflictUpdate(
        CachedConversationsCompanion.insert(
          accountId: 'account-a',
          token: room.token.value,
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
