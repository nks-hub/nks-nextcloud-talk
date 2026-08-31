import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    vault = MemoryCredentialVault();
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026),
    );
    vault.values[account.id] = 'app-password';
    conversation = await _insertConversation(database, account);
  });

  tearDown(() => database.close());

  test(
    'capability-gated create reaches one POST and confirms the poll',
    () async {
      var pollPosts = 0;
      final service = _service(
        accounts,
        chat,
        vault,
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _capabilities(const ['chat-v2', 'talk-polls']);
          }
          pollPosts++;
          final body = (jsonDecode(request.body) as Map)
              .cast<String, Object?>();
          expect(body['question'], 'Lunch?');
          expect(body['options'], ['Pizza', 'Salad']);
          return _pollResponse(201);
        }),
      );

      final poll = await service.create(
        key: (
          accountId: account.id,
          roomToken: conversation.token,
          threadId: null,
        ),
        question: 'Lunch?',
        options: const ['Pizza', 'Salad'],
        resultMode: PollResultMode.public,
        maxVotes: 1,
      );

      expect(poll.id, 7);
      expect(pollPosts, 1);
    },
  );

  test('missing capability fails before the mutation', () async {
    var pollPosts = 0;
    final service = _service(
      accounts,
      chat,
      vault,
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _capabilities(const ['chat-v2']);
        }
        pollPosts++;
        return _pollResponse(201);
      }),
    );

    await expectLater(
      service.create(
        key: (
          accountId: account.id,
          roomToken: conversation.token,
          threadId: null,
        ),
        question: 'Lunch?',
        options: const ['Pizza', 'Salad'],
        resultMode: PollResultMode.public,
        maxVotes: 1,
      ),
      throwsA(
        isA<PollServiceException>().having(
          (error) => error.code,
          'code',
          PollServiceError.unsupported,
        ),
      ),
    );
    expect(pollPosts, 0);
  });

  test(
    'disconnect after create POST is ambiguous and is not retried',
    () async {
      var pollPosts = 0;
      final service = _service(
        accounts,
        chat,
        vault,
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _capabilities(const ['chat-v2', 'talk-polls']);
          }
          pollPosts++;
          throw http.ClientException('fixture disconnect', request.url);
        }),
      );

      await expectLater(
        service.create(
          key: (
            accountId: account.id,
            roomToken: conversation.token,
            threadId: null,
          ),
          question: 'Lunch?',
          options: const ['Pizza', 'Salad'],
          resultMode: PollResultMode.public,
          maxVotes: 1,
        ),
        throwsA(
          isA<PollServiceException>().having(
            (error) => error.code,
            'code',
            PollServiceError.ambiguous,
          ),
        ),
      );
      expect(pollPosts, 1);
    },
  );

  test('second participant can show and vote in a read-only room', () async {
    final participant = await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'user-b',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026),
    );
    vault.values[participant.id] = 'participant-password';
    final participantConversation = await _insertConversation(
      database,
      participant,
    );
    await _replaceConversation(database, participantConversation, {
      'readOnly': 1,
      'permissions': 0,
    });
    var getRequests = 0;
    var voteRequests = 0;
    final service = _service(
      accounts,
      chat,
      vault,
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _capabilities(const ['chat-v2', 'talk-polls']);
        }
        if (request.method == 'GET') {
          getRequests++;
          return _pollResponse(200, hideVotes: true);
        }
        voteRequests++;
        return _pollResponse(200, votedSelf: const [1]);
      }),
    );
    final key = (
      accountId: participant.id,
      roomToken: participantConversation.token,
      threadId: null,
    );

    final poll = await service.load(key: key, pollId: 7);
    expect(poll.actorId, 'user-a');
    expect(poll.votes, isEmpty);
    final voted = await service.vote(key: key, poll: poll, optionIds: [1]);

    expect(voted.votedSelf, [1]);
    expect(getRequests, 1);
    expect(voteRequests, 1);
  });

  test('deleted named thread root rejects create before HTTP', () async {
    await _insertThreadRoot(
      database,
      accountId: account.id,
      roomToken: conversation.token,
      deleted: true,
    );
    var requests = 0;
    final service = _service(
      accounts,
      chat,
      vault,
      MockClient((request) async {
        requests++;
        return _capabilities(const ['chat-v2', 'talk-polls', 'threads']);
      }),
    );

    await expectLater(
      service.create(
        key: (
          accountId: account.id,
          roomToken: conversation.token,
          threadId: 777,
        ),
        question: 'Lunch?',
        options: const ['Pizza', 'Salad'],
        resultMode: PollResultMode.public,
        maxVotes: 1,
      ),
      throwsA(
        isA<PollServiceException>().having(
          (error) => error.code,
          'code',
          PollServiceError.contextMissing,
        ),
      ),
    );
    expect(requests, 0);
  });

  test('room scope is revalidated after capability network read', () async {
    var pollPosts = 0;
    final service = _service(
      accounts,
      chat,
      vault,
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          await _replaceConversation(database, conversation, {'readOnly': 1});
          return _capabilities(const ['chat-v2', 'talk-polls']);
        }
        pollPosts++;
        return _pollResponse(201);
      }),
    );

    await expectLater(
      service.create(
        key: (
          accountId: account.id,
          roomToken: conversation.token,
          threadId: null,
        ),
        question: 'Lunch?',
        options: const ['Pizza', 'Salad'],
        resultMode: PollResultMode.public,
        maxVotes: 1,
      ),
      throwsA(isA<PollServiceException>()),
    );
    expect(pollPosts, 0);
  });
}

