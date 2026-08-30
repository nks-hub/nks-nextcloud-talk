import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final manifest = _readJsonObject(
    'contracts/chat-messages/fixtures/manifest.json',
  );
  final manifestFixtures = (manifest['fixtures']! as List<Object?>)
      .map(_asObject)
      .toList(growable: false);
  final headerSets = _headerSets(manifest);

  group('chat capability fixtures', () {
    final cases = _cases('capability.cases.json');
    for (final testCase in cases) {
      final id = testCase['id']! as String;
      test(id, () {
        ChatCapabilityProfile action() =>
            ChatCapabilityProfile.fromTalkFeatures(
              testCase['talkFeatures'],
              federated: testCase['federated']! as bool,
            );

        if (testCase['expectedError'] == true) {
          expect(action, throwsA(isA<TalkProtocolException>()));
          return;
        }
        final profile = action();
        final expected = _asObject(testCase['expected']);
        expect(profile.read, expected['read']);
        expect(profile.sendText, expected['sendText']);
        expect(profile.reply, expected['reply']);
        expect(profile.privateReply, expected['privateReply']);
        expect(profile.backgroundCatchUp, expected['backgroundCatchUp']);
        expect(profile.threadFetch, expected['threadFetch']);
        expect(profile.setReadMarker, expected['setReadMarker']);
        expect(profile.markUnread, expected['markUnread']);
      });
    }
  });

  group('chat request fixtures', () {
    final cases = _cases('query.cases.json');
    for (final testCase in cases) {
      final id = testCase['id']! as String;
      test(id, () {
        ChatRequest action() => _requestFromCase(id, testCase);

        if (testCase['expectedError'] == true) {
          expect(action, throwsA(isA<TalkProtocolException>()));
          return;
        }

        final request = action();
        final expected = _asObject(testCase['expected']);
        expect(request.method.name.toUpperCase(), expected['method']);
        expect(request.queryParameters, _stringMap(expected['query']));
        expect(request.headers, _stringMap(expected['headers']));
        expect(request.formBody, expected['body']);
      });
    }

    test('builds a subpath-aware chat URI', () {
      final request = ChatFetchRequest(
        accountId: AccountId.parse('fixture-account'),
        requestId: ChatRequestId.parse('subpath-request'),
        server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
        roomToken: _token('rooma123'),
        profile: _profile(<Object?>['chat-v2']),
        direction: ChatFetchDirection.history,
        cursor: ChatCursor.parse('109'),
        lastCommonRead: ChatCursor.parse('100'),
        limit: 100,
        includeLastKnown: true,
        timeoutSeconds: 0,
        interactive: true,
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/nextcloud'
        '/ocs/v2.php/apps/spreed/api/v1/chat/rooma123'
        '?format=json&lookIntoFuture=0&limit=100&lastKnownMessageId=109'
        '&lastCommonReadId=100&timeout=0&setReadMarker=0'
        '&includeLastKnown=1&noStatusUpdate=0&markNotificationsAsRead=1',
      );
    });

    test('requires convergence before a future long poll', () {
      expect(
        () => ChatFetchRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ChatRequestId.parse('long-poll'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomToken: _token('rooma123'),
          profile: _profile(<Object?>['chat-v2']),
          direction: ChatFetchDirection.future,
          cursor: ChatCursor.parse('114'),
          lastCommonRead: ChatCursor.parse('110'),
          limit: 100,
          includeLastKnown: false,
          timeoutSeconds: 30,
          interactive: true,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('chat identifiers', () {
    test('compares twenty-digit cursors without integer conversion', () {
      final lower = ChatCursor.parse('9223372036854775808');
      final higher = ChatCursor.parse('18446744073709551615');
      expect(lower.compareTo(higher), lessThan(0));
      expect(higher.compareTo(lower), greaterThan(0));
    });

    test('redacts request and operation identifiers', () {
      final requestId = ChatRequestId.parse('private-request-id');
      final operationId = ChatOperationId.parse(
        'aaaaaaaa-0000-4000-8000-000000000001',
      );
      final referenceId = ChatReferenceId.parse(
        '11111111-1111-4111-8111-111111111111',
      );
      expect(requestId.toString(), isNot(contains(requestId.value)));
      expect(operationId.toString(), isNot(contains(operationId.value)));
      expect(referenceId.toString(), isNot(contains(referenceId.value)));
    });
  });

  group('chat geo location', () {
    test('accepts the upstream string coordinates and builds an OSM URI', () {
      final parameter = ChatRichObjectParameter.fromJson(<String, Object?>{
        'type': 'geo-location',
        'id': 'geo:48.85837,2.29448',
        'name': 'Eiffel Tower',
        'latitude': '48.85837',
        'longitude': '2.29448',
      });

      final location = ChatGeoLocation.fromParameter(parameter);

      expect(location, isNotNull);
      expect(location!.name, 'Eiffel Tower');
      expect(location.latitude, 48.85837);
      expect(location.longitude, 2.29448);
      expect(
        location.openStreetMapUri.toString(),
        'https://www.openstreetmap.org/'
        '?mlat=48.85837&mlon=2.29448#map=16/48.85837/2.29448',
      );
    });

    test('rejects malformed and out of range coordinates', () {
      for (final coordinates in <(Object?, Object?)>[
        ('not-a-number', '2.29448'),
        ('91', '2.29448'),
        ('48.85837', '-181'),
        (double.nan, 2.29448),
      ]) {
        final parameter = ChatRichObjectParameter.fromJson(<String, Object?>{
          'type': 'geo-location',
          'id': 'geo:fixture',
          'name': 'Invalid place',
          'latitude': coordinates.$1,
          'longitude': coordinates.$2,
        });

        expect(ChatGeoLocation.fromParameter(parameter), isNull);
      }
    });
  });

  group('chat response fixtures', () {
    final fixtures = manifestFixtures.where(
      (fixture) => fixture['direction'] == 'response',
    );
    for (final fixture in fixtures) {
      final id = fixture['id']! as String;
      test(id, () {
        Object action() {
          final body = fixture['status'] == '304'
              ? Uint8List(0)
              : _readBytes(
                  'contracts/chat-messages/fixtures/${fixture['file']}',
                );
          final headers = ChatResponseHeaders.fromMap(
            _fixtureHeaders(fixture, headerSets),
          );
          final statusCode = int.parse(fixture['status']! as String);
          return switch (fixture['operationId']) {
            'getChatMessages' => decodeChatGetResponse(
              request: _fetchRequest(id, _asObject(fixture['context'])),
              statusCode: statusCode,
              body: body,
              headers: headers,
            ),
            'sendChatMessage' => decodeChatSendResponse(
              request: _sendRequest(id, _asObject(fixture['context'])),
              statusCode: statusCode,
              body: body,
              headers: headers,
            ),
            'setChatReadMarker' || 'markChatUnread' => decodeChatReadResponse(
              request: _readRequest(
                id,
                fixture['operationId']! as String,
                _asObject(fixture['context']),
              ),
              statusCode: statusCode,
              body: body,
              headers: headers,
            ),
            _ => throw StateError('Unknown response operation'),
          };
        }

        if (fixture['expectedClassification'] == 'semantic-error') {
          expect(
            action,
            throwsA(
              isA<TalkProtocolException>().having(
                (error) => error.code,
                'code',
                TalkProtocolErrorCode.invalidChatResponse,
              ),
            ),
          );
          return;
        }

        final response = action();
        switch (response) {
          case final ChatGetResponse getResponse:
            expect(
              getResponse.classification,
              _getClassification(fixture['expectedClassification']! as String),
            );
            if (fixture.containsKey('expectedMessageCount')) {
              expect(
                getResponse.messages.length,
                fixture['expectedMessageCount'],
              );
            }
            if (fixture.containsKey('expectedCursor')) {
              expect(getResponse.cursor?.value, fixture['expectedCursor']);
            }
            if (fixture.containsKey('expectedCommonRead')) {
              expect(
                getResponse.lastCommonRead?.value,
                fixture['expectedCommonRead'],
              );
            }
          case final ChatSendResponse sendResponse:
            expect(
              sendResponse.classification,
              _sendClassification(fixture['expectedClassification']! as String),
            );
            if (fixture.containsKey('expectedMessageId')) {
              expect(sendResponse.messageId, fixture['expectedMessageId']);
            }
            if (fixture.containsKey('expectedRetryAfterSeconds')) {
              expect(
                sendResponse.retryAfterSeconds,
                fixture['expectedRetryAfterSeconds'],
              );
            }
          case final ChatReadResponse readResponse:
            expect(
              readResponse.classification,
              _readClassification(fixture['expectedClassification']! as String),
            );
            final expectedLastRead = fixture['expectedLastReadMessage'];
            if (expectedLastRead != null) {
              expect(readResponse.marker?.lastReadMessage, expectedLastRead);
            }
          default:
            fail('Unknown response type');
        }
      });
    }
  });

  group('chat request manifest fixtures', () {
    final fixtures = manifestFixtures.where(
      (fixture) => fixture['direction'] == 'request',
    );
    for (final fixture in fixtures) {
      final id = fixture['id']! as String;
      test(id, () {
        final json = _readJsonObject(
          'contracts/chat-messages/fixtures/${fixture['file']}',
        );
        Object action() => _requestManifestBody(id, fixture, json);
        if (fixture['schemaValid'] == false) {
          expect(action, throwsA(isA<TalkProtocolException>()));
          return;
        }
        expect(action(), json);
      });
    }
  });
}

Object _requestManifestBody(
  String id,
  Map<String, Object?> fixture,
  Map<String, Object?> json,
) {
  final threadId = json['threadId'] as int?;
  final profile = _profile(<Object?>[
    'chat-v2',
    'chat-reference-id',
    'chat-replies',
    'private-reply',
    'chat-read-marker',
    'chat-read-last',
    if (threadId != null) 'threads',
  ]);
  if (fixture['operationId'] == 'setChatReadMarker') {
    return ChatSetReadMarkerRequest(
      accountId: AccountId.parse('fixture-account'),
      requestId: ChatRequestId.parse('manifest-$id'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: _token('rooma123'),
      profile: profile,
      lastReadMessage: json['lastReadMessage']! as int,
    ).formBody;
  }
  final isCrossRoom = json['replyToToken'] != null;
  final request = isCrossRoom
      ? ChatSendRequest.restored(
          accountId: AccountId.parse('fixture-account'),
          requestId: ChatRequestId.parse('manifest-$id'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomToken: _token('direct456'),
          operationId: _operationId(),
          profile: profile,
          message: json['message']! as String,
          referenceId: ChatReferenceId.parse(json['referenceId']),
          replyTo: json['replyTo'] as int?,
          parentRoomToken: _token('source789'),
          replyToToken: _token(json['replyToToken']),
        )
      : ChatSendRequest(
          accountId: AccountId.parse('fixture-account'),
          requestId: ChatRequestId.parse('manifest-$id'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomToken: _token('rooma123'),
          operationId: _operationId(),
          profile: profile,
          message: json['message']! as String,
          referenceId: ChatReferenceId.parse(json['referenceId']),
          replyTo: json['replyTo'] as int?,
          threadId: threadId,
          parentRoomToken: json['replyTo'] == null ? null : _token('rooma123'),
        );
  return request.formBody;
}

ChatFetchRequest _fetchRequest(String id, Map<String, Object?> context) {
  final direction = context['direction'] == 'history'
      ? ChatFetchDirection.history
      : ChatFetchDirection.future;
  final threadId = context['threadId'] as int?;
  return ChatFetchRequest(
    accountId: AccountId.parse('fixture-account'),
    requestId: ChatRequestId.parse('fixture-$id'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: _token(context['roomToken']),
    profile: _profile(<Object?>['chat-v2', if (threadId != null) 'threads']),
    direction: direction,
    cursor: ChatCursor.parse(
      direction == ChatFetchDirection.history ? '999' : '0',
    ),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: direction == ChatFetchDirection.history,
    timeoutSeconds: 0,
    interactive: true,
    threadId: threadId,
  );
}

ChatRequest _readRequest(
  String id,
  String operationId,
  Map<String, Object?> context,
) {
  final profile = _profile(<Object?>[
    'chat-v2',
    'chat-read-marker',
    'chat-read-last',
    'chat-unread',
  ]);
  final accountId = AccountId.parse('fixture-account');
  final requestId = ChatRequestId.parse('fixture-$id');
  final server = ServerBase.parse('https://cloud.example.invalid');
  final roomToken = _token(context['roomToken']);
  return operationId == 'setChatReadMarker'
      ? ChatSetReadMarkerRequest(
          accountId: accountId,
          requestId: requestId,
          server: server,
          roomToken: roomToken,
          profile: profile,
          lastReadMessage: context['lastReadMessage']! as int,
        )
      : ChatMarkUnreadRequest(
          accountId: accountId,
          requestId: requestId,
          server: server,
          roomToken: roomToken,
          profile: profile,
        );
}

ChatSendRequest _sendRequest(String id, Map<String, Object?> context) {
  final replyTo = context['replyTo'] as int?;
  final threadId = context['threadId'] as int?;
  final parentToken = context['parentRoomToken'] == null
      ? null
      : _token(context['parentRoomToken']);
  final replyToken = context['replyToToken'] == null
      ? null
      : _token(context['replyToToken']);
  final profile = _profile(<Object?>[
    'chat-v2',
    'chat-reference-id',
    'chat-replies',
    'private-reply',
    if (threadId != null) 'threads',
  ]);
  return ChatSendRequest.restored(
    accountId: AccountId.parse('fixture-account'),
    requestId: ChatRequestId.parse('fixture-$id'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: _token(context['roomToken']),
    operationId: _operationId(),
    profile: profile,
    message: 'Fixture message',
    referenceId: ChatReferenceId.parse(context['referenceId']),
    replyTo: replyTo,
    threadId: threadId,
    parentRoomToken: parentToken,
    replyToToken: replyToken,
  );
}

ChatOperationId _operationId() =>
    ChatOperationId.parse('aaaaaaaa-0000-4000-8000-000000000001');

ChatGetClassification _getClassification(String value) => switch (value) {
  'messages' => ChatGetClassification.messages,
  'invisible-cursor-advance' => ChatGetClassification.invisibleCursorAdvance,
  'common-read-only' => ChatGetClassification.commonReadOnly,
  'not-modified' => ChatGetClassification.notModified,
  'reauth' => ChatGetClassification.reauthenticationRequired,
  'thread-not-found' => ChatGetClassification.threadNotFound,
  'transient-error' => ChatGetClassification.transientError,
  'ocs-error' => ChatGetClassification.ocsError,
  _ => throw StateError('Unknown GET classification'),
};

ChatReadClassification _readClassification(String value) => switch (value) {
  'read-confirmed' => ChatReadClassification.readConfirmed,
  'unread-confirmed' => ChatReadClassification.unreadConfirmed,
  'reauth' => ChatReadClassification.reauthenticationRequired,
  'ocs-error' => ChatReadClassification.ocsError,
  _ => throw StateError('Unknown read classification'),
};

ChatSendClassification _sendClassification(String value) => switch (value) {
  'send-confirmed' => ChatSendClassification.confirmed,
  'send-unconfirmed' => ChatSendClassification.unconfirmed,
  'send-ambiguous' => ChatSendClassification.ambiguous,
  'deterministic-failure' => ChatSendClassification.deterministicFailure,
  'rate-limited' => ChatSendClassification.rateLimited,
  'reauth' => ChatSendClassification.reauthenticationRequired,
  'server-error' => ChatSendClassification.serverError,
  _ => throw StateError('Unknown send classification'),
};

ChatRequest _requestFromCase(String id, Map<String, Object?> testCase) {
  final features = testCase['capabilities']! as List<Object?>;
  final input = _asObject(testCase['input']);
  final federated = input['federated'] as bool? ?? false;
  final profile = _profile(features, federated: federated);
  final targetToken = _token(input['targetRoomToken'] ?? 'rooma123');
  final common = <String, Object?>{
    'accountId': AccountId.parse('fixture-account'),
    'requestId': ChatRequestId.parse('query-$id'),
    'server': ServerBase.parse('https://cloud.example.invalid'),
    'roomToken': targetToken,
  };

  return switch (testCase['kind']) {
    'fetch' => ChatFetchRequest(
      accountId: common['accountId']! as AccountId,
      requestId: common['requestId']! as ChatRequestId,
      server: common['server']! as ServerBase,
      roomToken: targetToken,
      profile: profile,
      direction: switch (input['direction']) {
        'history' => ChatFetchDirection.history,
        'future' => ChatFetchDirection.future,
        _ => throw StateError('Unknown fetch direction'),
      },
      cursor: ChatCursor.parse(
        input['cursor'],
        path: r'$.query.lastKnownMessageId',
        code: TalkProtocolErrorCode.invalidChatRequest,
      ),
      lastCommonRead: ChatCursor.parse(
        input['lastCommonRead'],
        path: r'$.query.lastCommonReadId',
        code: TalkProtocolErrorCode.invalidChatRequest,
      ),
      limit: input['limit']! as int,
      includeLastKnown: input['includeLastKnown'] as bool? ?? false,
      timeoutSeconds: input['timeout'] as int? ?? 0,
      interactive: input['interactive']! as bool,
      threadId: input['threadId'] as int?,
      futureConverged: input['timeout'] == 30,
    ),
    'send' => ChatSendRequest(
      accountId: common['accountId']! as AccountId,
      requestId: common['requestId']! as ChatRequestId,
      server: common['server']! as ServerBase,
      roomToken: targetToken,
      operationId: ChatOperationId.parse(
        'aaaaaaaa-0000-4000-8000-000000000001',
      ),
      profile: profile,
      message: input['message']! as String,
      referenceId: ChatReferenceId.parse(input['referenceId']),
      replyTo: input['replyTo'] as int?,
      threadId: input['threadId'] as int?,
      parentRoomToken: input['parentRoomToken'] == null
          ? null
          : _token(input['parentRoomToken']),
      replyToToken: input['replyToToken'] == null
          ? null
          : _token(input['replyToToken']),
    ),
    'read' => ChatSetReadMarkerRequest(
      accountId: common['accountId']! as AccountId,
      requestId: common['requestId']! as ChatRequestId,
      server: common['server']! as ServerBase,
      roomToken: targetToken,
      profile: profile,
      lastReadMessage: input['lastReadMessage']! as int,
    ),
    'unread' => ChatMarkUnreadRequest(
      accountId: common['accountId']! as AccountId,
      requestId: common['requestId']! as ChatRequestId,
      server: common['server']! as ServerBase,
      roomToken: targetToken,
      profile: profile,
    ),
    _ => throw StateError('Unknown request kind'),
  };
}

ChatCapabilityProfile _profile(
  List<Object?> features, {
  bool federated = false,
}) => ChatCapabilityProfile.fromTalkFeatures(features, federated: federated);

ConversationToken _token(Object? value) => ConversationToken.parse(
  value,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidChatRequest,
);

List<Map<String, Object?>> _cases(String filename) {
  final root = _readJsonObject('contracts/chat-messages/fixtures/$filename');
  return (root['cases']! as List<Object?>)
      .map(_asObject)
      .toList(growable: false);
}

Map<String, Object?> _readJsonObject(String relativePath) {
  final file = File('${_repoRoot().path}/$relativePath');
  return _asObject(jsonDecode(file.readAsStringSync()));
}

Map<String, Object?> _asObject(Object? value) {
  return (value! as Map<Object?, Object?>).cast<String, Object?>();
}

Map<String, String> _stringMap(Object? value) {
  return (value! as Map<Object?, Object?>).map(
    (key, item) => MapEntry(key! as String, item! as String),
  );
}

Map<String, Map<String, String>> _headerSets(Map<String, Object?> manifest) {
  return _asObject(
    manifest['headerSets'],
  ).map((key, value) => MapEntry(key, _stringMap(value)));
}

Map<String, String> _fixtureHeaders(
  Map<String, Object?> fixture,
  Map<String, Map<String, String>> headerSets,
) {
  final headerSet = fixture['headerSet'];
  return headerSet == null ? const <String, String>{} : headerSets[headerSet]!;
}

Uint8List _readBytes(String relativePath) {
  return File('${_repoRoot().path}/$relativePath').readAsBytesSync();
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/chat-messages/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
