import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  UnbindConversationRequest request({
    String objectType = 'event',
    CapabilitySnapshot? capabilities,
  }) => UnbindConversationRequest(
    accountId: AccountId.parse('account-1'),
    server: ServerBase.parse('https://cloud.example.com'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    objectType: objectType,
    capabilities: capabilities ?? _capabilities(),
  );

  group('UnbindConversationRequest', () {
    test('deletes the object of exactly this room', () {
      final unbind = request();

      expect(unbind.httpMethod, 'DELETE');
      expect(unbind.uri.path, endsWith('/room/rooma123/object'));
      expect(unbind.formBody, isNull);
      expect(unbind.headers['OCS-APIRequest'], 'true');
    });

    test('offers only the bindings the server accepts', () {
      // Measured 9 September 2026: event and instant_meeting become ordinary
      // conversations, phone_temporary becomes phone_persist, and everything
      // else answers 400 object-type.
      expect(unbindableObjectTypes, <String>{
        'event',
        'instant_meeting',
        'phone_temporary',
      });
      for (final refused in <String>[
        '',
        'phone_persist',
        'note_to_self',
        'sample',
        'file',
      ]) {
        expect(
          () => request(objectType: refused),
          throwsA(isA<TalkProtocolException>()),
          reason: refused,
        );
      }
    });

    test('a server without unbind-conversation is never asked', () {
      expect(
        () => request(
          capabilities: _capabilities(features: const <String>{'chat-v2'}),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => request(
          capabilities: _capabilities(context: CapabilityContext.anonymous),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('never renders the room in its description', () {
      expect(request().toString(), isNot(contains('rooma123')));
    });
  });

  group('the answer to an unbind', () {
    RoomAdministrationResponse decode(int statusCode, String body) =>
        decodeRoomAdministrationResponse(
          request: request(),
          statusCode: statusCode,
          body: Uint8List.fromList(utf8.encode(body)),
        );

    test('a kept event room comes back with no binding at all', () {
      final response = decode(200, _roomBody(objectType: '', objectId: ''));

      expect(response, isA<RoomAdministrationSuccess>());
      expect((response as RoomAdministrationSuccess).room?.objectType, '');
    });

    test('a temporary phone room comes back as a persistent one', () {
      // The surprising half of the measurement: this is not an untyped room.
      final response = decode(
        200,
        _roomBody(objectType: 'phone_persist', objectId: 'probe-phone-1'),
      );

      expect(
        (response as RoomAdministrationSuccess).room?.objectType,
        'phone_persist',
      );
    });

    test('the refusals the endpoint can answer', () {
      expect(
        decode(400, _errorBody('object-type')),
        isA<RoomAdministrationRejected>(),
      );
      expect(decode(403, _errorBody('')), isA<RoomAdministrationForbidden>());
      expect(decode(404, _errorBody('')), isA<RoomAdministrationRoomMissing>());
    });
  });
}

String _errorBody(String error) => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'failure',
      'statuscode': 400,
      'message': '',
    },
    'data': error.isEmpty
        ? <String, Object?>{}
        : <String, Object?>{'error': error},
  },
});

String _roomBody({required String objectType, required String objectId}) =>
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': _syntheticRoom(objectType: objectType, objectId: objectId),
      },
    });

/// The same shape the neighbouring administration test uses, so this file
/// exercises the real room decoder rather than a reduced stand-in.
Map<String, Object?> _syntheticRoom({
  required String objectType,
  required String objectId,
}) {
  return {
    'actorId': 'fixture-user-a',
    'actorType': 'users',
    'attendeeId': 101,
    'attendeePermissions': 0,
    'attendeePin': null,
    'avatarVersion': '1',
    'breakoutRoomMode': 0,
    'breakoutRoomStatus': 0,
    'callFlag': 0,
    'callPermissions': 0,
    'callRecording': 0,
    'callStartTime': 0,
    'canDeleteConversation': true,
    'canEnableSIP': false,
    'canLeaveConversation': true,
    'canStartCall': true,
    'defaultPermissions': 0,
    'description': '',
    'displayName': 'synthetic-room',
    'hasCall': false,
    'hasPassword': false,
    'id': 1001,
    'isCustomAvatar': false,
    'isFavorite': false,
    'lastActivity': 1724300100,
    'lastCommonReadMessage': 0,
    'lastPing': 0,
    'lastReadMessage': 0,
    'listable': 0,
    'liveTranscriptionLanguageId': '',
    'lobbyState': 0,
    'lobbyTimer': 0,
    'mentionPermissions': 0,
    'messageExpiration': 0,
    'name': 'synthetic-room',
    'notificationCalls': 1,
    'notificationLevel': 1,
    'objectId': objectId,
    'objectType': objectType,
    'participantFlags': 0,
    'participantType': 2,
    'permissions': 255,
    'readOnly': 0,
    'recordingConsent': 0,
    'sessionId': 'fixture-session',
    'sipEnabled': 0,
    'token': 'rooma123',
    'type': 3,
    'unreadMention': false,
    'unreadMentionDirect': false,
    'unreadMessages': 0,
    'isArchived': false,
    'isImportant': false,
    'isSensitive': false,
    'tagIds': <Object?>[],
    'hasScheduledMessages': 0,
    'lastPinnedId': 0,
    'hiddenPinnedId': 0,
    'attributes': 0,
  };
}

CapabilitySnapshot _capabilities({
  Set<String> features = const <String>{'unbind-conversation'},
  CapabilityContext context = CapabilityContext.authenticated,
}) => CapabilitySnapshot.fromJson(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'version': <String, Object?>{
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': <String, Object?>{
        'spreed': <String, Object?>{'features': features.toList()},
      },
    },
  },
}, context: context);
