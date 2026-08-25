import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

const String _v4Base =
    'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room';
const String _v1Base =
    'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v1/room';
const String _banBase =
    'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v1/ban';

AccountId _accountId() => AccountId.parse('account-a');
ServerBase _server() => ServerBase.parse('https://cloud.example.invalid');
ConversationToken _token() =>
    ConversationToken.parse('rooma123', path: r'$.roomToken');

Uint8List _ocsBody({
  String status = 'ok',
  int statusCode = 200,
  Object? data = const <Object?>[],
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
  int type = 2,
  int readOnly = 0,
  bool hasPassword = false,
  bool isCustomAvatar = false,
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
    'hasPassword': hasPassword,
    'id': 1001,
    'isCustomAvatar': isCustomAvatar,
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
    'objectId': '',
    'objectType': '',
    'participantFlags': 0,
    'participantType': 2,
    'permissions': 255,
    'readOnly': readOnly,
    'recordingConsent': 0,
    'sessionId': 'fixture-session',
    'sipEnabled': 0,
    'token': 'rooma123',
    'type': type,
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

Matcher _protocolFailure(TalkProtocolErrorCode code) => throwsA(
  isA<TalkProtocolException>().having((error) => error.code, 'code', code),
);

void main() {
  group('SetRoomPublicRequest', () {
    test('POSTs to the v4 public endpoint when making a room public', () {
      final request = SetRoomPublicRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        public: true,
      );

      expect(request.httpMethod, 'POST');
      expect(request.uri.toString(), '$_v4Base/rooma123/public?format=json');
      expect(request.formBody, isNull);
      expect(request.headers['OCS-APIRequest'], 'true');
    });

    test('DELETEs the same endpoint when making a room private', () {
      final request = SetRoomPublicRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        public: false,
      );

      expect(request.httpMethod, 'DELETE');
      expect(request.uri.toString(), '$_v4Base/rooma123/public?format=json');
    });
  });

  group('SetRoomPasswordRequest', () {
    test('PUTs the password to the v4 password endpoint', () {
      final request = SetRoomPasswordRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        password: 'fixture-secret',
      );

      expect(request.httpMethod, 'PUT');
      expect(request.uri.toString(), '$_v4Base/rooma123/password?format=json');
      expect(request.formBody, {'password': 'fixture-secret'});
      expect(request.clearsPassword, isFalse);
    });

    test('sends an empty password to clear the protection', () {
      final request = SetRoomPasswordRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        password: '',
      );

      expect(request.formBody, {'password': ''});
      expect(request.clearsPassword, isTrue);
    });

    test('never renders the password in diagnostics', () {
      final request = SetRoomPasswordRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        password: 'fixture-secret',
      );

      expect(request.toString(), isNot(contains('fixture-secret')));
      expect(
        request.toString(),
        'SetRoomPasswordRequest(clearsPassword: false)',
      );
    });

    test('rejects a control character in the password', () {
      expect(
        () => SetRoomPasswordRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          password: 'bad\npassword',
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsRequest),
      );
    });

    test('rejects a password beyond the accepted length', () {
      expect(
        () => SetRoomPasswordRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          password: 'a' * (roomPasswordMaximumLength + 1),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsRequest),
      );
    });
  });

  group('SetRoomLobbyRequest', () {
    test('PUTs the state to the v4 webinar lobby endpoint', () {
      final request = SetRoomLobbyRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        state: RoomLobbyState.moderatorsOnly,
      );

      expect(request.httpMethod, 'PUT');
      expect(
        request.uri.toString(),
        '$_v4Base/rooma123/webinar/lobby?format=json',
      );
      expect(request.formBody, {'state': '1'});
    });

    test('carries the timer when the lobby lifts itself', () {
      final request = SetRoomLobbyRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        state: RoomLobbyState.moderatorsOnly,
        timerSecondsSinceEpoch: 1724300100,
      );

      expect(request.formBody, {'state': '1', 'timer': '1724300100'});
    });

    test('omits the timer when the lobby is switched off', () {
      final request = SetRoomLobbyRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        state: RoomLobbyState.none,
      );

      expect(request.formBody, {'state': '0'});
    });

    test('refuses a timer for a lobby that is being switched off', () {
      expect(
        () => SetRoomLobbyRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          state: RoomLobbyState.none,
          timerSecondsSinceEpoch: 1724300100,
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsRequest),
      );
    });

    test('refuses a non-positive timer', () {
      expect(
        () => SetRoomLobbyRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          state: RoomLobbyState.moderatorsOnly,
          timerSecondsSinceEpoch: 0,
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsRequest),
      );
    });

    test('refuses a millisecond timestamp that leaked in', () {
      expect(
        () => SetRoomLobbyRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          state: RoomLobbyState.moderatorsOnly,
          timerSecondsSinceEpoch: 1724300100000,
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsRequest),
      );
    });
  });

  group('SetRoomReadOnlyRequest', () {
    test('PUTs the documented state values', () {
      for (final (state, wire) in <(RoomReadOnlyState, String)>[
        (RoomReadOnlyState.readWrite, '0'),
        (RoomReadOnlyState.readOnly, '1'),
      ]) {
        final request = SetRoomReadOnlyRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          state: state,
        );

        expect(request.httpMethod, 'PUT');
        expect(
          request.uri.toString(),
          '$_v4Base/rooma123/read-only?format=json',
        );
        expect(request.formBody, {'state': wire});
      }
    });
  });

  group('SetRoomEmojiAvatarRequest', () {
    test('POSTs the emoji to the v1 avatar endpoint', () {
      final request = SetRoomEmojiAvatarRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        emoji: '\u{1F680}',
      );

      expect(request.httpMethod, 'POST');
      expect(
        request.uri.toString(),
        '$_v1Base/rooma123/avatar/emoji?format=json',
      );
      expect(request.formBody, {'emoji': '\u{1F680}'});
    });

    test('carries a six-digit hex colour without the leading hash', () {
      final request = SetRoomEmojiAvatarRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        emoji: '\u{1F680}',
        hexColor: '0082C9',
      );

      expect(request.formBody, {'emoji': '\u{1F680}', 'color': '0082C9'});
    });

    test('refuses a colour that is not six hex digits', () {
      for (final color in <String>['#0082C9', '0082C', 'ZZZZZZ', '0082C99']) {
        expect(
          () => SetRoomEmojiAvatarRequest(
            accountId: _accountId(),
            server: _server(),
            roomToken: _token(),
            emoji: '\u{1F680}',
            hexColor: color,
          ),
          _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsRequest),
        );
      }
    });

    test('refuses an empty emoji', () {
      expect(
        () => SetRoomEmojiAvatarRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          emoji: '',
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsRequest),
      );
    });

    test('accepts a multi-code-point emoji sequence', () {
      final request = SetRoomEmojiAvatarRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        // Family: man, woman, girl, boy — four code points joined by ZWJ.
        emoji: '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}',
      );

      expect(
        request.formBody!['emoji'],
        '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}',
      );
    });
  });

  group('DeleteRoomAvatarRequest', () {
    test('DELETEs the v1 avatar endpoint', () {
      final request = DeleteRoomAvatarRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
      );

      expect(request.httpMethod, 'DELETE');
      expect(request.uri.toString(), '$_v1Base/rooma123/avatar?format=json');
      expect(request.formBody, isNull);
    });
  });

  group('decodeRoomAdministrationResponse', () {
    SetRoomReadOnlyRequest request() => SetRoomReadOnlyRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
      state: RoomReadOnlyState.readOnly,
    );

    test('reads the refreshed room out of a 200 that carries one', () {
      final response = decodeRoomAdministrationResponse(
        request: request(),
        statusCode: 200,
        body: _ocsBody(data: _syntheticRoom(readOnly: 1)),
      );

      expect(response, isA<RoomAdministrationSuccess>());
      expect((response as RoomAdministrationSuccess).room?.readOnly, 1);
    });

    test('accepts a 200 that carries no room payload', () {
      final response = decodeRoomAdministrationResponse(
        request: request(),
        statusCode: 200,
        body: _ocsBody(),
      );

      expect(response, isA<RoomAdministrationSuccess>());
      expect((response as RoomAdministrationSuccess).room, isNull);
    });

    test('surfaces the password policy message from a 400', () {
      final response = decodeRoomAdministrationResponse(
        request: SetRoomPasswordRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          password: 'short',
        ),
        statusCode: 400,
        body: _ocsBody(
          status: 'failure',
          statusCode: 400,
          data: {'message': 'Password needs to be at least 10 characters.'},
        ),
      );

      expect(response, isA<RoomAdministrationRejected>());
      expect(
        (response as RoomAdministrationRejected).message,
        'Password needs to be at least 10 characters.',
      );
    });

    test('never renders the policy message in diagnostics', () {
      final response =
          decodeRoomAdministrationResponse(
                request: request(),
                statusCode: 400,
                body: _ocsBody(
                  status: 'failure',
                  statusCode: 400,
                  data: {'message': 'secret-policy-detail'},
                ),
              )
              as RoomAdministrationRejected;

      expect(response.toString(), isNot(contains('secret-policy-detail')));
    });

    test('leaves the message null for a refusal without one', () {
      final response = decodeRoomAdministrationResponse(
        request: request(),
        statusCode: 400,
        body: _ocsBody(status: 'failure', statusCode: 400),
      );

      expect((response as RoomAdministrationRejected).message, isNull);
    });

    test('classifies every documented status code', () {
      final expectations = <int, Matcher>{
        401: isA<RoomAdministrationReauthenticationRequired>(),
        403: isA<RoomAdministrationForbidden>(),
        404: isA<RoomAdministrationRoomMissing>(),
      };
      expectations.forEach((statusCode, matcher) {
        expect(
          decodeRoomAdministrationResponse(
            request: request(),
            statusCode: statusCode,
            body: _ocsBody(status: 'failure', statusCode: statusCode),
          ),
          matcher,
        );
      });

      for (final (statusCode, kind) in <(int, RoomSettingsHttpFailureKind)>[
        (429, RoomSettingsHttpFailureKind.rateLimited),
        (503, RoomSettingsHttpFailureKind.serviceUnavailable),
      ]) {
        final response = decodeRoomAdministrationResponse(
          request: request(),
          statusCode: statusCode,
          body: Uint8List(0),
        );
        expect(response, isA<RoomAdministrationHttpFailure>());
        expect((response as RoomAdministrationHttpFailure).kind, kind);
      }
    });

    test('refuses an undocumented status code', () {
      expect(
        () => decodeRoomAdministrationResponse(
          request: request(),
          statusCode: 418,
          body: _ocsBody(),
        ),
        _protocolFailure(TalkProtocolErrorCode.unsupportedHttpStatus),
      );
    });

    test('refuses a payload that is not an OCS envelope', () {
      expect(
        () => decodeRoomAdministrationResponse(
          request: request(),
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode('{"not":"ocs"}')),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidRoomSettingsResponse),
      );
    });
  });

  group('ListBansRequest', () {
    test('GETs the v1 ban endpoint, which is not under /room', () {
      final request = ListBansRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
      );

      expect(request.uri.toString(), '$_banBase/rooma123?format=json');
      expect(request.headers['OCS-APIRequest'], 'true');
    });
  });

  group('BanActorRequest', () {
    test('POSTs the actor to the v1 ban endpoint', () {
      final request = BanActorRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        actorType: BannedActorType.users,
        actorId: 'synthetic-member',
      );

      expect(request.uri.toString(), '$_banBase/rooma123?format=json');
      expect(request.formBody, {
        'actorType': 'users',
        'actorId': 'synthetic-member',
      });
    });

    test('carries the internal note only when there is one', () {
      final request = BanActorRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        actorType: BannedActorType.guests,
        actorId: 'synthetic-guest',
        internalNote: 'Repeated spam',
      );

      expect(request.formBody['internalNote'], 'Repeated spam');
    });

    test('renders neither the actor nor the note in diagnostics', () {
      final request = BanActorRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        actorType: BannedActorType.users,
        actorId: 'synthetic-member',
        internalNote: 'private moderator remark',
      );

      expect(request.toString(), 'BanActorRequest(actorType: users)');
    });

    test('refuses an empty actor id', () {
      expect(
        () => BanActorRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          actorType: BannedActorType.users,
          actorId: '',
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidBansRequest),
      );
    });

    test('refuses a note beyond the documented 4000 characters', () {
      expect(
        () => BanActorRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          actorType: BannedActorType.users,
          actorId: 'synthetic-member',
          internalNote: 'a' * (banNoteMaximumLength + 1),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidBansRequest),
      );
    });

    test('maps only the actor types the server accepts', () {
      expect(bannedActorTypeFor('users'), BannedActorType.users);
      expect(bannedActorTypeFor('guests'), BannedActorType.guests);
      expect(bannedActorTypeFor('emails'), BannedActorType.emails);
      expect(bannedActorTypeFor('federated_users'), isNull);
      expect(bannedActorTypeFor('bots'), isNull);
    });
  });

  group('UnbanActorRequest', () {
    test('DELETEs the ban by id', () {
      final request = UnbanActorRequest(
        accountId: _accountId(),
        server: _server(),
        roomToken: _token(),
        banId: 42,
      );

      expect(request.uri.toString(), '$_banBase/rooma123/42?format=json');
    });

    test('refuses a negative ban id', () {
      expect(
        () => UnbanActorRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          banId: -1,
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidBansRequest),
      );
    });
  });

  group('ban responses', () {
    Map<String, Object?> banJson({int id = 7}) => {
      'id': id,
      'moderatorActorType': 'users',
      'moderatorActorId': 'fixture-user-a',
      'moderatorDisplayName': 'Fixture Moderator',
      'bannedActorType': 'users',
      'bannedActorId': 'synthetic-member',
      'bannedDisplayName': 'Synthetic Member',
      'bannedTime': 1724300100,
      'internalNote': 'Repeated spam',
    };

    ListBansRequest listRequest() => ListBansRequest(
      accountId: _accountId(),
      server: _server(),
      roomToken: _token(),
    );

    test('decodes a validated ban list', () {
      final response = decodeListBansResponse(
        request: listRequest(),
        statusCode: 200,
        body: _ocsBody(data: [banJson(), banJson(id: 8)]),
      );

      expect(response, isA<RoomBanListSuccess>());
      final bans = (response as RoomBanListSuccess).bans;
      expect(bans.map((ban) => ban.id), [7, 8]);
      expect(bans.first.bannedDisplayName, 'Synthetic Member');
      expect(bans.first.internalNote, 'Repeated spam');
      expect(bans.first.bannedTime, 1724300100);
    });

    test('renders only the id of a ban in diagnostics', () {
      final response =
          decodeListBansResponse(
                request: listRequest(),
                statusCode: 200,
                body: _ocsBody(data: [banJson()]),
              )
              as RoomBanListSuccess;

      expect(response.bans.first.toString(), 'RoomBan(id: 7)');
    });

    test('decodes the ban a create request answers with', () {
      final response = decodeBanActorResponse(
        request: BanActorRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          actorType: BannedActorType.users,
          actorId: 'synthetic-member',
        ),
        statusCode: 200,
        body: _ocsBody(data: banJson()),
      );

      expect(response, isA<RoomBanChangeSuccess>());
      expect((response as RoomBanChangeSuccess).ban?.id, 7);
    });

    test('treats an unban 200 as success without a ban object', () {
      final response = decodeUnbanActorResponse(
        request: UnbanActorRequest(
          accountId: _accountId(),
          server: _server(),
          roomToken: _token(),
          banId: 7,
        ),
        statusCode: 200,
        body: _ocsBody(data: null),
      );

      expect(response, isA<RoomBanChangeSuccess>());
      expect((response as RoomBanChangeSuccess).ban, isNull);
    });

    test('keeps the documented 400 discriminator', () {
      for (final error in <String>[
        'bannedActor',
        'internalNote',
        'moderator',
        'self',
        'room',
      ]) {
        final response = decodeBanActorResponse(
          request: BanActorRequest(
            accountId: _accountId(),
            server: _server(),
            roomToken: _token(),
            actorType: BannedActorType.users,
            actorId: 'synthetic-member',
          ),
          statusCode: 400,
          body: _ocsBody(
            status: 'failure',
            statusCode: 400,
            data: {'error': error},
          ),
        );

        expect(response, isA<RoomBanRejected>());
        expect((response as RoomBanRejected).error, error);
      }
    });

    test('classifies the remaining status codes', () {
      final expectations = <int, Matcher>{
        401: isA<RoomBanReauthenticationRequired>(),
        403: isA<RoomBanForbidden>(),
        404: isA<RoomBanRoomMissing>(),
      };
      expectations.forEach((statusCode, matcher) {
        expect(
          decodeListBansResponse(
            request: listRequest(),
            statusCode: statusCode,
            body: _ocsBody(status: 'failure', statusCode: statusCode),
          ),
          matcher,
        );
      });

      final rateLimited = decodeListBansResponse(
        request: listRequest(),
        statusCode: 429,
        body: Uint8List(0),
      );
      expect(
        (rateLimited as RoomBanHttpFailure).kind,
        RoomBanHttpFailureKind.rateLimited,
      );
    });

    test('refuses a ban list that is not a list', () {
      expect(
        () => decodeListBansResponse(
          request: listRequest(),
          statusCode: 200,
          body: _ocsBody(data: {'id': 7}),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidBansResponse),
      );
    });

    test('refuses a ban entry with a missing field', () {
      final incomplete = banJson()..remove('bannedDisplayName');
      expect(
        () => decodeListBansResponse(
          request: listRequest(),
          statusCode: 200,
          body: _ocsBody(data: [incomplete]),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidBansResponse),
      );
    });

    test('refuses an undocumented status code', () {
      expect(
        () => decodeListBansResponse(
          request: listRequest(),
          statusCode: 418,
          body: _ocsBody(),
        ),
        _protocolFailure(TalkProtocolErrorCode.unsupportedHttpStatus),
      );
    });
  });
}
