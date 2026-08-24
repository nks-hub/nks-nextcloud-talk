import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final manifest = _readJsonObject(
    'contracts/conversation-list/fixtures/manifest.json',
  );
  final fullHeaders = _stringMap(_asObject(manifest['headerSets'])['full']);
  final fullFixture = _readJsonObject(
    'contracts/conversation-list/fixtures/conversations-full.response.json',
  );

  test('accepts case-insensitive response header names', () {
    final headers = <String, String>{
      for (final entry in fullHeaders.entries)
        entry.key.toLowerCase(): entry.value,
      'Date': 'synthetic-one',
      'date': 'synthetic-two',
    };
    final response =
        _decodeResponse(
              statusCode: 200,
              json: _clone(fullFixture),
              headers: headers,
            )
            as ConversationListSuccess;

    expect(response.cursor.value, '1724300001');
    expect(response.federationInvites?.value, '0');
  });

  test('rejects case-insensitive duplicate response headers', () {
    final headers = Map<String, String>.of(fullHeaders)
      ..['x-nextcloud-talk-hash'] = 'fixture-hash-a';

    expect(
      () => _decodeResponse(
        statusCode: 200,
        json: _clone(fullFixture),
        headers: headers,
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationHeaders,
        ),
      ),
    );
  });

  test('rejects a malformed federation counter', () {
    final headers = Map<String, String>.of(fullHeaders)
      ..['X-Nextcloud-Talk-Federation-Invites'] = '-1';

    expect(
      () => _decodeResponse(
        statusCode: 200,
        json: _clone(fullFixture),
        headers: headers,
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationHeaders,
        ),
      ),
    );
  });

  test('redacts invalid room values from protocol diagnostics', () {
    const marker = 'PRIVATE_ROOM_VALUE_REDACTION_GUARD';
    final body = _clone(fullFixture);
    _firstRoom(body)['token'] = marker;

    final error = _captureProtocolError(
      () => _decodeResponse(statusCode: 200, json: body, headers: fullHeaders),
    );

    expect(error.toString(), isNot(contains(marker)));
    expect(error.path, r'$.ocs.data[0].token');
  });

  test('redacts dynamic Rich Object String keys from diagnostics', () {
    const marker = 'PRIVATE_PARAMETER_KEY_REDACTION_GUARD';
    final body = _clone(fullFixture);
    final lastMessage = _asObject(_firstRoom(body)['lastMessage']);
    final parameters = _asObject(lastMessage['messageParameters']);
    parameters[marker] = <String, Object?>{'type': 7};

    final error = _captureProtocolError(
      () => _decodeResponse(statusCode: 200, json: body, headers: fullHeaders),
    );

    expect(error.toString(), isNot(contains(marker)));
    expect(error.path, contains('[<member>].type'));
  });

  test('accepts PHP empty arrays for empty preview maps', () {
    final body = _clone(fullFixture);
    final lastMessage = _asObject(_firstRoom(body)['lastMessage']);
    lastMessage['messageParameters'] = <Object?>[];
    lastMessage['reactions'] = <Object?>[];

    final response =
        _decodeResponse(statusCode: 200, json: body, headers: fullHeaders)
            as ConversationListSuccess;

    expect(response.rooms.first.lastMessage?.messageParameters, isEmpty);
    expect(response.rooms.first.lastMessage?.reactions, isEmpty);
  });

  test('rejects non-empty arrays for preview maps', () {
    for (final key in <String>['messageParameters', 'reactions']) {
      final body = _clone(fullFixture);
      final lastMessage = _asObject(_firstRoom(body)['lastMessage']);
      lastMessage[key] = <Object?>['invalid'];

      expect(
        () =>
            _decodeResponse(statusCode: 200, json: body, headers: fullHeaders),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidConversationResponse,
          ),
        ),
      );
    }
  });

  test('rejects a preview without its room token', () {
    final body = _clone(fullFixture);
    final lastMessage = _asObject(_firstRoom(body)['lastMessage']);
    lastMessage.remove('token');

    expect(
      () => _decodeResponse(statusCode: 200, json: body, headers: fullHeaders),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.previewConversationMismatch,
        ),
      ),
    );
  });

  test('keeps room and preview wire objects deeply immutable', () {
    final response =
        _decodeResponse(
              statusCode: 200,
              json: _clone(fullFixture),
              headers: fullHeaders,
            )
            as ConversationListSuccess;
    final room = response.rooms.first;
    final previewWire = _asObject(room.wire['lastMessage']);
    final parameterWire = _asObject(previewWire['messageParameters']);

    expect(() => room.wire['token'] = 'other999', throwsUnsupportedError);
    expect(() => previewWire['message'] = 'changed', throwsUnsupportedError);
    expect(
      () => parameterWire['private'] = <String, Object?>{'type': 'user'},
      throwsUnsupportedError,
    );
    expect(() => response.rooms.add(room), throwsUnsupportedError);
  });

  test('does not stringify account, room, name or message values', () {
    final response =
        _decodeResponse(
              statusCode: 200,
              json: _clone(fullFixture),
              headers: fullHeaders,
            )
            as ConversationListSuccess;
    final room = response.rooms.first;
    final preview = room.lastMessage!;
    final privateValues = <String>[
      'account-private',
      room.token.value,
      room.displayName,
      room.name,
      room.description,
      preview.message,
      preview.actorId,
      preview.referenceId!,
      'fixture-tag',
    ];
    final rendered = <Object>[
      AccountId.parse('account-private'),
      room.token,
      response.configurationHash,
      response.responseHeaders,
      room,
      preview,
      room.wire,
      preview.wire,
      preview.messageParameters,
      room.tagIds,
      response,
    ].join('\n');

    for (final value in privateValues) {
      expect(rendered, isNot(contains(value)));
    }
  });

  test('rejects room wire data beyond the depth budget', () {
    final body = _clone(fullFixture);
    Object? nested = 'leaf';
    for (var depth = 0; depth < 70; depth++) {
      nested = <Object?>[nested];
    }
    _firstRoom(body)['futureDeepValue'] = nested;

    expect(
      () => _decodeResponse(statusCode: 200, json: body, headers: fullHeaders),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationResponse,
        ),
      ),
    );
  });

  test('enforces one node budget across a response', () {
    final body = _clone(fullFixture);
    _firstRoom(body)['futureWideValue'] = List<Object?>.filled(250001, null);

    expect(
      () => _decodeResponse(statusCode: 200, json: body, headers: fullHeaders),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationResponse,
        ),
      ),
    );
  });

  test('rejects more than the OpenAPI room limit before parsing rooms', () {
    final body = _clone(fullFixture);
    final ocs = _asObject(body['ocs']);
    final room = _firstRoom(body);
    ocs['data'] = List<Object?>.filled(conversationMaximumRooms + 1, room);

    expect(
      () => _decodeResponse(statusCode: 200, json: body, headers: fullHeaders),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidConversationResponse,
        ),
      ),
    );
  });
}

