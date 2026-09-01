import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  SignalingSettingsRequest request({String accountId = 'account-a'}) {
    return SignalingSettingsRequest(
      context: SignalingRequestContext(
        accountId: AccountId.parse(accountId),
        requestId: SignalingRequestId.parse('request-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        credentialGeneration: 1,
        capabilityGeneration: 1,
        settingsRevision: 'revision-a',
        connectionEpoch: 1,
        roomEpoch: 1,
      ),
    );
  }

  test('an authorized settings fetch resolves the internal transport', () async {
    late http.BaseRequest captured;
    // The fixture file is a case list, so the request is answered with the
    // first case payload instead of the whole file.
    final cases =
        readFixtureJson('signaling/fixtures/settings.cases.json')
            as List<Object?>;
    final internal =
        (cases.first! as Map<String, Object?>)['data']! as Map<String, Object?>;
    final scopedApi = HttpNextcloudApi(
      client: MockClient((incoming) async {
        captured = incoming;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': internal,
              },
            }),
          ),
          200,
        );
      }),
    );
    addTearDown(scopedApi.close);

    final response = await scopedApi.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-app-password',
    );

    expect(captured.method, 'GET');
    expect(captured.url.path, endsWith('/signaling/settings'));
    expect(captured.url.queryParameters['token'], 'rooma123');
    expect(captured.headers['OCS-APIRequest'], 'true');
    expect(
      captured.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('fixture-user:fixture-app-password'))}',
    );
    expect(response.classification, SignalingSettingsClassification.confirmed);
    expect(response.settings!.transport, SignalingTransportKind.internal);
  });

  test('an unauthorized settings fetch asks for reauthentication', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'failure',
                  'statuscode': 401,
                  'message': 'Unauthorised',
                },
                'data': <String, Object?>{},
              },
            }),
          ),
          401,
        ),
      ),
    );
    addTearDown(api.close);

    final response = await api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-app-password',
    );

    expect(
      response.classification,
      SignalingSettingsClassification.reauthenticationRequired,
    );
    expect(response.settings, isNull);
  });

  test('room session cookies stay isolated by account', () async {
    final requests = <http.BaseRequest>[];
    final cases =
        readFixtureJson('signaling/fixtures/settings.cases.json')
            as List<Object?>;
    final internal =
        (cases.first! as Map<String, Object?>)['data']! as Map<String, Object?>;
    final conversations =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )!
            as Map<String, Object?>;
    final room = Map<String, Object?>.from(
      ((conversations['ocs']! as Map<String, Object?>)['data']! as List).first
          as Map<String, Object?>,
    )..['sessionId'] = 'active-session';
    var activeResponses = 0;
    final api = HttpNextcloudApi(
      client: MockClient((incoming) async {
        requests.add(incoming);
        if (incoming.url.path.endsWith('/participants/active')) {
          activeResponses++;
          final cookie = activeResponses == 1 ? 'session-a' : 'session-b';
          return http.Response(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': room,
              },
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json',
              'set-cookie': 'nc_session=$cookie; Path=/; HttpOnly',
            },
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': internal,
            },
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final server = ServerBase.parse('https://cloud.example.invalid');
    final roomToken = ConversationToken.parse('rooma123', path: r'$.roomToken');

    for (final accountId in <String>['account-a', 'account-b']) {
      final response = await api.activateRoomSession(
        activeRequest: ActiveRoomSessionRequest(
          accountId: AccountId.parse(accountId),
          server: server,
          roomToken: roomToken,
        ),
        loginName: '$accountId-user',
        appPassword: 'fixture-password',
      );
      expect(response.response, isA<ActiveRoomSessionSuccess>());
      expect(response.lease, isNotNull);
    }
    await api.getSignalingSettings(
      settingsRequest: request(accountId: 'account-a'),
      loginName: 'account-a-user',
      appPassword: 'fixture-password',
    );
    await api.getSignalingSettings(
      settingsRequest: request(accountId: 'account-b'),
      loginName: 'account-b-user',
      appPassword: 'fixture-password',
    );

    expect(requests[0].headers['Cookie'], isNull);
    expect(requests[1].headers['Cookie'], isNull);
    expect(requests[2].headers['Cookie'], 'nc_session=session-a');
    expect(requests[3].headers['Cookie'], 'nc_session=session-b');
    await api.clearAccountSession('account-a');
    await api.getSignalingSettings(
      settingsRequest: request(accountId: 'account-a'),
      loginName: 'account-a-user',
      appPassword: 'fixture-password',
    );
    expect(requests[4].headers['Cookie'], isNull);
  });

  test('stale room lease cannot clear a replacement session', () async {
    final room = _activeRoomFixture();
    final internal = _internalSettingsFixture();
    final requests = <http.BaseRequest>[];
    var activation = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/participants/active')) {
          if (request.method == 'DELETE') return _ocsResponse(null);
          activation++;
          room['sessionId'] = 'active-$activation';
          return _ocsResponse(
            room,
            cookie: 'nc_session=session-$activation; Path=/',
          );
        }
        return _ocsResponse(internal);
      }),
    );
    addTearDown(api.close);
    final activeRequest = _activeRequest('account-a');
    final first = await api.activateRoomSession(
      activeRequest: activeRequest,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    final second = await api.activateRoomSession(
      activeRequest: activeRequest,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    final beforeStaleRelease = requests.length;

    await api.deactivateRoomSession(
      lease: first.lease!,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    expect(requests, hasLength(beforeStaleRelease));
    await api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    expect(requests.last.headers['Cookie'], 'nc_session=session-2');

    await api.deactivateRoomSession(
      lease: second.lease!,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
  });

  test('invalid active response performs one bounded cleanup', () async {
    var deletes = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.method == 'DELETE') {
          deletes++;
          return _ocsResponse(null);
        }
        return http.Response(
          '{"ocs":{"meta":{"status":"ok","statuscode":200},'
          '"data":{"sessionId":"broken"}}}',
          200,
          headers: const {
            'content-type': 'application/json',
            'set-cookie': 'nc_session=broken; Path=/',
          },
        );
      }),
    );
    addTearDown(api.close);

    await expectLater(
      api.activateRoomSession(
        activeRequest: _activeRequest('account-a'),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(deletes, 1);
  });

  test('cookie expiry domain and path stay RFC scoped', () async {
    var now = DateTime.utc(2026, 9, 1);
    final room = _activeRoomFixture()..['sessionId'] = 'active-session';
    final internal = _internalSettingsFixture();
    final settingsCookies = <String?>[];
    var activeCookie =
        'bad cookie, nc_session=short; Max-Age=1; Path=/; HttpOnly';
    final api = HttpNextcloudApi(
      clock: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/participants/active')) {
          if (request.method == 'DELETE') return _ocsResponse(null);
          return _ocsResponse(room, cookie: activeCookie);
        }
        settingsCookies.add(request.headers['Cookie']);
        return _ocsResponse(internal);
      }),
    );
    addTearDown(api.close);
    var activation = await api.activateRoomSession(
      activeRequest: _activeRequest('account-a'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    await api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    now = now.add(const Duration(seconds: 2));
    await api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    expect(settingsCookies, ['nc_session=short', isNull]);

    await api.deactivateRoomSession(
      lease: activation.lease!,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    activeCookie =
        'nc_session=wrong; Domain=attacker.invalid; Path=/, '
        'path_cookie=wrong; Path=/ocs2, '
        'deleted=x; Max-Age=-1; Path=/, default_cookie=wrong';
    activation = await api.activateRoomSession(
      activeRequest: _activeRequest('account-a'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    await api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    expect(settingsCookies.last, isNull);
    await api.deactivateRoomSession(
      lease: activation.lease!,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );

    activeCookie =
        'same=root; Path=/, '
        'same=scoped; Path=/ocs/v2.php/apps/spreed/api/v3/signaling, '
        'empty=; Path=/';
    activation = await api.activateRoomSession(
      activeRequest: _activeRequest('account-a'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    await api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    expect(settingsCookies.last, 'same=scoped; same=root; empty=');
    await api.deactivateRoomSession(
      lease: activation.lease!,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
  });

  test('close invalidates a held activation before cookie capture', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var deletes = 0;
    String? deleteCookie;
    final room = _activeRoomFixture()..['sessionId'] = 'active-session';
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.method == 'DELETE') {
          deletes++;
          deleteCookie = request.headers['Cookie'];
          return _ocsResponse(null);
        }
        started.complete();
        await release.future;
        return _ocsResponse(room, cookie: 'nc_session=late; Path=/');
      }),
    );
    final activation = api.activateRoomSession(
      activeRequest: _activeRequest('account-a'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    await started.future;
    final close = api.close();
    release.complete();

    await expectLater(
      activation,
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.cancelled,
        ),
      ),
    );
    await close;
    expect(deletes, 1);
    expect(deleteCookie, 'nc_session=late');
  });

  test('shutdown invalidates held signaling and call responses', () async {
    final settingsStarted = Completer<void>();
    final callStarted = Completer<void>();
    final release = Completer<void>();
    final room = _activeRoomFixture()..['sessionId'] = 'active-session';
    final internal = _internalSettingsFixture();
    var deletes = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/participants/active')) {
          if (request.method == 'DELETE') {
            deletes++;
            return _ocsResponse(null);
          }
          return _ocsResponse(room, cookie: 'nc_session=current; Path=/');
        }
        if (request.url.path.endsWith('/signaling/settings')) {
          settingsStarted.complete();
          await release.future;
          return _ocsResponse(
            internal,
            cookie: 'nc_session=late-settings; Path=/',
          );
        }
        callStarted.complete();
        await release.future;
        return _ocsResponse(
          const <Object?>[],
          cookie: 'nc_session=late-call; Path=/',
        );
      }),
    );
    addTearDown(api.close);
    await api.activateRoomSession(
      activeRequest: _activeRequest('account-a'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    final settings = api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    final call = api.getCallPeers(
      peersRequest: _callPeersRequest(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    await Future.wait([settingsStarted.future, callStarted.future]);
    final shutdown = api.shutdownAccountSession(
      accountId: 'account-a',
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    release.complete();

    await expectLater(settings, _cancelledApiRequest());
    await expectLater(call, _cancelledApiRequest());
    await shutdown;
    expect(deletes, 1);
  });

  test('shutdown cancels a signaling response held after headers', () async {
    final bodyListening = Completer<void>();
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(onListen: bodyListening.complete);
    final room = _activeRoomFixture()..['sessionId'] = 'active-session';
    final internal = _internalSettingsFixture();
    var deletes = 0;
    final api = HttpNextcloudApi(
      client: _StreamingClient((request) async {
        if (request.url.path.endsWith('/participants/active')) {
          if (request.method == 'DELETE') {
            deletes++;
            return _streamedOcsResponse(null);
          }
          return _streamedOcsResponse(
            room,
            cookie: 'nc_session=current; Path=/',
          );
        }
        return _streamedOcsResponse(
          internal,
          body: body.stream,
          cookie: 'nc_session=late-settings; Path=/',
        );
      }),
    );
    addTearDown(api.close);
    await api.activateRoomSession(
      activeRequest: _activeRequest('account-a'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    final settings = api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    await bodyListening.future;
    final shutdown = api.shutdownAccountSession(
      accountId: 'account-a',
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    body
      ..add(utf8.encode(jsonEncode(_ocsEnvelope(internal))))
      ..close();

    await expectLater(settings, _cancelledApiRequest());
    await shutdown;
    expect(deletes, 1);
  });

  test('close bounds an invalidated activation response body', () async {
    final requestStarted = Completer<void>();
    final releaseHeaders = Completer<void>();
    final body = StreamController<List<int>>();
    final room = _activeRoomFixture()..['sessionId'] = 'active-session';
    var deletes = 0;
    final api = HttpNextcloudApi(
      requestTimeout: const Duration(milliseconds: 20),
      client: _StreamingClient((request) async {
        if (request.method == 'DELETE') {
          deletes++;
          return _streamedOcsResponse(null);
        }
        requestStarted.complete();
        await releaseHeaders.future;
        return _streamedOcsResponse(
          room,
          body: body.stream,
          cookie: 'nc_session=late; Path=/',
        );
      }),
    );
    final activation = api.activateRoomSession(
      activeRequest: _activeRequest('account-a'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    final activationExpectation = expectLater(
      activation,
      _cancelledApiRequest(),
    );
    await requestStarted.future;
    final close = api.close();
    releaseHeaders.complete();
    Object? closeError;
    try {
      await close.timeout(const Duration(milliseconds: 250));
    } on Object catch (error) {
      closeError = error;
    } finally {
      await body.close();
      await close;
    }

    expect(closeError, isNull);
    await activationExpectation;
    expect(deletes, 1);
  });
}

ActiveRoomSessionRequest _activeRequest(String accountId) =>
    ActiveRoomSessionRequest(
      accountId: AccountId.parse(accountId),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    );

Map<String, Object?> _activeRoomFixture() {
  final conversations =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  return Map<String, Object?>.from(
    ((conversations['ocs']! as Map<String, Object?>)['data']! as List).first
        as Map<String, Object?>,
  );
}

Map<String, Object?> _internalSettingsFixture() {
  final cases =
      readFixtureJson('signaling/fixtures/settings.cases.json')
          as List<Object?>;
  return (cases.first! as Map<String, Object?>)['data']!
      as Map<String, Object?>;
}

http.Response _ocsResponse(Object? data, {String? cookie}) => http.Response(
  jsonEncode(_ocsEnvelope(data)),
  200,
  headers: <String, String>{
    'content-type': 'application/json',
    'set-cookie': ?cookie,
  },
);

Map<String, Object?> _ocsEnvelope(Object? data) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': data,
  },
};

http.StreamedResponse _streamedOcsResponse(
  Object? data, {
  Stream<List<int>>? body,
  String? cookie,
}) => http.StreamedResponse(
  body ?? Stream<List<int>>.value(utf8.encode(jsonEncode(_ocsEnvelope(data)))),
  200,
  headers: <String, String>{
    'content-type': 'application/json',
    'set-cookie': ?cookie,
  },
);

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

CallPeersRequest _callPeersRequest() => CallPeersRequest(
  context: CallRequestContext(
    authority: CallLifecycleAuthority(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
      nextcloudSessionId: ConversationSessionId.parse('active-session'),
      credentialGeneration: 1,
      capabilityGeneration: 1,
      capabilityRevision: 'revision-a',
    ),
    mutationSequence: 0,
  ),
);

Matcher _cancelledApiRequest() => throwsA(
  isA<NextcloudApiException>().having(
    (error) => error.code,
    'code',
    NextcloudApiError.cancelled,
  ),
);
