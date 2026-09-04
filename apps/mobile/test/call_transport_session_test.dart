import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// FOUND LIVE on the reference server: opening a chat activates the room
/// session, which bumps the account's session generation, and the ongoing-call
/// banner asks for the signalling transport at that same moment. The answer was
/// therefore discarded as a stale session and the banner reported "the call
/// transport could not be resolved", with no join offered at all.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  test('a room session activated mid-flight does not cancel the transport', () async {
    final settingsReached = Completer<void>();
    final releaseSettings = Completer<void>();
    late final HttpNextcloudApi api;
    api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/signaling/settings')) {
          if (!settingsReached.isCompleted) {
            settingsReached.complete();
          }
          await releaseSettings.future;
          return _ocs(<String, Object?>{
            'signalingMode': 'external',
            'userId': 'fixture-user',
            'hideWarning': true,
            'server': 'https://signal.example.invalid/standalone-signaling',
            'federation': null,
            'stunservers': <Object?>[
              <String, Object?>{
                'urls': <Object?>['stun:stun.example.invalid:3478'],
              },
            ],
            'turnservers': <Object?>[],
            'sipDialinInfo': '',
            'ticket': 'fixture-ticket',
            'helloAuthParams': <String, Object?>{
              '1.0': <String, Object?>{
                'userid': 'fixture-user',
                'ticket': 'fixture-ticket',
              },
            },
          });
        }
        if (request.url.path.endsWith('/participants/active')) {
          final root =
              readFixtureJson(
                    'conversation-list/fixtures/conversations-full.response.json',
                  )!
                  as Map<String, Object?>;
          final ocs = root['ocs']! as Map<String, Object?>;
          final rooms = ocs['data']! as List<Object?>;
          return http.Response(
            _ocs(rooms.first).body,
            200,
            headers: const <String, String>{
              'set-cookie': 'nc_session=transport-probe; Path=/; HttpOnly',
            },
          );
        }
        fail('Unexpected request ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    final transport = CallTransportService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
    final pending = transport.resolve(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await settingsReached.future;

    // Exactly what opening the chat does while the banner is asking.
    await api.activateRoomSession(
      activeRequest: ActiveRoomSessionRequest(
        accountId: AccountId.parse('account-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
      ),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    releaseSettings.complete();

    expect(await pending, CallTransport.externalHpb);
  });
}

http.Response _ocs(Object? data) => http.Response(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': data,
    },
  }),
  200,
  headers: const <String, String>{'Content-Type': 'application/json'},
);
