import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// The `notify_push` pre-auth route is declared as POST. A GET is answered
/// with 405, the socket never gets a token and the live channel silently
/// never connects — which is exactly what happened on a real device until the
/// verb was corrected.
void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final preAuth = Uri.parse('https://cloud.example.invalid/push/pre_auth');

  test('asks for the token with POST and returns it', () async {
    late http.BaseRequest seen;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        seen = request;
        return http.Response('token-from-server', 200);
      }),
    );
    addTearDown(api.close);

    final token = await api.fetchClientPushPreAuthToken(
      server: server,
      loginName: 'tester',
      appPassword: 'secret',
      preAuth: preAuth,
    );

    expect(seen.method, 'POST');
    expect(token, 'token-from-server');
  });

  test('refuses an endpoint pointing at another host', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response('nope', 200)),
    );
    addTearDown(api.close);

    await expectLater(
      api.fetchClientPushPreAuthToken(
        server: server,
        loginName: 'tester',
        appPassword: 'secret',
        preAuth: Uri.parse('https://evil.invalid/push/pre_auth'),
      ),
      throwsA(isA<NextcloudApiException>()),
    );
  });

  test('an empty answer is not treated as a token', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response('   ', 200)),
    );
    addTearDown(api.close);

    await expectLater(
      api.fetchClientPushPreAuthToken(
        server: server,
        loginName: 'tester',
        appPassword: 'secret',
        preAuth: preAuth,
      ),
      throwsA(isA<NextcloudApiException>()),
    );
  });
}
