import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final overviewRequest = SharedItemsOverviewRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('shared-overview-1'),
    server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
    roomToken: _roomToken(),
    sharedItemsAvailable: true,
    limit: 7,
  );

  test('builds bounded overview and page requests', () {
    expect(
      overviewRequest.uri.toString(),
      'https://cloud.example.invalid/nextcloud/ocs/v2.php/apps/spreed/'
      'api/v1/chat/rooma123/share/overview?format=json&limit=7',
    );
    expect(overviewRequest.headers['OCS-APIRequest'], 'true');

    final page = SharedItemsPageRequest(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('shared-page-1'),
      server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
      roomToken: _roomToken(),
      sharedItemsAvailable: true,
      type: SharedItemType.media,
      lastKnownMessageId: 0,
      limit: 28,
    );

    expect(page.queryParameters, {
      'format': 'json',
      'objectType': 'media',
      'lastKnownMessageId': '0',
      'limit': '28',
    });
  });

  test('rejects request bounds before constructing a URI', () {
    expect(
      () => SharedItemsOverviewRequest(
        accountId: AccountId.parse('account-a'),
        requestId: ChatRequestId.parse('shared-overview-invalid'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: _roomToken(),
        sharedItemsAvailable: true,
        limit: 21,
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => SharedItemsPageRequest(
        accountId: AccountId.parse('account-a'),
        requestId: ChatRequestId.parse('shared-page-invalid'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: _roomToken(),
        sharedItemsAvailable: true,
        type: SharedItemType.file,
        lastKnownMessageId: -1,
        limit: 201,
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('decodes overview categories and ignores an unknown future type', () {
    final response = decodeSharedItemsOverviewResponse(
      request: overviewRequest,
      statusCode: 200,
      body: _ocsBody({
        'file': [_message(110)],
        'media': [_message(112)],
        'future-type': <Object?>[],
      }),
    );

    expect(response.classification, SharedItemsClassification.success);
    expect(response.messagesByType.keys, {
      SharedItemType.file,
      SharedItemType.media,
    });
    expect(response.messagesByType[SharedItemType.file]!.single.messageId, 110);
    expect(
      response.messagesByType[SharedItemType.media]!.single.messageId,
      112,
    );
  });

  test('decodes a page in descending order and binds its cursor', () {
    final request = SharedItemsPageRequest(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('shared-page-response'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: _roomToken(),
      sharedItemsAvailable: true,
      type: SharedItemType.file,
      lastKnownMessageId: 0,
      limit: 2,
    );
    final response = decodeSharedItemsPageResponse(
      request: request,
      statusCode: 200,
      body: _ocsBody({'110': _message(110), '112': _message(112)}),
      headers: ChatResponseHeaders.fromMap({'X-Chat-Last-Given': '110'}),
    );

    expect(response.classification, SharedItemsClassification.success);
    expect(response.messages.map((message) => message.messageId), [112, 110]);
    expect(response.lastKnownMessageId, 110);
    expect(response.moreItemsPossible, isTrue);
  });

  test('an empty page terminates pagination without a cursor', () {
    final request = SharedItemsPageRequest(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('shared-page-empty'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: _roomToken(),
      sharedItemsAvailable: true,
      type: SharedItemType.poll,
      lastKnownMessageId: 110,
      limit: 28,
    );
    final response = decodeSharedItemsPageResponse(
      request: request,
      statusCode: 200,
      body: _ocsBody(<String, Object?>{}),
    );

    expect(response.messages, isEmpty);
    expect(response.lastKnownMessageId, isNull);
    expect(response.moreItemsPossible, isFalse);
  });

  test('rejects token mismatch, map-key mismatch, and missing cursor', () {
    final request = SharedItemsPageRequest(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('shared-page-invalid-response'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: _roomToken(),
      sharedItemsAvailable: true,
      type: SharedItemType.file,
      lastKnownMessageId: 0,
      limit: 28,
    );

    expect(
      () => decodeSharedItemsPageResponse(
        request: request,
        statusCode: 200,
        body: _ocsBody({'110': _message(110, token: 'other123')}),
        headers: ChatResponseHeaders.fromMap({'X-Chat-Last-Given': '110'}),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodeSharedItemsPageResponse(
        request: request,
        statusCode: 200,
        body: _ocsBody({'111': _message(110)}),
        headers: ChatResponseHeaders.fromMap({'X-Chat-Last-Given': '110'}),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodeSharedItemsPageResponse(
        request: request,
        statusCode: 200,
        body: _ocsBody({'110': _message(110)}),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('rejects a page that repeats an item at or above its cursor', () {
    final request = SharedItemsPageRequest(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('shared-page-repeated'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: _roomToken(),
      sharedItemsAvailable: true,
      type: SharedItemType.file,
      lastKnownMessageId: 110,
      limit: 28,
    );

    expect(
      () => decodeSharedItemsPageResponse(
        request: request,
        statusCode: 200,
        body: _ocsBody({'112': _message(112), '100': _message(100)}),
        headers: ChatResponseHeaders.fromMap({'X-Chat-Last-Given': '100'}),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('classifies an HTTP failure without decoding its body', () {
    final response = decodeSharedItemsOverviewResponse(
      request: overviewRequest,
      statusCode: 401,
      body: Uint8List(0),
    );

    expect(
      response.classification,
      SharedItemsClassification.reauthenticationRequired,
    );
  });

  for (final entry in const {
    401: SharedItemsClassification.reauthenticationRequired,
    404: SharedItemsClassification.roomNotFound,
    412: SharedItemsClassification.lobbyRestricted,
    429: SharedItemsClassification.rateLimited,
    503: SharedItemsClassification.serviceUnavailable,
  }.entries) {
    test('classifies HTTP ${entry.key}', () {
      final response = decodeSharedItemsOverviewResponse(
        request: overviewRequest,
        statusCode: entry.key,
        body: _ocsBody(<String, Object?>{}, success: false),
      );
      expect(response.classification, entry.value);
      expect(response.messagesByType, isEmpty);
    });
  }
}

Map<String, Object?> _message(int id, {String token = 'rooma123'}) {
  final fixture =
      jsonDecode(
            File(
              '../../contracts/chat-messages/fixtures/chat-future.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  final source = messages.first! as Map<String, Object?>;
  return <String, Object?>{...source, 'id': id, 'token': token};
}

Uint8List _ocsBody(Object? data, {bool success = true}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'ocs': {
        'meta': {
          'status': success ? 'ok' : 'failure',
          'statuscode': success ? 200 : 998,
          'message': success ? 'OK' : 'Failure',
        },
        'data': data,
      },
    }),
  ),
);

ConversationToken _roomToken() => ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidSharedItemsRequest,
);
