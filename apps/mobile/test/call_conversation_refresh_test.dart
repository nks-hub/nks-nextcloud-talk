import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/call_session_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_controller.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_service.dart';
import 'package:nextcloudtalk/features/conversations/conversation_sync_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test(
    'required refresh reports caller cancellation without claiming completion',
    () async {
      final harness = await _RefreshHarness.create();
      addTearDown(harness.close);
      harness.blockList = true;
      final cancellation = Completer<void>();
      final sync = ConversationSyncService(
        accounts: harness.accounts,
        credentials: harness.vault,
        api: harness.api,
      );
      final pending = sync.syncConfirmed(
        'account-a',
        forceFull: true,
        abortTrigger: cancellation.future,
      );
      await harness.listStarted.future.timeout(const Duration(seconds: 2));
      cancellation.complete();
      expect(await pending.timeout(const Duration(seconds: 2)), isFalse);
      harness.releaseList.complete();
    },
  );
  test(
    'best-effort sync preserves the void error-handler contract of push wakes',
    () async {
      final harness = await _RefreshHarness.create();
      addTearDown(harness.close);
      harness.failLists = true;
      var caught = false;
      await ConversationSyncService(
        accounts: harness.accounts,
        credentials: harness.vault,
        api: harness.api,
      ).sync('account-a').catchError((Object _, StackTrace _) {
        caught = true;
      }, test: (error) => error is ConversationSyncException);
      expect(caught, isTrue);
    },
  );
  for (final active in [false, true]) {
    test(
      'resolver preserves ${active ? 'active' : 'inactive'} metadata for call preflight',
      () async {
        final harness = await _RefreshHarness.create();
        addTearDown(harness.close);
        if (active) await harness.activate();
        final session = await harness.resolver.refresh('account-a', 'rooma123');
        expect(session?.value, active ? 'active-session' : '0');
        expect(harness.lists, 1);
      },
    );
  }

  test(
    'cancelled force-full refresh cannot return a cached nonzero session',
    () async {
      final harness = await _RefreshHarness.create();
      addTearDown(harness.close);
      await harness.activate();
      expect(
        (await harness.resolver.refresh('account-a', 'rooma123'))?.value,
        'active-session',
      );
      harness.blockList = true;
      final pending = harness.resolver.refresh('account-a', 'rooma123');
      await harness.listStarted.future.timeout(const Duration(seconds: 2));
      await harness.api.clearAccountSession('account-a');
      harness.releaseList.complete();
      expect(await pending.timeout(const Duration(seconds: 2)), isNull);
      final cached = await harness.accounts.getConversation(
        accountId: 'account-a',
        token: 'rooma123',
      );
      expect(
        ConversationRoom.fromJson(jsonDecode(cached!.rawJson)).sessionId.value,
        'active-session',
      );
    },
  );

  test('call lifecycle activates an inactive room before joining', () async {
    final harness = await _RefreshHarness.create();
    addTearDown(harness.close);
    final lifecycle = CallLifecycleService(
      accounts: harness.accounts,
      chat: ChatRepository(harness.database),
      sessions: CallLifecycleSessionRepository(harness.database),
      credentials: harness.vault,
      api: harness.api,
      refreshConversationSession: harness.resolver.refresh,
    );
    addTearDown(lifecycle.dispose);
    final joined = await lifecycle.join(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(joined.phase, CallLifecyclePhase.joined);
    expect(joined.authority.nextcloudSessionId.value, 'active-session');
    expect(
      harness.events.indexOf('list'),
      lessThan(harness.events.indexOf('activate')),
    );
    expect(
      harness.events.indexOf('activate'),
      lessThan(harness.events.indexOf('join')),
    );
    expect(harness.events.where((event) => event == 'join'), hasLength(1));
  });
}

final class _RefreshHarness {
  _RefreshHarness(this.database, this.accounts, this.vault, this.room);

