import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('conversation tags profile and requests', () {
    test('uses the authenticated capability and participant permission', () {
      final supported = ConversationTagsProfile.fromCapabilities(
        capabilities: _capabilities(),
        loggedInParticipant: true,
      );
      expect(supported.canLoadDefinitions, isTrue);
      expect(supported.canAssign, isTrue);

      final nonParticipant = ConversationTagsProfile.fromCapabilities(
        capabilities: _capabilities(),
        loggedInParticipant: false,
      );
      expect(nonParticipant.canLoadDefinitions, isTrue);
      expect(nonParticipant.canAssign, isFalse);
      expect(() => _assignRequest(profile: nonParticipant), _invalidRequest);

      for (final capabilities in <CapabilitySnapshot>[
        _capabilities(features: const <Object?>[]),
        _capabilities(context: CapabilityContext.anonymous),
      ]) {
        final unsupported = ConversationTagsProfile.fromCapabilities(
          capabilities: capabilities,
          loggedInParticipant: true,
        );
        expect(() => _fetchRequest(profile: unsupported), _invalidRequest);
        expect(() => _assignRequest(profile: unsupported), _invalidRequest);
      }
    });

    test('encodes user tags GET and full assignment JSON POST', () {
      final fetch = _fetchRequest();
      expect(fetch.httpMethod, 'GET');
      expect(
        fetch.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/'
        'tags?format=json',
      );
      expect(fetch.headers['OCS-APIRequest'], 'true');

      final assign = _assignRequest(tagIds: const ['11', '22']);
      expect(assign.httpMethod, 'POST');
      expect(
        assign.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/'
        'room/rooma123/tags?format=json',
      );
      expect(assign.headers['Content-Type'], 'application/json; charset=utf-8');
      expect(jsonDecode(utf8.decode(assign.bodyBytes)), {
        'tagIds': ['11', '22'],
      });
      expect(assign.toString(), isNot(contains('11')));
      expect(assign.toString(), isNot(contains('rooma123')));
    });

    test('rejects duplicate, nonnumeric and oversized assignments', () {
      for (final ids in <List<String>>[
        const ['11', '11'],
        const ['not-numeric'],
        [for (var index = 0; index < 21; index++) '${index + 1}'],
      ]) {
        expect(() => _assignRequest(tagIds: ids), _invalidRequest);
      }
      expect(_assignRequest(tagIds: const []).tagIds, isEmpty);
    });
  });

  group('conversation tag response decoding', () {
    test('decodes, validates and sorts all user-scoped definitions', () {
      final response = decodeFetchConversationTagsResponse(
        request: _fetchRequest(),
        statusCode: 200,
        body: _body(200, [
          _tag('22', 'Work', 2, 'custom'),
          _tag('11', 'Favorites', 0, 'favorites'),
          _tag('33', 'Other', 3, 'other'),
        ]),
      );
      expect(response, isA<FetchConversationTagsSuccess>());
      final definitions =
          (response as FetchConversationTagsSuccess).definitions;
      expect(definitions.map((tag) => tag.id), ['11', '22', '33']);
      expect(definitions[1].type, ConversationTagType.custom);
    });

    test('fails closed on malformed definitions and envelopes', () {
      final malformed = <Object?>[
        [_tag('11', 'A', 0, 'custom'), _tag('11', 'B', 1, 'custom')],
        [_tag('abc', 'A', 0, 'custom')],
        [_tag('11', '', 0, 'custom')],
        [_tag('11', 'A', 0, 'unknown')],
      ];
      for (final data in malformed) {
        expect(
          () => decodeFetchConversationTagsResponse(
            request: _fetchRequest(),
            statusCode: 200,
            body: _body(200, data),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      expect(
        () => decodeFetchConversationTagsResponse(
          request: _fetchRequest(),
          statusCode: 200,
          body: Uint8List.fromList([0xff]),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('keeps participant scopes separate and trusts filtered room tags', () {
      final first = _assignRequest(
        accountId: 'account-a',
        tagIds: const ['11', '22'],
      );
      final second = _assignRequest(
        accountId: 'account-b',
        tagIds: const ['33'],
      );
      final firstResponse = decodeAssignConversationTagsResponse(
        request: first,
        statusCode: 200,
        body: _body(200, _room(tagIds: const ['22'])),
      );
      final secondResponse = decodeAssignConversationTagsResponse(
        request: second,
        statusCode: 200,
        body: _body(200, _room(tagIds: const ['33'])),
      );

      expect(firstResponse.request.accountId.value, 'account-a');
      expect(secondResponse.request.accountId.value, 'account-b');
      expect((firstResponse as AssignConversationTagsSuccess).room.tagIds, {
        '22',
      });
      expect((secondResponse as AssignConversationTagsSuccess).room.tagIds, {
        '33',
      });
    });

    test('rejects a wrong room or an unrequested returned tag', () {
      for (final room in <Map<String, Object?>>[
        _room(tagIds: const ['11'])..['token'] = 'other123',
        _room(tagIds: const ['99']),
      ]) {
        expect(
          () => decodeAssignConversationTagsResponse(
            request: _assignRequest(tagIds: const ['11']),
            statusCode: 200,
            body: _body(200, room),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
    });

    test(
      'classifies auth, permission, missing room and retryable failures',
      () {
        final request = _assignRequest();
        final classified = <int, Matcher>{
          401: isA<AssignConversationTagsReauthenticationRequired>(),
          403: isA<AssignConversationTagsForbidden>(),
          404: isA<AssignConversationTagsRoomMissing>(),
        };
        for (final entry in classified.entries) {
          expect(
            decodeAssignConversationTagsResponse(
              request: request,
              statusCode: entry.key,
              body: _body(entry.key, const <Object?>[], success: false),
            ),
            entry.value,
          );
        }
        for (final statusCode in const [429, 503]) {
          expect(
            decodeAssignConversationTagsResponse(
              request: request,
              statusCode: statusCode,
              body: Uint8List(0),
            ),
            isA<AssignConversationTagsHttpFailure>(),
          );
        }
      },
    );
  });
}

FetchConversationTagsRequest _fetchRequest({ConversationTagsProfile? profile}) {
  return FetchConversationTagsRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    profile: profile ?? _profile(),
  );
}

AssignConversationTagsRequest _assignRequest({
  String accountId = 'account-a',
  Iterable<String> tagIds = const ['11'],
  ConversationTagsProfile? profile,
}) {
  return AssignConversationTagsRequest(
    accountId: AccountId.parse(accountId),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: profile ?? _profile(),
    tagIds: tagIds,
  );
}

ConversationTagsProfile _profile() => ConversationTagsProfile.fromCapabilities(
  capabilities: _capabilities(),
  loggedInParticipant: true,
);

CapabilitySnapshot _capabilities({
  CapabilityContext context = CapabilityContext.authenticated,
  List<Object?> features = const ['conversation-tags'],
}) => CapabilitySnapshot.fromJson({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
      'version': {
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': {
        'spreed': {
          'features': features,
          'features-local': features,
          'config': <String, Object?>{},
          'version': '24.0.2',
        },
      },
    },
  },
}, context: context);

Map<String, Object?> _tag(String id, String name, int sortOrder, String type) =>
    {
      'id': id,
      'name': name,
      'sortOrder': sortOrder,
      'collapsed': false,
      'type': type,
    };

Map<String, Object?> _room({required List<String> tagIds}) {
  final root =
      jsonDecode(
            File(
              '../../contracts/conversation-list/fixtures/'
              'conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>)
    ..['tagIds'] = tagIds;
}

Uint8List _body(int statusCode, Object? data, {bool success = true}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {
              'status': success ? 'ok' : 'failure',
              'statuscode': statusCode,
              'message': success ? 'OK' : 'failure',
            },
            'data': data,
          },
        }),
      ),
    );

final Matcher _invalidRequest = throwsA(
  isA<TalkProtocolException>().having(
    (error) => error.code,
    'code',
    TalkProtocolErrorCode.invalidRoomSettingsRequest,
  ),
);
