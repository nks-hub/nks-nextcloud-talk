import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('readClientPushEndpoints', () {
    Map<String, Object?> capability({
      Object? websocket = 'wss://cloud.example.invalid/push/ws',
      Object? preAuth = 'https://cloud.example.invalid/push/pre_auth',
      Object? types = const ['files', 'activities', 'notifications'],
    }) => <String, Object?>{
      'notify_push': <String, Object?>{
        'type': types,
        'endpoints': <String, Object?>{
          'websocket': websocket,
          'pre_auth': preAuth,
        },
      },
    };

    test('reads the advertised endpoints', () {
      final endpoints = readClientPushEndpoints(capability())!;
      expect(endpoints.websocket.toString(), contains('/push/ws'));
      expect(endpoints.preAuth.scheme, 'https');
      expect(endpoints.carriesNotifications, isTrue);
    });

    test('a server without the app offers nothing', () {
      expect(readClientPushEndpoints(const <String, Object?>{}), isNull);
    });

    test('a build that carries only files is reported as such', () {
      final endpoints = readClientPushEndpoints(
        capability(types: const ['files']),
      )!;
      expect(endpoints.carriesNotifications, isFalse);
    });

    test('a websocket endpoint with credentials is refused', () {
      // Credentials in the authority hide the real host, so the endpoint is
      // rejected outright rather than trimmed.
      expect(
        readClientPushEndpoints(
          capability(websocket: 'wss://user:pass@evil.invalid/push/ws'),
        ),
        isNull,
      );
    });

    test('a plain http websocket scheme is refused', () {
      expect(
        readClientPushEndpoints(
          capability(websocket: 'https://cloud.example.invalid/push/ws'),
        ),
        isNull,
      );
    });
  });

  group('parseClientPushFrame', () {
    test('recognises the frames this client acts on', () {
      expect(parseClientPushFrame('authenticated'), ClientPushEvent.authenticated);
      expect(
        parseClientPushFrame('notify_notification'),
        ClientPushEvent.notification,
      );
      expect(parseClientPushFrame('notify_activity'), ClientPushEvent.activity);
      expect(parseClientPushFrame('notify_file'), ClientPushEvent.file);
    });

    test('keeps the name when a payload follows it', () {
      expect(
        parseClientPushFrame('notify_file_id [1,2,3]'),
        ClientPushEvent.file,
      );
    });

    test('an unknown frame is ignored rather than fatal', () {
      expect(parseClientPushFrame('notify_something_new'), isNull);
      expect(parseClientPushFrame(''), isNull);
    });
  });

  group('clientPushHandshake', () {
    test('sends an empty username and then the token', () {
      expect(clientPushHandshake(preAuthToken: 'abc123'), <String>['', 'abc123']);
    });

    test('refuses an empty token', () {
      expect(
        () => clientPushHandshake(preAuthToken: ''),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}
