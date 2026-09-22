import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid/nextcloud');
  final notification = <String, Object?>{
    'notification_id': 42,
    'app': 'spreed',
    'object_type': 'chat',
    'object_id': 'roomtoken/123',
    'subject': 'Room',
    'message': 'Message',
    'shouldNotify': true,
  };
  String envelope(Object? data) => jsonEncode({
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200},
      'data': data,
    },
  });

  Future<List<Map<String, Object?>>?> fetch(HttpNextcloudApi api) =>
      api.getDesktopNotifications(
        server: server,
        loginName: 'tester',
        appPassword: 'secret',
      );

  test(
    'notifications use the account base path and authenticated bounded transport',
    () async {
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          expect(
            request.url.path,
            '/nextcloud/ocs/v2.php/apps/notifications/api/v2/notifications',
          );
          expect(
            request.headers['Authorization'],
            'Basic ${base64Encode(utf8.encode('tester:secret'))}',
          );
          expect(request.followRedirects, isFalse);
          return http.Response(envelope([notification]), 200);
        }),
      );
      addTearDown(api.close);
      expect(await fetch(api), [notification]);
    },
  );

  test('DND preserves the IDs but suppresses display', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => http.Response(
          envelope([notification]),
          200,
          headers: {'x-nextcloud-user-status': 'dnd'},
        ),
      ),
    );
    addTearDown(api.close);
    final result = await fetch(api);
    expect(result!.single['notification_id'], 42);
    expect(result.single['shouldNotify'], false);
  });

  test(
    'disabled notifications and malformed responses never become unread fallbacks',
    () async {
      var response = http.Response('', 204);
      final api = HttpNextcloudApi(client: MockClient((_) async => response));
      addTearDown(api.close);
      expect(await fetch(api), isNull);
      response = http.Response(envelope({'wrong': 'shape'}), 200);
      await expectLater(fetch(api), throwsA(isA<NextcloudApiException>()));
      response = http.Response(
        envelope([notification]),
        302,
        headers: {'location': 'https://other.example.invalid'},
      );
      await expectLater(fetch(api), throwsA(isA<NextcloudApiException>()));
    },
  );
}
