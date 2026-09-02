import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Two accounts on two different servers, holding the SAME room token.
///
/// A Talk token is unique per server, not globally, so this collision is
/// ordinary rather than exotic — and it is the one shape where a query or a
/// cache key that forgets the account does not merely show the wrong thing but
/// sends one server's conversation to the other one. The outbox and the root
/// merge are already covered in `chat_projection_isolation_test.dart`; this
/// file covers the three that were left open: where a request goes and with
/// whose credentials, what the read state does, and whether one account's poll
/// can answer the other's.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late MemoryCredentialVault credentials;

  const servers = <String, String>{
    'account-a': 'https://a.example.invalid',
    'account-b': 'https://b.example.invalid',
  };

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    credentials = MemoryCredentialVault();
    for (final entry in servers.entries) {
      await accounts.upsertAccount(
        accountId: entry.key,
        serverUrl: entry.value,
        loginName: 'user-${entry.key}',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
      // Distinct passwords, so a request carrying the wrong one is visible in
      // the recorded Authorization header instead of silently matching.
      credentials.values[entry.key] = 'password-${entry.key}';
      await _insertRoom(database, accountId: entry.key);
    }
  });

  tearDown(() => database.close());

  ChatService serviceWith(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
  }

  test(
    'every request goes to its own server with its own credential',
    () async {
      final seen = <({String account, String host, String? authorization})>[];
      final service = serviceWith(
        MockClient((request) async {
          final authorization = request.headers['authorization'];
          final account = servers.keys.firstWhere(
            (id) => request.url.host.startsWith(id.split('-').last),
            orElse: () => 'unknown',
          );
          seen.add((
            account: account,
            host: request.url.host,
            authorization: authorization,
          ));
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_capabilities()), 200);
          }
          return http.Response('', 304);
        }),
      );

      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await service.syncRoom(accountId: 'account-b', roomToken: 'rooma123');

      expect(seen, isNotEmpty);
      for (final call in seen) {
        final expectedHost = Uri.parse(servers[call.account]!).host;
        expect(
          call.host,
          expectedHost,
          reason: 'a request for ${call.account} reached ${call.host}',
        );
        final credential = base64Encode(
          utf8.encode('user-${call.account}:password-${call.account}'),
        );
        expect(
          call.authorization,
          'Basic $credential',
          reason: '${call.account} sent the wrong credential to ${call.host}',
        );
      }
      // Both servers really were contacted; a run that reached only one would
      // satisfy the loop above without proving anything.
      expect(seen.map((call) => call.host).toSet(), {
        'a.example.invalid',
        'b.example.invalid',
      });
    },
  );

  test('read state moves for one account and leaves the other alone', () async {
    var futureRequests = 0;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_capabilities()), 200);
        }
        if (request.url.host != 'b.example.invalid') {
          return http.Response('', 304);
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-history.response.json',
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '103',
              'X-Chat-Last-Common-Read': '100',
            },
          );
        }
        if (futureRequests++ == 0) {
          return http.Response(
            jsonEncode(_futureMessages()),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '114',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }
        return http.Response('', 304);
      }),
    );

    await service.syncRoom(accountId: 'account-b', roomToken: 'rooma123');

    final scopeB = await chat.getRootScope(
      accountId: 'account-b',
      roomToken: 'rooma123',
    );
    final scopeA = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(scopeB?.futureCursor, '114');
    expect(
      scopeA,
      isNull,
      reason: 'the same token on another server has its own read state',
    );

    final messagesA = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    expect(
      messagesA,
      isEmpty,
      reason: "account A must not inherit account B's messages",
    );
  });

  test(
    "a live poll for one account never answers the other's catch-up",
    () async {
      // catchUpRoom deliberately joins a poll that is already in flight instead
      // of racing it. Joining across accounts would mean waiting for — and then
      // trusting — a request made to a different server.
      final pollReached = Completer<void>();
      final pollAnswer = Completer<http.Response>();
      var accountBRequests = 0;

      final service = serviceWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_capabilities()), 200);
          }
          if (request.url.host == 'a.example.invalid') {
            if (!pollReached.isCompleted) {
              pollReached.complete();
            }
            return pollAnswer.future;
          }
          accountBRequests++;
          return http.Response('', 304);
        }),
      );

      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      addTearDown(binding.close);
      final pollForA = service.syncRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      await pollReached.future;

      await service.catchUpRoom(accountId: 'account-b', roomToken: 'rooma123');

      expect(
        accountBRequests,
        greaterThan(0),
        reason:
            "account B waited on account A's poll instead of asking its own "
            'server',
      );

      pollAnswer.complete(http.Response('', 304));
      await pollForA;
    },
  );
}

Map<String, Object?> _capabilities() => capabilitiesJson(
  talkFeatures: const <String>[
    'conversation-v4',
    'chat-v2',
    'chat-reference-id',
  ],
);

Map<String, Object?> _futureMessages() =>
    jsonDecode(
          jsonEncode(
            readFixtureJson('chat-messages/fixtures/chat-future.response.json'),
          ),
        )!
        as Map<String, Object?>;

Future<void> _insertRoom(
  AppDatabase database, {
  required String accountId,
}) async {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final roomJson = Map<String, Object?>.from(
    rooms.first! as Map<String, Object?>,
  );
  final lastMessage = Map<String, Object?>.from(
    roomJson['lastMessage']! as Map<String, Object?>,
  );
  lastMessage['id'] = 109;
  roomJson['lastMessage'] = lastMessage;
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
          roomName: Value(room.name),
          objectType: Value(room.objectType),
          avatarVersion: Value(room.avatarVersion),
          isCustomAvatar: Value(room.isCustomAvatar),
          rawJson: jsonEncode(roomJson),
        ),
      );
}
