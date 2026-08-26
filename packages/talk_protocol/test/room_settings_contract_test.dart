import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

AccountId _accountId() => AccountId.parse('account-a');
ServerBase _server() => ServerBase.parse('https://cloud.example.invalid');
ConversationToken _token() =>
    ConversationToken.parse('rooma123', path: r'$.roomToken');

CapabilitySnapshot _capabilities({
  CapabilityContext context = CapabilityContext.authenticated,
  Object? talkFeatures = const <Object?>['archived-conversations-v2'],
}) {
  return CapabilitySnapshot.fromJson(<String, Object?>{
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
          'spreed': <String, Object?>{'features': talkFeatures},
        },
      },
    },
  }, context: context);
}

Uint8List _ocsBody({
  required String status,
  required int statusCode,
  Object? data,
}) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'ocs': {
          'meta': {
            'status': status,
            'statuscode': statusCode,
            'message': status,
          },
          'data': data,
        },
      }),
    ),
  );
}

Map<String, Object?> _syntheticRoom({
  String token = 'rooma123',
  String name = 'synthetic-room',
  String description = '',
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
    'description': description,
    'displayName': name,
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
    'name': name,
    'notificationCalls': 1,
    'notificationLevel': 1,
    'objectId': '',
    'objectType': '',
    'participantFlags': 0,
    'participantType': 2,
    'permissions': 255,
    'readOnly': 0,
    'recordingConsent': 0,
    'sessionId': 'fixture-session',
    'sipEnabled': 0,
    'token': token,
    'type': 2,
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

void main() {
  group('UpdateRoomNameRequest', () {
    test('builds the v4 room URI and form body', () {
      final request = UpdateRoomNameRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        name: 'New name',
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123?format=json',
      );
      expect(request.formBody, {'roomName': 'New name'});
    });

    test('trims the name before sending it', () {
      final request = UpdateRoomNameRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        name: '  Padded  ',
      );

      expect(request.formBody, {'roomName': 'Padded'});
    });

    test('rejects an empty name', () {
      expect(
        () => UpdateRoomNameRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          name: '   ',
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRoomSettingsRequest,
          ),
        ),
      );
    });

    test('rejects a name over the maximum length', () {
      expect(
        () => UpdateRoomNameRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          name: 'x' * 201,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a name carrying a control character', () {
      expect(
        () => UpdateRoomNameRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          name: 'bad\nname',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('decodeUpdateRoomNameResponse', () {
    UpdateRoomNameRequest request() => UpdateRoomNameRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
      name: 'New name',
    );

    test('parses the renamed room on success', () {
      final body = _ocsBody(
        status: 'ok',
        statusCode: 200,
        data: _syntheticRoom(name: 'New name'),
      );

      final response = decodeUpdateRoomNameResponse(
        request: request(),
        statusCode: 200,
        body: body,
      );

      expect(response, isA<UpdateRoomNameSuccess>());
      expect((response as UpdateRoomNameSuccess).room.name, 'New name');
    });

    test('classifies 401, 403 and 404', () {
      expect(
        decodeUpdateRoomNameResponse(
          request: request(),
          statusCode: 401,
          body: _ocsBody(status: 'failure', statusCode: 401),
        ),
        isA<UpdateRoomNameReauthenticationRequired>(),
      );
      expect(
        decodeUpdateRoomNameResponse(
          request: request(),
          statusCode: 403,
          body: _ocsBody(status: 'failure', statusCode: 403),
        ),
        isA<UpdateRoomNameForbidden>(),
      );
      expect(
        decodeUpdateRoomNameResponse(
          request: request(),
          statusCode: 404,
          body: _ocsBody(status: 'failure', statusCode: 404),
        ),
        isA<UpdateRoomNameRoomMissing>(),
      );
    });

    test('classifies 429 and 503 as recoverable HTTP failures', () {
      final rateLimited =
          decodeUpdateRoomNameResponse(
                request: request(),
                statusCode: 429,
                body: Uint8List(0),
              )
              as UpdateRoomNameHttpFailure;
      expect(rateLimited.kind, RoomSettingsHttpFailureKind.rateLimited);

      final unavailable =
          decodeUpdateRoomNameResponse(
                request: request(),
                statusCode: 503,
                body: Uint8List(0),
              )
              as UpdateRoomNameHttpFailure;
      expect(
        unavailable.kind,
        RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => decodeUpdateRoomNameResponse(
          request: request(),
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode('not json')),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects an unsupported HTTP status', () {
      expect(
        () => decodeUpdateRoomNameResponse(
          request: request(),
          statusCode: 500,
          body: Uint8List(0),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.unsupportedHttpStatus,
          ),
        ),
      );
    });
  });

  group('UpdateRoomDescriptionRequest', () {
    test('builds the description sub-path and form body', () {
      final request = UpdateRoomDescriptionRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        description: 'A synthetic description.',
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/description?format=json',
      );
      expect(request.formBody, {'description': 'A synthetic description.'});
    });

    test('allows an empty description (clearing it)', () {
      final request = UpdateRoomDescriptionRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        description: '',
      );

      expect(request.formBody, {'description': ''});
    });

    test('rejects a description over the maximum length', () {
      expect(
        () => UpdateRoomDescriptionRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          description: 'x' * 2001,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('decodeUpdateRoomDescriptionResponse', () {
    UpdateRoomDescriptionRequest request() => UpdateRoomDescriptionRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
      description: 'Updated description',
    );

    test('parses the updated room on success', () {
      final body = _ocsBody(
        status: 'ok',
        statusCode: 200,
        data: _syntheticRoom(description: 'Updated description'),
      );

      final response = decodeUpdateRoomDescriptionResponse(
        request: request(),
        statusCode: 200,
        body: body,
      );

      expect(response, isA<UpdateRoomDescriptionSuccess>());
      expect(
        (response as UpdateRoomDescriptionSuccess).room.description,
        'Updated description',
      );
    });

    test('classifies 403 as forbidden', () {
      final response = decodeUpdateRoomDescriptionResponse(
        request: request(),
        statusCode: 403,
        body: _ocsBody(status: 'failure', statusCode: 403),
      );
      expect(response, isA<UpdateRoomDescriptionForbidden>());
    });
  });

  group('UpdateNotificationLevelRequest', () {
    test('builds the notify sub-path with the wire level', () {
      final request = UpdateNotificationLevelRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        level: RoomNotificationLevel.mentions,
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/notify?format=json',
      );
      expect(request.formBody, {'level': '2'});
    });

    test('encodes always and never', () {
      expect(
        UpdateNotificationLevelRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          level: RoomNotificationLevel.always,
        ).formBody,
        {'level': '1'},
      );
      expect(
        UpdateNotificationLevelRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          level: RoomNotificationLevel.never,
        ).formBody,
        {'level': '3'},
      );
    });
  });

  group('decodeUpdateNotificationLevelResponse', () {
    UpdateNotificationLevelRequest request() => UpdateNotificationLevelRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
      level: RoomNotificationLevel.always,
    );

    test('reports success without needing a room payload', () {
      final response = decodeUpdateNotificationLevelResponse(
        request: request(),
        statusCode: 200,
        body: _ocsBody(status: 'ok', statusCode: 200, data: <Object?>[]),
      );
      expect(response, isA<UpdateNotificationLevelSuccess>());
    });

    test('classifies 404 as room missing', () {
      final response = decodeUpdateNotificationLevelResponse(
        request: request(),
        statusCode: 404,
        body: _ocsBody(status: 'failure', statusCode: 404),
      );
      expect(response, isA<UpdateNotificationLevelRoomMissing>());
    });

    test('classifies 401 as reauthentication required', () {
      final response = decodeUpdateNotificationLevelResponse(
        request: request(),
        statusCode: 401,
        body: _ocsBody(status: 'failure', statusCode: 401),
      );
      expect(response, isA<UpdateNotificationLevelReauthenticationRequired>());
    });
  });

  group('SetFavoriteRequest', () {
    test('uses POST to add and DELETE to remove', () {
      final add = SetFavoriteRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        favorite: true,
      );
      final remove = SetFavoriteRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        favorite: false,
      );

      expect(add.httpMethod, 'POST');
      expect(remove.httpMethod, 'DELETE');
      expect(
        add.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/favorite?format=json',
      );
      expect(add.uri, remove.uri);
    });
  });

  group('decodeSetFavoriteResponse', () {
    SetFavoriteRequest request() => SetFavoriteRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
      favorite: true,
    );

    test('reports success', () {
      final response = decodeSetFavoriteResponse(
        request: request(),
        statusCode: 200,
        body: _ocsBody(status: 'ok', statusCode: 200, data: <Object?>[]),
      );
      expect(response, isA<SetFavoriteSuccess>());
    });

    test('classifies 429 as rate limited', () {
      final response = decodeSetFavoriteResponse(
        request: request(),
        statusCode: 429,
        body: Uint8List(0),
      );
      expect(response, isA<SetFavoriteHttpFailure>());
      expect(
        (response as SetFavoriteHttpFailure).kind,
        RoomSettingsHttpFailureKind.rateLimited,
      );
    });
  });

  group('SetArchivedRequest', () {
    test('uses POST to archive and DELETE to unarchive', () {
      final archive = SetArchivedRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        capabilities: _capabilities(),
        archived: true,
      );
      final unarchive = SetArchivedRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        capabilities: _capabilities(),
        archived: false,
      );

      expect(archive.httpMethod, 'POST');
      expect(unarchive.httpMethod, 'DELETE');
      expect(
        archive.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/archive?format=json',
      );
      expect(archive.uri, unarchive.uri);
    });

    test('requires an authenticated archived-conversations-v2 snapshot', () {
      for (final capabilities in <CapabilitySnapshot>[
        _capabilities(talkFeatures: const <Object?>[]),
        _capabilities(context: CapabilityContext.anonymous),
      ]) {
        expect(
          () => SetArchivedRequest(
            accountId: _accountId(),
            server: _server(),
            roomToken: _token(),
            capabilities: capabilities,
            archived: true,
          ),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidRoomSettingsRequest,
            ),
          ),
        );
      }
    });

    test('rejects malformed and duplicate capability feature lists', () {
      for (final features in <Object?>[
        const <Object?>['archived-conversations-v2', 7],
        const <Object?>[
          'archived-conversations-v2',
          'archived-conversations-v2',
        ],
      ]) {
        expect(
          () => _capabilities(talkFeatures: features),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidCapabilities,
            ),
          ),
        );
      }
    });
  });

  group('decodeSetArchivedResponse', () {
    SetArchivedRequest request() => SetArchivedRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
      capabilities: _capabilities(),
      archived: true,
    );

    test('reports success', () {
      final response = decodeSetArchivedResponse(
        request: request(),
        statusCode: 200,
        body: _ocsBody(status: 'ok', statusCode: 200, data: <Object?>[]),
      );
      expect(response, isA<SetArchivedSuccess>());
    });

    test('classifies 404 as room missing', () {
      final response = decodeSetArchivedResponse(
        request: request(),
        statusCode: 404,
        body: _ocsBody(status: 'failure', statusCode: 404),
      );
      expect(response, isA<SetArchivedRoomMissing>());
    });

    test('classifies 503 as a recoverable HTTP failure', () {
      final response = decodeSetArchivedResponse(
        request: request(),
        statusCode: 503,
        body: Uint8List(0),
      );
      expect(response, isA<SetArchivedHttpFailure>());
      expect(
        (response as SetArchivedHttpFailure).kind,
        RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    });
  });

  group('DeleteRoomRequest', () {
    test('builds the room URI', () {
      final request = DeleteRoomRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        canDeleteConversation: true,
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123?format=json',
      );
    });

    test('refuses to build when the server says the room cannot be deleted',
        () {
      expect(
        () => DeleteRoomRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          canDeleteConversation: false,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRoomSettingsRequest,
          ),
        ),
      );
    });

    test('keeps the room token out of toString', () {
      final request = DeleteRoomRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        canDeleteConversation: true,
      );

      expect(request.toString(), 'DeleteRoomRequest(<redacted>)');
      expect(request.toString(), isNot(contains('rooma123')));
    });
  });

  group('decodeDeleteRoomResponse', () {
    DeleteRoomRequest request() => DeleteRoomRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
      canDeleteConversation: true,
    );

    test('reports success', () {
      expect(
        decodeDeleteRoomResponse(
          request: request(),
          statusCode: 200,
          body: _ocsBody(status: 'ok', statusCode: 200, data: <Object?>[]),
        ),
        isA<DeleteRoomSuccess>(),
      );
    });

    test('classifies 400 as rejected, e.g. a one-to-one conversation', () {
      expect(
        decodeDeleteRoomResponse(
          request: request(),
          statusCode: 400,
          body: _ocsBody(status: 'failure', statusCode: 400),
        ),
        isA<DeleteRoomRejected>(),
      );
    });

    test('classifies 401, 403 and 404', () {
      expect(
        decodeDeleteRoomResponse(
          request: request(),
          statusCode: 401,
          body: _ocsBody(status: 'failure', statusCode: 401),
        ),
        isA<DeleteRoomReauthenticationRequired>(),
      );
      expect(
        decodeDeleteRoomResponse(
          request: request(),
          statusCode: 403,
          body: _ocsBody(status: 'failure', statusCode: 403),
        ),
        isA<DeleteRoomForbidden>(),
      );
      expect(
        decodeDeleteRoomResponse(
          request: request(),
          statusCode: 404,
          body: _ocsBody(status: 'failure', statusCode: 404),
        ),
        isA<DeleteRoomRoomMissing>(),
      );
    });

    test('maps 429 and 503 onto bounded HTTP failures', () {
      final rateLimited = decodeDeleteRoomResponse(
        request: request(),
        statusCode: 429,
        body: Uint8List(0),
      );
      expect(
        (rateLimited as DeleteRoomHttpFailure).kind,
        RoomSettingsHttpFailureKind.rateLimited,
      );
      final unavailable = decodeDeleteRoomResponse(
        request: request(),
        statusCode: 503,
        body: Uint8List(0),
      );
      expect(
        (unavailable as DeleteRoomHttpFailure).kind,
        RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    });

    test('rejects an undocumented status code', () {
      expect(
        () => decodeDeleteRoomResponse(
          request: request(),
          statusCode: 418,
          body: Uint8List(0),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.unsupportedHttpStatus,
          ),
        ),
      );
    });
  });

  group('LeaveRoomRequest', () {
    test('builds the participants/self URI', () {
      final request = LeaveRoomRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/participants/self?format=json',
      );
    });
  });

  group('decodeLeaveRoomResponse', () {
    LeaveRoomRequest request() => LeaveRoomRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
    );

    test('reports success', () {
      final response = decodeLeaveRoomResponse(
        request: request(),
        statusCode: 200,
        body: _ocsBody(status: 'ok', statusCode: 200, data: <Object?>[]),
      );
      expect(response, isA<LeaveRoomSuccess>());
    });

    test('classifies 400 as rejected, e.g. last moderator', () {
      final response = decodeLeaveRoomResponse(
        request: request(),
        statusCode: 400,
        body: _ocsBody(status: 'failure', statusCode: 400),
      );
      expect(response, isA<LeaveRoomRejected>());
    });

    test('classifies 403 as forbidden and 404 as room missing', () {
      expect(
        decodeLeaveRoomResponse(
          request: request(),
          statusCode: 403,
          body: _ocsBody(status: 'failure', statusCode: 403),
        ),
        isA<LeaveRoomForbidden>(),
      );
      expect(
        decodeLeaveRoomResponse(
          request: request(),
          statusCode: 404,
          body: _ocsBody(status: 'failure', statusCode: 404),
        ),
        isA<LeaveRoomRoomMissing>(),
      );
    });
  });
}