ConversationListResponse _decodeResponse({
  required int statusCode,
  required Object? json,
  Map<String, String> headers = const <String, String>{},
}) {
  return decodeConversationListResponse(
    request: ConversationListRequest(
      accountId: AccountId.parse('security-account'),
      requestId: ConversationRequestId.parse('security-request'),
      server: ServerBase.parse('https://security.example.invalid'),
      mode: ConversationFetchMode.full,
      includeLastMessage: false,
    ),
    statusCode: statusCode,
    json: json,
    headers: headers,
  );
}

TalkProtocolException _captureProtocolError(void Function() action) {
  try {
    action();
  } on TalkProtocolException catch (error) {
    return error;
  }
  throw StateError('Expected a TalkProtocolException');
}

Map<String, Object?> _firstRoom(Map<String, Object?> body) {
  final ocs = _asObject(body['ocs']);
  return _asObject((ocs['data']! as List<Object?>).first);
}

Map<String, Object?> _clone(Map<String, Object?> value) {
  return _asObject(jsonDecode(jsonEncode(value)));
}

Map<String, Object?> _readJsonObject(String relativePath) {
  final file = File('${_repoRoot().path}/$relativePath');
  return _asObject(jsonDecode(file.readAsStringSync()));
}

Map<String, Object?> _asObject(Object? value) {
  return (value! as Map<Object?, Object?>).cast<String, Object?>();
}

Map<String, String> _stringMap(Object? value) {
  return (value! as Map<Object?, Object?>).cast<String, String>();
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/conversation-list/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
