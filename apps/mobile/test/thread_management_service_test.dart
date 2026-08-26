import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/data/thread_repository.dart';
import 'package:nextcloudtalk/features/threads/thread_management_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

const _server = 'https://cloud.example.invalid';
const _accountId = 'account-a';
const _roomToken = 'rooma123';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late ThreadRepository threads;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    threads = ThreadRepository(database);
    vault = MemoryCredentialVault()..values[_accountId] = 'fixture-password';
    await _insertAccount(accounts, _accountId, loginName: 'user-a');
    await _insertRoom(database, accountId: _accountId);
  });

  tearDown(() => database.close());

  ThreadManagementService service(HttpNextcloudApi api) {
    return ThreadManagementService(
      accounts: accounts,
      chat: chat,
      threads: threads,
      credentials: vault,
      api: api,
    );
  }

  test(
    'recent refresh sends bounded room request then replaces cache',
    () async {
      final richRequests = <http.Request>[];
      final api = _api((request) {
        richRequests.add(request);
        return _fixtureResponse('recent-threads-success');
      });
      addTearDown(api.close);

      final result = await service(
        api,
      ).refreshRecent(accountId: _accountId, roomToken: _roomToken);

      expect(result.single.threadId, 120);
      expect(richRequests, hasLength(1));
      expect(richRequests.single.method, 'GET');
      expect(richRequests.single.url.path, endsWith('/threads/recent'));
      expect(richRequests.single.url.queryParameters['limit'], '50');
      final stored = await threads.listAccount(_accountId);
      expect(stored.single.threadId, 120);
      expect(stored.single.recent, isTrue);
    },
  );

  test(
    'failed subscribed page leaves the previous complete cache intact',
    () async {
      await threads.replaceSubscribed(
        accountId: _accountId,
        server: ServerBase.parse(_server),
        values: <RichChatThread>[_thread(id: 40, roomToken: _roomToken)],
      );
      final offsets = <String?>[];
      final api = _api((request) {
        offsets.add(request.url.queryParameters['offset']);
        if (offsets.length == 1) {
          return _ocsResponse(
            statusCode: 200,
            data: List<Object?>.generate(
              100,
              (index) => _threadWire(
                id: 1000 + index,
                roomToken: 'room${index.toString().padLeft(4, '0')}',
              ),
            ),
          );
        }
        return _ocsResponse(statusCode: 503, data: const <String, Object?>{});
      });
      addTearDown(api.close);

      await expectLater(
        service(api).refreshSubscribed(accountId: _accountId),
        throwsA(
          isA<ThreadManagementException>().having(
            (error) => error.code,
            'code',
            ThreadManagementError.serviceUnavailable,
          ),
        ),
      );

      expect(offsets, <String?>['0', '100']);
      final stored = await threads.listAccount(_accountId);
      expect(stored, hasLength(1));
      expect(stored.single.threadId, 40);
      expect(stored.single.subscribed, isTrue);
    },
  );

  test(
    'detail exposes author rename and writable chat notification policy',
    () async {
      final api = _api((_) => _fixtureResponse('thread-detail-success'));
      addTearDown(api.close);

      final access = await service(
        api,
      ).loadDetail(accountId: _accountId, roomToken: _roomToken, threadId: 120);

      expect(access.canRename, isTrue);
      expect(access.canChangeNotifications, isTrue);
      final cached = await threads.get(
        accountId: _accountId,
        roomToken: _roomToken,
        threadId: 120,
      );
      expect(cached?.detailed, isTrue);
      expect(
        await chat.getMessage(
          accountId: _accountId,
          roomToken: _roomToken,
          messageId: 120,
        ),
        isNotNull,
      );
    },
  );

  test('expired root is renameable only by a moderator', () async {
    final expired = _fixtureBody('thread-detail-success');
    final data = _ocsData(expired) as Map<String, Object?>;
    data['first'] = null;
    final deniedApi = _api((_) => _jsonResponse(expired, 200));
    addTearDown(deniedApi.close);

    await expectLater(
      service(deniedApi).rename(
        accountId: _accountId,
        roomToken: _roomToken,
        threadId: 120,
        title: 'Renamed',
      ),
      throwsA(
        isA<ThreadManagementException>().having(
          (error) => error.code,
          'code',
          ThreadManagementError.permissionDenied,
        ),
      ),
    );

    await _insertRoom(database, accountId: _accountId, participantType: 2);
    var puts = 0;
    final moderatorApi = _api((request) {
      if (request.method == 'PUT') {
        puts++;
        return _fixtureResponse('thread-rename-success');
      }
      return _jsonResponse(expired, 200);
    });
    addTearDown(moderatorApi.close);

    final updated = await service(moderatorApi).rename(
      accountId: _accountId,
      roomToken: _roomToken,
      threadId: 120,
      title: 'Updated design',
    );
    expect(puts, 1);
    expect(updated.thread.title, 'Updated design');
  });

  test(
    'ambiguous rename is sent once and is never cached as success',
    () async {
      var puts = 0;
      final api = _api((request) {
        if (request.method == 'PUT') {
          puts++;
          return _ocsResponse(statusCode: 503, data: const <String, Object?>{});
        }
        return _fixtureResponse('thread-detail-success');
      });
      addTearDown(api.close);

      await expectLater(
        service(api).rename(
          accountId: _accountId,
          roomToken: _roomToken,
          threadId: 120,
          title: 'Uncertain title',
        ),
        throwsA(
          isA<ThreadManagementException>().having(
            (error) => error.code,
            'code',
            ThreadManagementError.ambiguous,
          ),
        ),
      );

      expect(puts, 1);
      expect(await threads.listAccount(_accountId), isEmpty);
    },
  );

  test(
    'notification policy rejects read-only room before any mutation',
    () async {
      await _insertRoom(database, accountId: _accountId, readOnly: 1);
      var mutations = 0;
      final api = _api((request) {
        mutations++;
        return _fixtureResponse('thread-notify-success');
      });
      addTearDown(api.close);

      await expectLater(
        service(api).setNotificationLevel(
          accountId: _accountId,
          roomToken: _roomToken,
          threadId: 120,
          level: 3,
        ),
        throwsA(
          isA<ThreadManagementException>().having(
            (error) => error.code,
            'code',
            ThreadManagementError.permissionDenied,
          ),
        ),
      );
      expect(mutations, 0);
    },
  );

  test('401 mutation reauthenticates only the target account', () async {
    const accountB = 'account-b';
    await _insertAccount(accounts, accountB, loginName: 'user-b');
    await chat.recordCapabilities(
      accountId: accountB,
      talkFeatures: const <String>{'chat-v2', 'threads'},
      observedAt: DateTime.utc(2026, 8, 26),
    );
    final api = _api(
      (_) => _ocsResponse(statusCode: 401, data: const <String, Object?>{}),
    );
    addTearDown(api.close);

    await expectLater(
      service(api).setNotificationLevel(
        accountId: _accountId,
        roomToken: _roomToken,
        threadId: 120,
        level: 3,
      ),
      throwsA(
        isA<ThreadManagementException>().having(
          (error) => error.code,
          'code',
          ThreadManagementError.reauthenticationRequired,
        ),
      ),
    );

    final target = await chat.loadRuntimeForTesting(_accountId);
    final survivor = await chat.loadRuntimeForTesting(accountB);
    expect(
      target.accounts[AccountId.parse(_accountId)]?.lane,
      ChatAccountLane.reauthenticationRequired,
    );
    expect(
      survivor.accounts[AccountId.parse(accountB)]?.lane,
      ChatAccountLane.ready,
    );
  });
}

