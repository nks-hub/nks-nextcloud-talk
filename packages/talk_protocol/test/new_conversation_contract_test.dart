import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('RecipientSearchRequest', () {
    test('builds an autocomplete/get URI scoped to a new conversation', () {
      final request = RecipientSearchRequest(
        accountId: AccountId.parse('fixture-account'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        searchTerm: 'alice',
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/core/autocomplete/get'
        '?format=json&itemType=call&itemId=new&search=alice'
        '&shareTypes%5B%5D=0&shareTypes%5B%5D=1',
      );
      expect(request.headers['OCS-APIRequest'], 'true');
    });

    test('rejects an empty search term', () {
      expect(
        () => RecipientSearchRequest(
          accountId: AccountId.parse('fixture-account'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          searchTerm: '',
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRecipientSearchRequest,
          ),
        ),
      );
    });

    test('rejects a search term carrying a control character', () {
      expect(
        () => RecipientSearchRequest(
          accountId: AccountId.parse('fixture-account'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          searchTerm: 'ali\nce',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('decodeRecipientSearchResponse', () {
    test('parses users and groups from a successful search', () {
      final response = decodeRecipientSearchResponse(
        request: _searchRequest(),
        statusCode: 200,
        json: {
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': [
              {
                'id': 'alice',
                'label': 'Alice Example',
                'source': 'users',
                'subline': 'alice@example.invalid',
              },
              {'id': 'engineering', 'label': 'Engineering', 'source': 'groups'},
            ],
          },
        },
      );

      expect(response, isA<RecipientSearchSuccess>());
      final success = response as RecipientSearchSuccess;
      expect(success.recipients, hasLength(2));
      expect(success.recipients[0].id, 'alice');
      expect(success.recipients[0].shareType, RecipientShareType.user);
      expect(success.recipients[0].subline, 'alice@example.invalid');
      expect(success.recipients[1].shareType, RecipientShareType.group);
      expect(success.recipients[1].subline, isNull);
    });

    test('reports HTTP 401 as reauthentication required', () {
      final response = decodeRecipientSearchResponse(
        request: _searchRequest(),
        statusCode: 401,
        json: {
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 401},
            'data': <Object?>[],
          },
        },
      );

      expect(response, isA<RecipientSearchReauthenticationRequired>());
    });

    test('reports an OCS-level failure without throwing', () {
      final response = decodeRecipientSearchResponse(
        request: _searchRequest(),
        statusCode: 200,
        json: {
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 400},
            'data': <Object?>[],
          },
        },
      );

      expect(response, isA<RecipientSearchOcsFailure>());
      expect((response as RecipientSearchOcsFailure).ocsStatusCode, 400);
    });

    test('rejects a duplicate user/group pair', () {
      expect(
        () => decodeRecipientSearchResponse(
          request: _searchRequest(),
          statusCode: 200,
          json: {
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200},
              'data': [
                {'id': 'alice', 'label': 'Alice', 'source': 'users'},
                {'id': 'alice', 'label': 'Alice Again', 'source': 'users'},
              ],
            },
          },
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRecipientSearchResponse,
          ),
        ),
      );
    });

    test('rejects an unknown recipient source', () {
      expect(
        () => decodeRecipientSearchResponse(
          request: _searchRequest(),
          statusCode: 200,
          json: {
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200},
              'data': [
                {'id': 'circle1', 'label': 'A circle', 'source': 'circles'},
              ],
            },
          },
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a malformed root document', () {
      expect(
        () => decodeRecipientSearchResponse(
          request: _searchRequest(),
          statusCode: 200,
          json: 'not-an-object',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('CreateConversationRequest', () {
    test('builds a one-to-one invite without a room name', () {
      final request = CreateConversationRequest(
        accountId: AccountId.parse('fixture-account'),
        requestId: ConversationRequestId.parse('create-1'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomType: CreateConversationRoomType.oneToOne,
        inviteId: 'alice',
        inviteSource: 'users',
      );

      expect(request.formBody, {
        'roomType': '1',
        'invite': 'alice',
        'source': 'users',
      });
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room'
        '?format=json',
      );
    });

    test('builds a group invite carrying a room name', () {
      final request = CreateConversationRequest(
        accountId: AccountId.parse('fixture-account'),
        requestId: ConversationRequestId.parse('create-2'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomType: CreateConversationRoomType.group,
        inviteId: 'engineering',
        inviteSource: 'groups',
        roomName: 'Engineering',
      );

      expect(request.formBody, {
        'roomType': '2',
        'invite': 'engineering',
        'source': 'groups',
        'roomName': 'Engineering',
      });
    });

    test('builds an empty group without invite fields', () {
      final request = CreateConversationRequest(
        accountId: AccountId.parse('fixture-account'),
        requestId: ConversationRequestId.parse('create-empty-group'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomType: CreateConversationRoomType.group,
        roomName: 'Project room',
      );

      expect(request.formBody, {'roomType': '2', 'roomName': 'Project room'});
    });

    test('builds a public room without invite fields', () {
      final request = CreateConversationRequest(
        accountId: AccountId.parse('fixture-account'),
        requestId: ConversationRequestId.parse('create-public'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomType: CreateConversationRoomType.public,
        roomName: 'Town hall',
      );

      expect(request.formBody, {'roomType': '3', 'roomName': 'Town hall'});
    });

    test('rejects a one-to-one room without an invite', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-missing-invite'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.oneToOne,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a public room carrying an invite', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-public-invite'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.public,
          inviteId: 'alice',
          inviteSource: 'users',
          roomName: 'Town hall',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a public room without a name', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-public-no-name'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.public,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects an invite id without its source', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-partial-invite'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.group,
          inviteId: 'alice',
          roomName: 'Project room',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a group invite without a room name', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-3'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.group,
          inviteId: 'engineering',
          inviteSource: 'groups',
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidCreateConversationRequest,
          ),
        ),
      );
    });

    test('rejects a one-to-one invite carrying a room name', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-4'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.oneToOne,
          inviteId: 'alice',
          inviteSource: 'users',
          roomName: 'Alice',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects an unsupported invite source', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-5'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.oneToOne,
          inviteId: 'alice',
          inviteSource: 'circles',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects an empty invite id', () {
      expect(
        () => CreateConversationRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ConversationRequestId.parse('create-6'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomType: CreateConversationRoomType.oneToOne,
          inviteId: '',
          inviteSource: 'users',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('decodeCreateConversationResponse', () {
    test('parses the newly created room on OCS 201', () {
      final response = decodeCreateConversationResponse(
        request: _createRequest(),
        statusCode: 200,
        json: {
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 201, 'message': 'Created'},
            'data': _syntheticRoom(),
          },
        },
      );

      expect(response, isA<CreateConversationSuccess>());
      final success = response as CreateConversationSuccess;
      expect(success.room.token.value, 'newroom01');
      expect(success.room.type, 1);
    });

    test('reports HTTP 401 as reauthentication required', () {
      final response = decodeCreateConversationResponse(
        request: _createRequest(),
        statusCode: 401,
        json: {
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 401},
            'data': <Object?>[],
          },
        },
      );

      expect(response, isA<CreateConversationReauthenticationRequired>());
    });

    test('reports an OCS-level failure without throwing', () {
      final response = decodeCreateConversationResponse(
        request: _createRequest(),
        statusCode: 200,
        json: {
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 403},
            'data': <Object?>[],
          },
        },
      );

      expect(response, isA<CreateConversationOcsFailure>());
      expect((response as CreateConversationOcsFailure).ocsStatusCode, 403);
    });

    test('classifies HTTP 429 as a rate-limit failure', () {
      final response = decodeCreateConversationResponse(
        request: _createRequest(),
        statusCode: 429,
        json: null,
      );

      expect(response, isA<CreateConversationHttpFailure>());
      expect(
        (response as CreateConversationHttpFailure).kind,
        CreateConversationHttpFailureKind.rateLimited,
      );
    });

    test('rejects a malformed created-room payload', () {
      expect(
        () => decodeCreateConversationResponse(
          request: _createRequest(),
          statusCode: 200,
          json: {
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 201},
              'data': {'token': 'newroom01'},
            },
          },
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}

RecipientSearchRequest _searchRequest() => RecipientSearchRequest(
  accountId: AccountId.parse('fixture-account'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  searchTerm: 'alice',
);

CreateConversationRequest _createRequest() => CreateConversationRequest(
  accountId: AccountId.parse('fixture-account'),
  requestId: ConversationRequestId.parse('create-fixture'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomType: CreateConversationRoomType.oneToOne,
  inviteId: 'alice',
  inviteSource: 'users',
);

Map<String, Object?> _syntheticRoom() => {
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
  'displayName': 'Alice Example',
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
  'name': 'synthetic-new-room',
  'notificationCalls': 1,
  'notificationLevel': 1,
  'objectId': '',
  'objectType': '',
  'participantFlags': 0,
  'participantType': 1,
  'permissions': 255,
  'readOnly': 0,
  'recordingConsent': 0,
  'sessionId': 'fixture-session-new',
  'sipEnabled': 0,
  'token': 'newroom01',
  'type': 1,
  'unreadMention': false,
  'unreadMentionDirect': false,
  'unreadMessages': 0,
  'isArchived': false,
  'isImportant': false,
  'isSensitive': false,
  'tagIds': <Object?>[],
  'lastPinnedId': 0,
  'hiddenPinnedId': 0,
  'hasScheduledMessages': 0,
  'attributes': 0,
};
