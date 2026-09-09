import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// The shape the reference instance actually answered with on 9 September
/// 2026, recorded so a server change is visible here rather than in the UI.
const Map<String, Object?> _record = <String, Object?>{
  'id': 2,
  'userId': 'fixture-user',
  'firstDay': '2026-09-10',
  'lastDay': '2026-09-12',
  'status': 'Away',
  'message': 'Back on the 13th.',
  'replacementUserId': null,
  'replacementUserDisplayName': null,
};

final ServerBase _server = ServerBase.parse(
  'https://cloud.example.invalid/nextcloud',
);

const String _path = '/nextcloud/ocs/v2.php/apps/dav/api/v1/outOfOffice/'
    'fixture-user';

http.Response _ocs(int status, Object? data) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': status == 200 ? 'ok' : 'failure', 'statuscode': status},
      'data': data,
    },
  }),
  status,
  headers: const {'content-type': 'application/json'},
);

void main() {
  test('an account with no absence set reads back nothing', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, _path);
        return _ocs(404, null);
      }),
    );
    addTearDown(api.close);

    expect(
      await api.getOwnOutOfOffice(
        server: _server,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
        userId: 'fixture-user',
      ),
      isNull,
    );
  });

  test('an absence reads back as inclusive calendar days', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => _ocs(200, _record)),
    );
    addTearDown(api.close);

    final absence = await api.getOwnOutOfOffice(
      server: _server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      userId: 'fixture-user',
    );

    expect(absence!.firstDay, DateTime(2026, 9, 10));
    expect(absence.lastDay, DateTime(2026, 9, 12));
    expect(absence.status, 'Away');
    expect(absence.message, 'Back on the 13th.');
    expect(absence.replacementUserId, isNull);
  });

  test('setting an absence sends the days the server documents', () async {
    late Map<String, String> sent;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, _path);
        sent = Uri.splitQueryString(request.body);
        return _ocs(200, _record);
      }),
    );
    addTearDown(api.close);

    final stored = await api.setOwnOutOfOffice(
      server: _server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      userId: 'fixture-user',
      firstDay: DateTime(2026, 9, 10),
      lastDay: DateTime(2026, 9, 12),
      status: 'Away',
      message: 'Back on the 13th.',
    );

    expect(sent, {
      'firstDay': '2026-09-10',
      'lastDay': '2026-09-12',
      'status': 'Away',
      'message': 'Back on the 13th.',
    });
    expect(stored.firstDay, DateTime(2026, 9, 10));
  });

  test('a replacement is sent only when there is one', () async {
    final bodies = <Map<String, String>>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        bodies.add(Uri.splitQueryString(request.body));
        return _ocs(200, {..._record, 'replacementUserId': 'colleague'});
      }),
    );
    addTearDown(api.close);

    await api.setOwnOutOfOffice(
      server: _server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      userId: 'fixture-user',
      firstDay: DateTime(2026, 9, 10),
      lastDay: DateTime(2026, 9, 12),
      status: 'Away',
      message: '',
      replacementUserId: 'colleague',
    );
    await api.setOwnOutOfOffice(
      server: _server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      userId: 'fixture-user',
      firstDay: DateTime(2026, 9, 10),
      lastDay: DateTime(2026, 9, 12),
      status: 'Away',
      message: '',
    );

    expect(bodies.first['replacementUserId'], 'colleague');
    expect(bodies.last.containsKey('replacementUserId'), isFalse);
  });

  test('a record for somebody else is refused', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (request) async => _ocs(200, {..._record, 'userId': 'somebody-else'}),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.getOwnOutOfOffice(
        server: _server,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
        userId: 'fixture-user',
      ),
      throwsA(isA<NextcloudApiException>()),
    );
  });

  test('a last day before the first day is refused', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (request) async => _ocs(200, {..._record, 'lastDay': '2026-09-09'}),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.getOwnOutOfOffice(
        server: _server,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
        userId: 'fixture-user',
      ),
      throwsA(isA<NextcloudApiException>()),
    );
  });

  test('a day that is not a real date is refused', () async {
    for (final day in <String>['2026-13-01', '2026-02-30', '10.9.2026', '']) {
      final api = HttpNextcloudApi(
        client: MockClient(
          (request) async => _ocs(200, {..._record, 'firstDay': day}),
        ),
      );
      addTearDown(api.close);

      await expectLater(
        api.getOwnOutOfOffice(
          server: _server,
          loginName: 'fixture-user',
          appPassword: 'fixture-password',
          userId: 'fixture-user',
        ),
        throwsA(isA<NextcloudApiException>()),
        reason: '$day is not a calendar day',
      );
    }
  });

  test('clearing an absence sends DELETE and accepts an empty answer', () async {
    var deletes = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, _path);
        deletes++;
        return _ocs(200, null);
      }),
    );
    addTearDown(api.close);

    await api.clearOwnOutOfOffice(
      server: _server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      userId: 'fixture-user',
    );

    expect(deletes, 1);
  });
}