HttpNextcloudApi _api(
  FutureOr<http.Response> Function(http.Request request) richHandler,
) {
  return HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/ocs/v2.php/cloud/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const <String>[
                'conversation-v4',
                'chat-v2',
                'threads',
              ],
            ),
          ),
          200,
        );
      }
      return richHandler(request);
    }),
  );
}

Future<void> _insertAccount(
  AccountRepository accounts,
  String accountId, {
  required String loginName,
}) {
  return accounts.upsertAccount(
    accountId: accountId,
    serverUrl: _server,
    loginName: loginName,
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 8, 26),
  );
}

Future<void> _insertRoom(
  AppDatabase database, {
  required String accountId,
  int participantType = 3,
  int permissions = 128,
  int readOnly = 0,
  int lobbyState = 0,
}) {
  final raw = _roomJson()
    ..['participantType'] = participantType
    ..['permissions'] = permissions
    ..['readOnly'] = readOnly
    ..['lobbyState'] = lobbyState;
  final room = ConversationRoom.fromJson(raw);
  return database
      .into(database.cachedConversations)
      .insertOnConflictUpdate(
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
          rawJson: jsonEncode(raw),
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
  room['token'] = _roomToken;
  room.remove('remoteServer');
  return room;
}

RichChatThread _thread({required int id, required String roomToken}) {
  return RichChatThread.fromJson(_threadWire(id: id, roomToken: roomToken));
}

Map<String, Object?> _threadWire({required int id, required String roomToken}) {
  return <String, Object?>{
    'thread': <String, Object?>{
      'id': id,
      'roomToken': roomToken,
      'title': 'Thread $id',
      'lastMessageId': id,
      'lastActivity': 1724300000 + id,
      'numReplies': 0,
    },
    'attendee': const <String, Object?>{'notificationLevel': 1},
    'first': null,
    'last': null,
  };
}

http.Response _fixtureResponse(String id) {
  final body = _fixtureBody(id);
  final meta =
      (body['ocs']! as Map<String, Object?>)['meta']! as Map<String, Object?>;
  return _jsonResponse(body, meta['statuscode']! as int);
}

Map<String, Object?> _fixtureBody(String id) {
  final manifest =
      readFixtureJson('rich-chat/fixtures/responses.cases.json')!
          as Map<String, Object?>;
  final cases = manifest['cases']! as List<Object?>;
  final item = cases.cast<Map<String, Object?>>().singleWhere(
    (candidate) => candidate['id'] == id,
  );
  return jsonDecode(jsonEncode(item['body'])) as Map<String, Object?>;
}

Object? _ocsData(Map<String, Object?> body) {
  return (body['ocs']! as Map<String, Object?>)['data'];
}

http.Response _ocsResponse({required int statusCode, required Object? data}) {
  final success = statusCode >= 200 && statusCode < 300;
  return _jsonResponse(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': success ? 'ok' : 'failure',
        'statuscode': statusCode,
        'message': success ? 'OK' : 'Failure',
      },
      'data': data,
    },
  }, statusCode);
}

http.Response _jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}
