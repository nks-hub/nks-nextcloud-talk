import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final account = AccountId.parse('fixture-account');
  final roomToken = ConversationToken.parse(
    'fixtureroom1',
    path: r'$.roomToken',
  );
  final otherRoomToken = ConversationToken.parse(
    'fixtureroom2',
    path: r'$.roomToken',
  );

  MessageSearchRequest globalRequest({
    String term = 'fixture term',
    int limit = 20,
    int? cursor,
  }) => MessageSearchRequest(
    accountId: account,
    requestId: SearchRequestId.parse('fixture-request'),
    server: server,
    scope: MessageSearchScope.global,
    term: term,
    limit: limit,
    cursor: cursor,
  );

  MessageSearchRequest currentRoomRequest({
    String term = 'fixture term',
    int limit = 20,
    int? cursor,
    ConversationToken? token,
  }) => MessageSearchRequest(
    accountId: account,
    requestId: SearchRequestId.parse('fixture-request'),
    server: server,
    scope: MessageSearchScope.currentRoom,
    term: term,
    limit: limit,
    cursor: cursor,
    roomToken: token ?? roomToken,
  );

  Map<String, Object?> searchEntry({
    String title = 'Fixture Author',
    String subline = 'Fixture excerpt text matching the search term.',
    String conversation = 'fixtureroom1',
    String messageId = '42',
    int? timestamp = 1770000000,
    String? threadId,
    String resourceUrl =
        'https://cloud.example.invalid/call/fixtureroom1#message_42',
  }) => {
    'thumbnailUrl': '',
    'title': title,
    'subline': subline,
    'resourceUrl': resourceUrl,
    'icon': 'icon-talk',
    'rounded': false,
    'attributes': {
      'conversation': conversation,
      'messageId': messageId,
      'threadId': ?threadId,
      'timestamp': ?timestamp,
    },
  };

  Object? successBody({
    List<Object?>? entries,
    bool isPaginated = true,
    int? cursor = 20,
  }) => {
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200},
      'data': {
        'name': 'Messages',
        'isPaginated': isPaginated,
        'cursor': cursor,
        'entries': entries ?? [searchEntry()],
      },
    },
  };

  group('MessageSearchRequest validation', () {
    test('builds the global-provider URI with term, limit and cursor', () {
      final request = globalRequest(term: 'invoice', limit: 15, cursor: 40);

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/search/providers/'
        'talk-message/search?format=json&term=invoice&limit=15&cursor=40',
      );
    });

    test('builds the current-room URI with a from route hint', () {
      final request = currentRoomRequest(term: 'invoice', limit: 10);

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/search/providers/'
        'talk-message-current/search?format=json&term=invoice&limit=10'
        '&from=%2Fcall%2Ffixtureroom1',
      );
    });

    test('omits cursor when absent', () {
      final request = globalRequest();

      expect(request.queryParameters.containsKey('cursor'), isFalse);
    });

    test('rejects an empty search term', () {
      expect(
        () => globalRequest(term: '   '),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidSearchRequest,
          ),
        ),
      );
    });

    test('rejects an overlong search term', () {
      expect(
        () => globalRequest(term: ''.padRight(501, 'a')),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a term with control characters', () {
      expect(
        () => globalRequest(term: 'line\nbreak'),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a limit below the minimum', () {
      expect(
        () => globalRequest(limit: 0),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a limit above the maximum', () {
      expect(
        () => globalRequest(limit: 51),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a negative cursor', () {
      expect(
        () => globalRequest(cursor: -1),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a current-room request without a room token', () {
      expect(
        () => MessageSearchRequest(
          accountId: account,
          requestId: SearchRequestId.parse('fixture-request'),
          server: server,
          scope: MessageSearchScope.currentRoom,
          term: 'invoice',
          limit: 20,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a global request carrying a room token', () {
      expect(
        () => MessageSearchRequest(
          accountId: account,
          requestId: SearchRequestId.parse('fixture-request'),
          server: server,
          scope: MessageSearchScope.global,
          term: 'invoice',
          limit: 20,
          roomToken: roomToken,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('does not leak the search term through toString', () {
      final request = globalRequest(term: 'fixture-secret-term');

      expect(request.toString(), isNot(contains('fixture-secret-term')));
    });
  });

  group('decodeMessageSearchResponse success shapes', () {
    test('classifies and decodes a single result', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(),
      );

      expect(response.classification, MessageSearchClassification.results);
      expect(response.results, hasLength(1));
      expect(response.providerName, 'Messages');
      expect(response.isPaginated, isTrue);
      expect(response.nextCursor, 20);

      final result = response.results.single;
      expect(result.messageId, 42);
      expect(result.roomToken, roomToken);
      expect(result.author, 'Fixture Author');
      expect(result.excerpt, 'Fixture excerpt text matching the search term.');
      expect(
        result.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1770000000 * 1000, isUtc: true),
      );
      expect(result.resourceUrl, contains('fixtureroom1'));
    });

    // The live provider serialises attributes as strings; a numeric
    // timestamp only ever appeared in hand-written fixtures. Requiring the
    // number made every real search fail with invalidSearchResponse.
    test('decodes the string timestamp a live server sends', () {
      final entry = searchEntry(timestamp: null);
      final attributes = entry['attributes']! as Map<String, Object?>;
      attributes['timestamp'] = '1770000000';

      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(entries: [entry]),
      );

      expect(
        response.results.single.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1770000000 * 1000, isUtc: true),
      );
    });

    test('preserves the canonical thread id a live provider sends', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(entries: [searchEntry(threadId: '40')]),
      );

      expect(response.results.single.threadId, 40);
    });

    test('leaves thread id null for a root result outside a thread', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(entries: [searchEntry()]),
      );

      expect(response.results.single.threadId, isNull);
    });

    test('rejects a timestamp that is neither a number nor digits', () {
      final entry = searchEntry(timestamp: null);
      final attributes = entry['attributes']! as Map<String, Object?>;
      attributes['timestamp'] = 'not-a-timestamp';

      expect(
        () => decodeMessageSearchResponse(
          request: globalRequest(),
          statusCode: 200,
          json: successBody(entries: [entry]),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.path,
            'path',
            r'$.ocs.data.entries[0].attributes.timestamp',
          ),
        ),
      );
    });

    test('leaves timestamp null when the server omits it', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(entries: [searchEntry(timestamp: null)]),
      );

      expect(response.results.single.timestamp, isNull);
    });

    test('truncates an overlong excerpt', () {
      final longSubline = ''.padRight(400, 'x');
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(entries: [searchEntry(subline: longSubline)]),
      );

      final excerpt = response.results.single.excerpt;
      expect(excerpt.length, messageSearchExcerptMaximumLength + 1);
      expect(excerpt, endsWith('…'));
    });

    test('classifies zero entries as empty', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(entries: const []),
      );

      expect(response.classification, MessageSearchClassification.empty);
      expect(response.results, isEmpty);
    });

    test('accepts a current-room result matching the requested room', () {
      final response = decodeMessageSearchResponse(
        request: currentRoomRequest(),
        statusCode: 200,
        json: successBody(),
      );

      expect(response.classification, MessageSearchClassification.results);
    });

    test('does not leak the excerpt or author through toString', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: successBody(),
      );

      final rendered = response.results.single.toString();
      expect(rendered, isNot(contains('Fixture Author')));
      expect(rendered, isNot(contains('Fixture excerpt')));
    });
  });

  group('decodeMessageSearchResponse failure and edge shapes', () {
    test('classifies HTTP 401 as reauthentication required', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 401,
        json: null,
      );

      expect(
        response.classification,
        MessageSearchClassification.reauthenticationRequired,
      );
      expect(response.results, isEmpty);
    });

    test('classifies HTTP 404 as provider not found', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 404,
        json: null,
      );

      expect(
        response.classification,
        MessageSearchClassification.providerNotFound,
      );
    });

    test('classifies HTTP 429 and 503 as transient errors', () {
      for (final statusCode in [429, 503]) {
        final response = decodeMessageSearchResponse(
          request: globalRequest(),
          statusCode: statusCode,
          json: null,
        );

        expect(
          response.classification,
          MessageSearchClassification.transientError,
        );
      }
    });

    test('classifies an OCS-level failure body as ocsError', () {
      final response = decodeMessageSearchResponse(
        request: globalRequest(),
        statusCode: 200,
        json: {
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 400},
            'data': null,
          },
        },
      );

      expect(response.classification, MessageSearchClassification.ocsError);
    });

    test('rejects an unsupported HTTP status', () {
      expect(
        () => decodeMessageSearchResponse(
          request: globalRequest(),
          statusCode: 500,
          json: null,
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

    test('rejects a body missing the entries array', () {
      expect(
        () => decodeMessageSearchResponse(
          request: globalRequest(),
          statusCode: 200,
          json: {
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200},
              'data': {'name': 'Messages', 'isPaginated': false},
            },
          },
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidSearchResponse,
          ),
        ),
      );
    });

    test('rejects an entry missing the conversation attribute', () {
      final entry = searchEntry()..remove('attributes');
      expect(
        () => decodeMessageSearchResponse(
          request: globalRequest(),
          statusCode: 200,
          json: successBody(entries: [entry]),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects a non-numeric messageId', () {
      expect(
        () => decodeMessageSearchResponse(
          request: globalRequest(),
          statusCode: 200,
          json: successBody(entries: [searchEntry(messageId: 'not-a-number')]),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects an invalid canonical threadId', () {
      for (final threadId in <String>['0', '-1', 'not-a-number']) {
        expect(
          () => decodeMessageSearchResponse(
            request: globalRequest(),
            statusCode: 200,
            json: successBody(entries: [searchEntry(threadId: threadId)]),
          ),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.path,
              'path',
              r'$.ocs.data.entries[0].attributes.threadId',
            ),
          ),
        );
      }
    });

    test('rejects more entries than the maximum result cap', () {
      final entries = List<Object?>.generate(
        messageSearchMaximumResults + 1,
        (index) => searchEntry(messageId: '${index + 1}'),
      );

      expect(
        () => decodeMessageSearchResponse(
          request: globalRequest(),
          statusCode: 200,
          json: successBody(entries: entries),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('drops a current-room result that belongs to a different room', () {
      // `from` is a ranking hint, not a filter: a live Nextcloud 34 answered a
      // one-room search with an entry from another conversation. Rejecting the
      // whole response left the user with an error and no results, so the
      // foreign entry is dropped and the rest still arrives.
      final response = decodeMessageSearchResponse(
        request: currentRoomRequest(token: otherRoomToken),
        statusCode: 200,
        json: successBody(),
      );

      expect(response.results, isEmpty);
      expect(response.classification, MessageSearchClassification.empty);
    });
  });
}
