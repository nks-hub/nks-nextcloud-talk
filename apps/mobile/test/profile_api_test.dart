import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  test(
    'profile and status transport uses the authenticated subpath OCS API',
    () async {
      final requests = <http.Request>[];
      var status = OwnUserStatusType.online;
      var message = 'Focusing';
      var icon = '🎯';
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/cloud/user')) {
            return _ocsResponse({
              'id': 'alice',
              'displayname': 'Alice Example',
              'email': 'alice@example.invalid',
            });
          }
          if (path.endsWith('/user_status/status')) {
            status = OwnUserStatusType.values.byName(
              Uri.splitQueryString(request.body)['statusType']!,
            );
            return _ocsResponse(_status(status, message: message, icon: icon));
          }
          if (path.endsWith('/user_status/message/custom')) {
            final fields = Uri.splitQueryString(request.body);
            message = fields['message'] ?? '';
            icon = fields['statusIcon'] ?? '';
            return _ocsResponse(_status(status, message: message, icon: icon));
          }
          if (path.endsWith('/user_status/message')) {
            message = '';
            icon = '';
            return _ocsResponse(<Object?>[]);
          }
          if (path.endsWith('/user_status')) {
            return _ocsResponse(_status(status, message: message, icon: icon));
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(api.close);
      final server = ServerBase.parse(
        'https://cloud.example.invalid/nextcloud',
      );

      final profile = await api.getOwnProfile(
        server: server,
        loginName: 'alice',
        appPassword: 'fixture-password',
      );
      final initial = await api.getOwnUserStatus(
        server: server,
        loginName: 'alice',
        appPassword: 'fixture-password',
      );
      final away = await api.setOwnUserStatusType(
        server: server,
        loginName: 'alice',
        appPassword: 'fixture-password',
        status: OwnUserStatusType.away,
      );
      final custom = await api.setOwnCustomStatusMessage(
        server: server,
        loginName: 'alice',
        appPassword: 'fixture-password',
        message: 'In a workshop',
        statusIcon: '🛠️',
      );
      await api.clearOwnUserStatusMessage(
        server: server,
        loginName: 'alice',
        appPassword: 'fixture-password',
      );

      expect(profile.userId, 'alice');
      expect(profile.displayName, 'Alice Example');
      expect(profile.email, 'alice@example.invalid');
      expect(initial.status, OwnUserStatusType.online);
      expect(away.status, OwnUserStatusType.away);
      expect(custom.message, 'In a workshop');
      expect(custom.icon, '🛠️');
      expect(requests.map((request) => '${request.method} ${request.url.path}'), <
        String
      >[
        'GET /nextcloud/ocs/v2.php/cloud/user',
        'GET /nextcloud/ocs/v2.php/apps/user_status/api/v1/user_status',
        'PUT /nextcloud/ocs/v2.php/apps/user_status/api/v1/user_status/status',
        'PUT /nextcloud/ocs/v2.php/apps/user_status/api/v1/user_status/message/custom',
        'DELETE /nextcloud/ocs/v2.php/apps/user_status/api/v1/user_status/message',
      ]);
      for (final request in requests) {
        expect(request.url.queryParameters, {'format': 'json'});
        expect(request.headers['OCS-APIRequest'], 'true');
        expect(
          request.headers['Authorization'],
          'Basic ${base64Encode(utf8.encode('alice:fixture-password'))}',
        );
      }
    },
  );

  test(
    'profile parser rejects a mismatched OCS envelope and oversized status',
    () async {
      var requestCount = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          requestCount++;
          if (requestCount == 1) {
            return _jsonResponse({
              'ocs': {
                'meta': {
                  'status': 'failure',
                  'statuscode': 200,
                  'message': 'No',
                },
                'data': {'id': 'alice'},
              },
            });
          }
          return _ocsResponse(
            _status(
              OwnUserStatusType.online,
              message: List.filled(70 * 1024, 'x').join(),
              icon: null,
            ),
          );
        }),
      );
      addTearDown(api.close);
      final server = ServerBase.parse('https://cloud.example.invalid');

      await expectLater(
        api.getOwnProfile(
          server: server,
          loginName: 'alice',
          appPassword: 'fixture-password',
        ),
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.code,
            'code',
            NextcloudApiError.invalidJson,
          ),
        ),
      );
      await expectLater(
        api.getOwnUserStatus(
          server: server,
          loginName: 'alice',
          appPassword: 'fixture-password',
        ),
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.code,
            'code',
            NextcloudApiError.responseTooLarge,
          ),
        ),
      );
    },
  );

  test(
    'status parser rejects unknown status types and malformed booleans',
    () async {
      final api = HttpNextcloudApi(
        client: MockClient(
          (request) async => _ocsResponse({
            ..._status(OwnUserStatusType.online, message: null, icon: null),
            'status': 'meeting',
            'statusIsUserDefined': 'yes',
          }),
        ),
      );
      addTearDown(api.close);

      await expectLater(
        api.getOwnUserStatus(
          server: ServerBase.parse('https://cloud.example.invalid'),
          loginName: 'alice',
          appPassword: 'fixture-password',
        ),
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.code,
            'code',
            NextcloudApiError.invalidJson,
          ),
        ),
      );
    },
  );
}

Map<String, Object?> _status(
  OwnUserStatusType status, {
  required String? message,
  required String? icon,
}) => <String, Object?>{
  'userId': 'alice',
  'message': message,
  'messageId': null,
  'messageIsPredefined': false,
  'icon': icon,
  'clearAt': null,
  'status': status.name,
  'statusIsUserDefined': true,
};

http.Response _ocsResponse(Object? data) => _jsonResponse({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': data,
  },
});

http.Response _jsonResponse(Object? data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
