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

  group('parseOwnTalkRoomSettingsFrame', () {
    test('reads the room token and the revision', () {
      final signal = parseOwnTalkRoomSettingsFrame(
        'owntalk_room_settings {"token":"abc123xy","revision":7}',
      )!;
      expect(signal.roomToken.value, 'abc123xy');
      expect(signal.revision, 7);
    });

    test('tolerates surrounding whitespace and extra keys', () {
      final signal = parseOwnTalkRoomSettingsFrame(
        '  owntalk_room_settings   {"token":"abc123xy","revision":0,"x":[1]}\n',
      )!;
      expect(signal.revision, 0);
    });

    test('does not touch the frames parseClientPushFrame knows', () {
      const frame = 'owntalk_room_settings {"token":"abc123xy","revision":7}';
      expect(parseClientPushFrame(frame), isNull);
      for (final other in <String>[
        'authenticated',
        'notify_notification',
        'notify_file_id [1,2,3]',
        'notify_activity',
      ]) {
        expect(parseOwnTalkRoomSettingsFrame(other), isNull, reason: other);
      }
      expect(
        parseOwnTalkRoomSettingsFrame(
          'owntalk_room_settings_v2 {"token":"abc123xy","revision":7}',
        ),
        isNull,
      );
    });

    test('ignores malformed bodies instead of throwing', () {
      for (final frame in <String>[
        'owntalk_room_settings',
        'owntalk_room_settings ',
        'owntalk_room_settings not json',
        'owntalk_room_settings {"token":"abc123xy"',
        'owntalk_room_settings []',
        'owntalk_room_settings "abc123xy"',
        'owntalk_room_settings null',
        'owntalk_room_settings {"revision":7}',
        'owntalk_room_settings {"token":"abc123xy"}',
        'owntalk_room_settings {"token":"abc123xy","revision":"7"}',
        'owntalk_room_settings {"token":"abc123xy","revision":7.5}',
        'owntalk_room_settings {"token":"abc123xy","revision":-1}',
        'owntalk_room_settings {"token":7,"revision":7}',
        'owntalk_room_settings {"token":"a b","revision":7}',
        'owntalk_room_settings {"token":"../etc","revision":7}',
        'owntalk_room_settings {"token":"abc","revision":7}',
        'owntalk_room_settings {"token":"","revision":7}',
      ]) {
        expect(parseOwnTalkRoomSettingsFrame(frame), isNull, reason: frame);
      }
    });

    test('ignores an oversized frame', () {
      final padding = ' ' * 300;
      expect(
        parseOwnTalkRoomSettingsFrame(
          'owntalk_room_settings {"token":"abc123xy",$padding"revision":7}',
        ),
        isNull,
      );
      final token = 'a' * 250;
      expect(
        parseOwnTalkRoomSettingsFrame(
          'owntalk_room_settings {"token":"$token","revision":7}',
        ),
        isNull,
      );
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
