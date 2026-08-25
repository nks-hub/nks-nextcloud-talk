import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');

  test('uses bounded no-redirect requests for server status', () async {
    late http.Request observed;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        observed = request;
        return http.Response(jsonEncode(readyStatusJson()), 200);
      }),
    );
    addTearDown(api.close);

    final status = await api.getServerStatus(server);

    expect(status.isReady, isTrue);
    expect(observed.method, 'GET');
    expect(observed.url, server.statusUri);
    expect(observed.followRedirects, isFalse);
    expect(observed.maxRedirects, 0);
  });

  test('rejects redirects instead of following a new origin', () async {
    final api = HttpNextcloudApi(
      client: MockClient((_) async => http.Response('', 302)),
    );
    addTearDown(api.close);

    await expectLater(
      api.getServerStatus(server),
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.unexpectedStatus,
        ),
      ),
    );
  });

  test('stops an unbounded stream once the status limit is exceeded', () async {
    final api = HttpNextcloudApi(client: _OversizedStreamingClient());
    addTearDown(api.close);

    await expectLater(
      api.getServerStatus(server),
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.responseTooLarge,
        ),
      ),
    );
  });

  test('sends Login Flow v2 poll as form data without redirects', () async {
    final requests = <http.Request>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/login/v2')) {
          return http.Response(jsonEncode(loginInitializationJson()), 200);
        }
        return http.Response(jsonEncode(loginSuccessJson()), 200);
      }),
    );
    addTearDown(api.close);

    final initialization = await api.initializeLogin(server);
    final result = await api.pollLogin(
      PendingLogin(
        server: server,
        serverStatus: ServerStatus.fromJson(readyStatusJson()),
        initialization: initialization,
      ),
    );

    expect(result, isA<LoginPollSucceeded>());
    expect(requests, hasLength(2));
    expect(requests.last.followRedirects, isFalse);
    expect(
      requests.last.headers['Content-Type'],
      startsWith('application/x-www-form-urlencoded'),
    );
    expect(requests.last.bodyFields.keys, ['token']);
  });

  test('loads a bounded same-origin avatar with authentication', () async {
    late http.Request observed;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        observed = request;
        return http.Response.bytes(
          const [0x89, 0x50, 0x4e, 0x47],
          200,
          headers: const {
            'content-type': 'image/png',
            'cache-control': 'private, max-age=300',
            'etag': '"fixture-avatar"',
            'x-nc-iscustomavatar': '0',
          },
        );
      }),
    );
    addTearDown(api.close);
    final avatarUri = server.uri.replace(
      path: '/ocs/v2.php/apps/spreed/api/v1/room/room-a/avatar',
    );

    final response = await api.getAvatar(
      server: server,
      avatarUri: avatarUri,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      ifNoneMatch: '"older-avatar"',
    );

    expect(response.status, AvatarResponseStatus.image);
    expect(response.body, const [0x89, 0x50, 0x4e, 0x47]);
    expect(response.contentType, 'image/png');
    expect(response.isCustomAvatar, isFalse);
    expect(response.cacheControl, 'private, max-age=300');
    expect(response.etag, '"fixture-avatar"');
    expect(observed.followRedirects, isFalse);
    expect(observed.maxRedirects, 0);
    expect(observed.headers['Authorization'], startsWith('Basic '));
    expect(observed.headers['If-None-Match'], '"older-avatar"');
  });

  test('avatar transport rejects a different origin before sending', () async {
    var sent = false;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        sent = true;
        return http.Response('', 200);
      }),
    );
    addTearDown(api.close);

    await expectLater(
      api.getAvatar(
        server: server,
        avatarUri: Uri.parse(
          'https://other.example.invalid/index.php/avatar/user/64',
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.invalidAvatarUri,
        ),
      ),
    );
    expect(sent, isFalse);
  });

  test('maps an aborted authenticated request to cancellation', () async {
    final cancellation = Completer<void>();
    final api = HttpNextcloudApi(client: _AbortAwareClient());
    addTearDown(api.close);

    final request = api.getAuthenticatedCapabilities(
      server: server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      abortTrigger: cancellation.future,
    );
    cancellation.complete();

    await expectLater(
      request,
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.cancelled,
        ),
      ),
    );
  });

  test('performs the authenticated Web Push registration handshake', () async {
    final requests = <http.Request>[];
    final responses = <http.Response>[
      http.Response(
        jsonEncode(_ocsResponse(<String, Object>{'vapid': 'B${'a' * 86}'})),
        200,
      ),
      http.Response(jsonEncode(_ocsResponse(const <Object>[], 201)), 201),
      http.Response(jsonEncode(_ocsResponse(const <Object>[], 202)), 202),
      http.Response(jsonEncode(_ocsResponse(const <Object>[], 202)), 202),
    ];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests.add(request);
        return responses.removeAt(0);
      }),
    );
    addTearDown(api.close);

    final vapid = await api.getWebPushVapid(
      server: server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    final registration = await api.registerWebPush(
      server: server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      endpoint: 'https://push.example.invalid/subscription',
      uaPublicKey: 'B${'b' * 86}',
      authSecret: 'c' * 22,
    );
    await api.activateWebPush(
      server: server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      activationToken: '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
    );
    await api.unregisterWebPush(
      server: server,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );

    expect(vapid, 'B${'a' * 86}');
    expect(registration, WebPushRegistrationStatus.activationRequired);
    expect(requests.map((request) => request.method), <String>[
      'GET',
      'POST',
      'POST',
      'DELETE',
    ]);
    expect(requests.map((request) => request.url.path), <String>[
      '/ocs/v2.php/apps/notifications/api/v2/webpush/vapid',
      '/ocs/v2.php/apps/notifications/api/v2/webpush',
      '/ocs/v2.php/apps/notifications/api/v2/webpush/activate',
      '/ocs/v2.php/apps/notifications/api/v2/webpush',
    ]);
    expect(requests.every((request) => !request.followRedirects), isTrue);
    expect(
      requests.every(
        (request) =>
            request.headers['Authorization']?.startsWith('Basic ') ?? false,
      ),
      isTrue,
    );
    expect(requests[1].bodyFields, <String, String>{
      'endpoint': 'https://push.example.invalid/subscription',
      'uaPublicKey': 'B${'b' * 86}',
      'auth': 'c' * 22,
      'appTypes': 'all',
    });
    expect(requests[2].bodyFields, <String, String>{
      'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
    });
  });

  test('rejects malformed VAPID data from an authenticated server', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(_ocsResponse(const <String, Object>{'vapid': 'bad'})),
          200,
        ),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.getWebPushVapid(
        server: server,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.invalidWebPushResponse,
        ),
      ),
    );
  });
}

Map<String, Object?> _ocsResponse(Object? data, [int statusCode = 200]) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': statusCode,
        'message': 'OK',
      },
      'data': data,
    },
  };
}

final class _OversizedStreamingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final chunks = Stream<List<int>>.fromIterable([
      List<int>.filled(48 * 1024, 0x20),
      List<int>.filled(48 * 1024, 0x20),
    ]);
    return http.StreamedResponse(chunks, 200);
  }
}

final class _AbortAwareClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request, isA<http.Abortable>());
    final abortable = request as http.Abortable;
    await abortable.abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}
