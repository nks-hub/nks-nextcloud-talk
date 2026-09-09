import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

const String _listing = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/remote.php/dav/calendars/user-a/personal/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Personal</d:displayname>
        <cal:supported-calendar-component-set>
          <cal:comp name="VEVENT"/>
        </cal:supported-calendar-component-set>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/calendars/user-a/inbox/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Inbox</d:displayname>
        <cal:supported-calendar-component-set>
          <cal:comp name="VEVENT"/>
        </cal:supported-calendar-component-set>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'password-a';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
      talkFeatures: const <String>{'schedule-meeting'},
    );
  });

  tearDown(() => database.close());

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

  test('the listing keeps calendars and drops the scheduling boxes', () async {
    final calls = <String>[];
    final service = serviceWith(
      MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        return http.Response(_listing, 207);
      }),
    );

    final calendars = await service.listCalendars(accountId: 'account-a');

    expect(calls.single, 'PROPFIND /remote.php/dav/calendars/user-a/');
    expect(calendars.map((calendar) => calendar.uri), <String>['personal']);
  });

  test('a meeting is sent once, in seconds, with the bare calendar', () async {
    final bodies = <String>[];
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(talkFeatures: const ['schedule-meeting']),
            ),
            200,
          );
        }
        bodies.add(request.body);
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{'status': 'ok', 'statuscode': 200},
              'data': null,
            },
          }),
          200,
        );
      }),
    );
    final start = DateTime.now().toUtc().add(const Duration(days: 1));

    await service.scheduleMeeting(
      accountId: 'account-a',
      roomToken: 'rooma123',
      calendarUri: 'personal',
      start: start,
      end: start.add(const Duration(hours: 1)),
      title: 'Sprint review',
    );

    expect(bodies, hasLength(1));
    expect(
      bodies.single,
      contains('start=${start.millisecondsSinceEpoch ~/ 1000}'),
    );
    expect(bodies.single, contains('calendarUri=personal'));
    expect(bodies.single, contains('title=Sprint+review'));
  });

  test('a refusal carries the server error word, not a guess', () async {
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(talkFeatures: const ['schedule-meeting']),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{'status': 'failure', 'statuscode': 400},
              'data': <String, Object?>{'error': 'email'},
            },
          }),
          400,
        );
      }),
    );

    await expectLater(
      () => service.scheduleMeeting(
        accountId: 'account-a',
        roomToken: 'rooma123',
        calendarUri: 'personal',
        start: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
      throwsA(
        isA<RoomSettingsException>()
            .having((e) => e.code, 'code', RoomSettingsError.rejected)
            .having((e) => e.message, 'message', 'email'),
      ),
    );
  });

  test('a dropped connection is ambiguous, never a second attempt', () async {
    var attempts = 0;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(talkFeatures: const ['schedule-meeting']),
            ),
            200,
          );
        }
        attempts++;
        throw http.ClientException('connection closed');
      }),
    );

    await expectLater(
      () => service.scheduleMeeting(
        accountId: 'account-a',
        roomToken: 'rooma123',
        calendarUri: 'personal',
        start: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
      throwsA(
        isA<RoomSettingsException>().having(
          (e) => e.code,
          'code',
          RoomSettingsError.ambiguous,
        ),
      ),
    );
    // The endpoint does not deduplicate; one attempt is the whole point.
    expect(attempts, 1);
  });

  test('a start in the past never reaches the server', () async {
    var reached = false;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(talkFeatures: const ['schedule-meeting']),
            ),
            200,
          );
        }
        reached = true;
        return http.Response('', 200);
      }),
    );

    await expectLater(
      () => service.scheduleMeeting(
        accountId: 'account-a',
        roomToken: 'rooma123',
        calendarUri: 'personal',
        start: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      ),
      throwsA(isA<RoomSettingsException>()),
    );
    expect(reached, isFalse);
  });

  test('a server without the capability is never asked', () async {
    var reached = false;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(capabilitiesJson(talkFeatures: const ['chat-v2'])),
            200,
          );
        }
        reached = true;
        return http.Response('', 200);
      }),
    );

    await expectLater(
      () => service.scheduleMeeting(
        accountId: 'account-a',
        roomToken: 'rooma123',
        calendarUri: 'personal',
        start: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
      throwsA(isA<RoomSettingsException>()),
    );
    expect(reached, isFalse);
  });
}