  static Future<_RefreshHarness> create() async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final vault = MemoryCredentialVault()
      ..values['account-a'] = 'fixture-password';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final response =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )
            as Map<String, Object?>;
    final rooms =
        (response['ocs'] as Map<String, Object?>)['data'] as List<Object?>;
    final room = Map<String, Object?>.from(rooms.first as Map<String, Object?>)
      ..addAll({
        'sessionId': '0',
        'permissions': 255,
        'participantType': 1,
        'lobbyState': 0,
        'canStartCall': true,
        'hasCall': false,
        'recordingConsent': 0,
      });
    final harness = _RefreshHarness(database, accounts, vault, room);
    harness.api = HttpNextcloudApi(client: MockClient(harness.handle));
    harness.resolver = CallConversationSessionResolver(
      accounts: accounts,
      conversations: ConversationSyncService(
        accounts: accounts,
        credentials: vault,
        api: harness.api,
      ),
    );
    return harness;
  }

  final AppDatabase database;
  final AccountRepository accounts;
  final MemoryCredentialVault vault;
  final Map<String, Object?> room;
  late final HttpNextcloudApi api;
  late final CallConversationSessionResolver resolver;
  final listStarted = Completer<void>(), releaseList = Completer<void>();
  final events = <String>[];
  bool blockList = false;
  bool failLists = false;
  int lists = 0;

  Future<void> activate() async {
    await api.activateRoomSession(
      activeRequest: ActiveRoomSessionRequest(
        accountId: AccountId.parse('account-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
      ),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
  }

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/cloud/capabilities')) {
      final capabilities = capabilitiesJson(
        talkFeatures: [
          'conversation-v4',
          'chat-v2',
          'audio',
          'video',
          'signaling-v3',
          'in-call-flags',
          'conversation-permissions',
          'silent-call',
          'recording-consent',
        ],
      );
      final data =
          (capabilities['ocs'] as Map<String, Object?>)['data']
              as Map<String, Object?>;
      final spreed =
          (data['capabilities'] as Map<String, Object?>)['spreed']
              as Map<String, Object?>;
      (spreed['config'] as Map<String, Object?>)['call'] = {
        'enabled': true,
        'recording-consent': 0,
      };
      return http.Response(jsonEncode(capabilities), 200);
    }
    if (request.url.path.endsWith('/participants/active')) {
      if (request.method == 'DELETE') return _ocs({});
      events.add('activate');
      return _ocs(
        {...room, 'sessionId': 'active-session'},
        headers: {'set-cookie': 'nc_session=active; Path=/; HttpOnly'},
      );
    }
    if (request.url.path.endsWith('/signaling/settings')) {
      return _ocs({
        'signalingMode': 'internal',
        'userId': 'fixture-user',
        'hideWarning': true,
        'server': '',
        'federation': null,
        'stunservers': [],
        'turnservers': [],
        'sipDialinInfo': '',
      });
    }
    if (request.url.path.contains('/api/v4/call/')) {
      expect(request.method, 'POST');
      expect(request.headers['Cookie'], 'nc_session=active');
      events.add('join');
      return _ocs({});
    }
    lists++;
    events.add('list');
    if (failLists) return http.Response('', 503);
    expect(request.url.path, conversationV4Path);
    expect(request.url.queryParameters.containsKey('modifiedSince'), isFalse);
    final hasSession = request.headers['Cookie'] == 'nc_session=active';
    if (blockList) {
      listStarted.complete();
      await releaseList.future;
    }
    return _ocs([
      {...room, 'sessionId': hasSession ? 'active-session' : '0'},
    ]);
  }

  Future<void> close() async {
    if (!releaseList.isCompleted) releaseList.complete();
    api.close();
    await database.close();
  }
}

http.Response _ocs(Object? data, {Map<String, String> headers = const {}}) =>
    http.Response(
      jsonEncode({
        'ocs': {
          'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
          'data': data,
        },
      }),
      200,
      headers: headers,
    );