PollService _service(
  AccountRepository accounts,
  ChatRepository chat,
  MemoryCredentialVault vault,
  http.Client client,
) => PollService(
  accounts: accounts,
  chat: chat,
  credentials: vault,
  api: HttpNextcloudApi(client: client),
);

Future<CachedConversation> _insertConversation(
  AppDatabase database,
  StoredAccount account,
) async {
  final roomJson = _roomJson();
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: account.id,
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
  return (database.select(
    database.cachedConversations,
  )..where((row) => row.accountId.equals(account.id))).getSingle();
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
  final room = ((root['ocs'] as Map<String, Object?>)['data'] as List).first;
  return Map<String, Object?>.from(room as Map<String, Object?>);
}

Future<void> _replaceConversation(
  AppDatabase database,
  CachedConversation conversation,
  Map<String, Object?> overrides,
) async {
  final raw = jsonDecode(conversation.rawJson) as Map<String, Object?>
    ..addAll(overrides);
  await (database.update(database.cachedConversations)..where(
        (row) =>
            row.accountId.equals(conversation.accountId) &
            row.token.equals(conversation.token),
      ))
      .write(CachedConversationsCompanion(rawJson: Value(jsonEncode(raw))));
}

Future<void> _insertThreadRoot(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
  required bool deleted,
}) async {
  final response =
      jsonDecode(
            File(
              '../../contracts/chat-messages/fixtures/'
              'chat-thread-future.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final message =
      ((response['ocs'] as Map<String, Object?>)['data'] as List).single
          as Map<String, Object?>;
  final root =
      Map<String, Object?>.from(message['parent'] as Map<String, Object?>)
        ..['id'] = 777
        ..['token'] = roomToken
        ..['threadId'] = 777
        ..['isThread'] = true
        ..['threadTitle'] = 'Named thread';
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: 777,
          actorType: 'users',
          actorId: 'user-a',
          actorDisplayName: 'User A',
          timestamp: 1787443000,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '',
          displayText: 'Named thread',
          deleted: deleted,
          threadId: const Value(777),
          rawJson: jsonEncode(root),
        ),
      );
}

http.Response _capabilities(Iterable<String> features) => http.Response(
  jsonEncode(capabilitiesJson(talkFeatures: features)),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _pollResponse(
  int statusCode, {
  List<int> votedSelf = const [],
  bool hideVotes = false,
}) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': statusCode},
      'data': {
        'id': 7,
        'question': 'Lunch?',
        'options': ['Pizza', 'Salad'],
        'actorType': 'users',
        'actorId': 'user-a',
        'actorDisplayName': 'User A',
        'status': 0,
        'resultMode': 0,
        'maxVotes': 1,
        'votedSelf': votedSelf,
        'votes': hideVotes || statusCode == 201
            ? <Object?>[]
            : <String, int>{if (votedSelf.isNotEmpty) 'option-1': 1},
        'numVoters': votedSelf.isEmpty ? 0 : 1,
      },
    },
  }),
  statusCode,
  headers: {'content-type': 'application/json'},
);
