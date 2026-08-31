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
  return database.select(database.cachedConversations).getSingle();
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

http.Response _capabilities(Iterable<String> features) => http.Response(
  jsonEncode(capabilitiesJson(talkFeatures: features)),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _pollResponse(int statusCode) => http.Response(
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
        'votedSelf': <int>[],
        'votes': <String, int>{},
        'numVoters': 0,
      },
    },
  }),
  statusCode,
  headers: {'content-type': 'application/json'},
);
