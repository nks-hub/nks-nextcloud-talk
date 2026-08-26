import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('rejects oversized, malformed, deep and over-budget responses', () {
    final request = _mentionsRequest();
    for (final body in <Uint8List>[
      Uint8List(richChatMaximumResponseBytes + 1),
      Uint8List.fromList(const <int>[0xff]),
      _successBody(_nestedValue(70)),
      _successBody(List<Object?>.filled(200001, 0)),
    ]) {
      expect(
        () => decodeRichChatResponse(
          request: request,
          statusCode: 200,
          body: body,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRichChatResponse,
          ),
        ),
      );
    }
  });

  test('requires exact HTTP and OCS status plus a data member', () {
    final request = _mentionsRequest();
    for (final body in <Uint8List>[
      _ocsBody(status: 'ok', statusCode: 201, data: const []),
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{'status': 'ok', 'statuscode': 200},
            },
          }),
        ),
      ),
    ]) {
      expect(
        () => decodeRichChatResponse(
          request: request,
          statusCode: 200,
          body: body,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    }

    expect(
      () => decodeRichChatResponse(
        request: request,
        statusCode: 204,
        body: _ocsBody(status: 'ok', statusCode: 204, data: const []),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('rejects response data bound to another room or message', () {
    final fixture = _fixture('edit-message-success');
    final body = _object(fixture['body']);
    final ocs = _object(body['ocs']);
    final data = _object(ocs['data']);
    final parent = _object(data['parent']);
    parent['token'] = 'roomb456';

    expect(
      () => decodeRichChatResponse(
        request: _editRequest(),
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidRichChatResponse,
        ),
      ),
    );
  });

  test('rejects nested thread messages outside the thread identity', () {
    final fixture = _fixture('recent-threads-success');
    final body = _object(fixture['body']);
    final data = _object(body['ocs'])['data']! as List<Object?>;
    final thread = _object(data.single);
    thread['first'] = <String, Object?>{..._message(), 'token': 'roomb456'};

    expect(
      () => decodeRichChatResponse(
        request: _recentThreadsRequest(),
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidRichChatResponse,
        ),
      ),
    );
  });

  for (final field in <String>['first', 'last']) {
    test('rejects $field message bound to another thread id', () {
      final fixture = _fixture('recent-threads-success');
      final body = _object(fixture['body']);
      final data = _object(body['ocs'])['data']! as List<Object?>;
      final threadInfo = _object(data.single);
      threadInfo[field] = <String, Object?>{
        ..._message(),
        'id': field == 'first' ? 120 : 122,
        'threadId': 999,
      };

      expect(
        () => decodeRichChatResponse(
          request: _recentThreadsRequest(),
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRichChatResponse,
          ),
        ),
      );
    });
  }

  test('keeps thread notification responses account and request scoped', () {
    final fixture = _fixture('thread-notify-success');
    final requestA = _notifyRequest(
      accountId: 'account-a',
      requestId: 'notify-account-a',
    );
    final requestB = _notifyRequest(
      accountId: 'account-b',
      requestId: 'notify-account-b',
    );

    final responseA = decodeRichChatResponse(
      request: requestA,
      statusCode: fixture['status']! as int,
      body: Uint8List.fromList(utf8.encode(jsonEncode(fixture['body']))),
    );
    final responseB = decodeRichChatResponse(
      request: requestB,
      statusCode: fixture['status']! as int,
      body: Uint8List.fromList(utf8.encode(jsonEncode(fixture['body']))),
    );

    expect(identical(responseA.request, requestA), isTrue);
    expect(identical(responseB.request, requestB), isTrue);
    expect(identical(responseA.request, responseB.request), isFalse);
    expect(responseA.request.accountId, isNot(responseB.request.accountId));
    expect(requestA.messageId, isNull);
    expect(requestA.threadId, 120);
    expect(requestA.requestPath, endsWith('/threads/120/notify'));
    expect(responseA.threads.single.threadId, 120);
  });

  test('rejects notification response bound to a reply instead of root', () {
    final fixture = _fixture('thread-notify-success');
    final body = _object(fixture['body']);
    final thread = _object(_object(_object(body['ocs'])['data'])['thread']);
    thread['id'] = 122;

    expect(
      () => decodeRichChatResponse(
        request: _notifyRequest(),
        statusCode: fixture['status']! as int,
        body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidRichChatResponse,
        ),
      ),
    );
  });

  test('rejects thread notification room and canonical root mismatches', () {
    final wrongRoom = _object(_fixture('thread-notify-success')['body']);
    final wrongRoomThread = _object(
      _object(_object(wrongRoom['ocs'])['data'])['thread'],
    );
    wrongRoomThread['roomToken'] = 'roomb456';

    final wrongRoot = _object(_fixture('thread-notify-success')['body']);
    final wrongRootThread = _object(
      _object(_object(wrongRoot['ocs'])['data'])['thread'],
    );
    wrongRootThread['id'] = 121;

    for (final body in <Map<String, Object?>>[wrongRoom, wrongRoot]) {
      expect(
        () => decodeRichChatResponse(
          request: _notifyRequest(),
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRichChatResponse,
          ),
        ),
      );
    }
  });

  test('rejects an invalid canonical root before notification dispatch', () {
    expect(
      () => _notifyRequest(threadId: 0),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidRichChatRequest,
        ),
      ),
    );
  });

  test('rejects duplicate thread and scheduled message identities', () {
    final threadFixture = _fixture('recent-threads-success');
    final threadBody = _object(threadFixture['body']);
    final threads = _object(threadBody['ocs'])['data']! as List<Object?>;
    threads.add(jsonDecode(jsonEncode(threads.single)));

    expect(
      () => decodeRichChatResponse(
        request: _recentThreadsRequest(),
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(jsonEncode(threadBody))),
      ),
      throwsA(isA<TalkProtocolException>()),
    );

    final scheduleFixture = _fixture('schedule-list-success');
    final scheduleBody = _object(scheduleFixture['body']);
    final schedules = _object(scheduleBody['ocs'])['data']! as List<Object?>;
    schedules.add(jsonDecode(jsonEncode(schedules.single)));

    expect(
      () => decodeRichChatResponse(
        request: _scheduledRequest(),
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(jsonEncode(scheduleBody))),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('rejects a scheduled parent from another room', () {
    final fixture = _fixture('schedule-list-success');
    final body = _object(fixture['body']);
    final data = _object(body['ocs'])['data']! as List<Object?>;
    _object(data.single)['parent'] = <String, Object?>{
      ..._message(),
      'token': 'roomb456',
    };

    expect(
      () => decodeRichChatResponse(
        request: _scheduledRequest(),
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidRichChatResponse,
        ),
      ),
    );
  });

  test('accepts ordinary scheduled messages with an optional parent', () {
    final fixture = _fixture('schedule-list-success');
    final body = _object(fixture['body']);
    final data = _object(body['ocs'])['data']! as List<Object?>;
    final scheduled = _object(data.single);

    RichChatScheduledMessage decode() => decodeRichChatResponse(
      request: _scheduledRequest(),
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
    ).scheduledMessages.single;

    final withoutParent = decode();
    final reparsedWithoutParent = RichChatScheduledMessage.fromJson(
      withoutParent.wire,
      roomToken: _token('rooma123'),
    );
    expect(withoutParent.threadId, 0);
    expect(withoutParent.parent, isNull);
    expect(reparsedWithoutParent.threadId, 0);
    expect(reparsedWithoutParent.parent, isNull);
    expect(
      () => withoutParent.wire['message'] = 'blocked',
      throwsUnsupportedError,
    );

    scheduled['parent'] = <String, Object?>{
      ..._message(),
      'threadId': 0,
      'isThread': false,
    };
    final withParent = decode();
    final reparsedWithParent = RichChatScheduledMessage.fromJson(
      withParent.wire,
      roomToken: _token('rooma123'),
    );
    expect(withParent.threadId, 0);
    expect(withParent.parent?.threadId, 0);
    expect(reparsedWithParent.threadId, 0);
    expect(reparsedWithParent.parent?.threadId, 0);
    expect(
      () => _object(withParent.wire['parent'])['message'] = 'blocked',
      throwsUnsupportedError,
    );
  });

  test('requires a named scheduled parent to match its thread identity', () {
    final fixture = _fixture('schedule-list-success');
    final body = _object(fixture['body']);
    final data = _object(body['ocs'])['data']! as List<Object?>;
    final scheduled = _object(data.single)
      ..['threadId'] = 120
      ..['threadTitle'] = 'Design'
      ..['parent'] = <String, Object?>{
        ..._message(),
        'threadId': 121,
        'isThread': true,
        'threadTitle': 'Design',
      };

    RichChatResponse decode() => decodeRichChatResponse(
      request: _scheduledRequest(),
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );

    expect(
      decode,
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidRichChatResponse,
        ),
      ),
    );

    _object(scheduled['parent'])['threadId'] = 120;
    final parsed = decode().scheduledMessages.single;
    final reparsed = RichChatScheduledMessage.fromJson(
      parsed.wire,
      roomToken: _token('rooma123'),
    );

    expect(parsed.threadId, 120);
    expect(parsed.parent?.threadId, 120);
    expect(reparsed.threadId, 120);
    expect(reparsed.parent?.threadId, 120);
  });

  test('wire models and request sections are deeply immutable', () {
    final source = <String, Object?>{
      'type': 'user',
      'id': 'user-a',
      'name': 'Private display',
      'extra': <String, Object?>{
        'values': <Object?>['original'],
      },
    };
    final parameter = ChatRichObjectParameter.fromJson(source);
    (_object(source['extra'])['values']! as List<Object?>)[0] = 'changed';
    final frozenExtra = _object(parameter.wire['extra']);
    expect(frozenExtra['values'], <Object?>['original']);
    expect(
      () => (frozenExtra['values']! as List<Object?>).add('blocked'),
      throwsUnsupportedError,
    );

    final request = _editRequest();
    expect(
      () => request.queryParameters['extra'] = 'blocked',
      throwsUnsupportedError,
    );
    expect(
      () => request.formBody!['message'] = 'blocked',
      throwsUnsupportedError,
    );

    final message = ChatMessage.fromJson(_message());
    final room = RichChatRoomState(
      roomToken: _token('rooma123'),
      messages: <int, ChatMessage>{120: message},
      threads: const {},
      reminders: const {},
      scheduledMessages: const {},
      lastMessageId: 120,
    );
    expect(() => room.messages[121] = message, throwsUnsupportedError);
  });

  test(
    'diagnostics redact request, response, actor and rich object content',
    () {
      final request = _editRequest(message: 'private-message-value');
      final fixture = _fixture('edit-message-success');
      final response = decodeRichChatResponse(
        request: request,
        statusCode: fixture['status']! as int,
        body: Uint8List.fromList(utf8.encode(jsonEncode(fixture['body']))),
      );
      final parameter = ChatRichObjectParameter.fromJson(<String, Object?>{
        'type': 'user',
        'id': 'private-user-id',
        'name': 'Private display',
      });
      final actor = RichChatActorIdentity(
        actorType: 'users',
        actorId: 'private-actor-id',
      );

      for (final diagnostic in <String>[
        request.toString(),
        response.toString(),
        response.messageMutation.toString(),
        parameter.toString(),
        actor.toString(),
      ]) {
        expect(diagnostic, isNot(contains('private')));
        expect(diagnostic, isNot(contains('rooma123')));
      }
    },
  );

  test('sanitizes active links at the semantic-tree boundary', () {
    final document = renderRichChatMessage(
      message:
          '[data](data:text/plain,x) [file](file:///tmp/x) '
          '[intent](intent://scan) [http](http://example.org) '
          '[cross](//evil.example/path) '
          '[credential](https://user:pass@example.org/path) '
          '[safe](https://example.org/path)',
      markdownEnabled: true,
      parameters: const {},
      server: ServerBase.parse('https://cloud.example.org'),
    );
    expect(document.activeLinks, <String>['https://example.org/path']);
  });

  test(
    'rejects render node amplification before the next parameter lookup',
    () {
      final parameter = ChatRichObjectParameter.fromJson(<String, Object?>{
        'type': 'user',
        'id': 'user-a',
        'name': 'User A',
      });
      for (final markdownEnabled in <bool>[false, true]) {
        final parameters = _LookupLimitedParameters(
          parameter: parameter,
          maximumLookups: 199999,
        );
        expect(
          () => renderRichChatMessage(
            message: '{a}' * 200000,
            markdownEnabled: markdownEnabled,
            parameters: parameters,
            server: ServerBase.parse('https://cloud.example.org'),
          ),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidRichChatRender,
            ),
          ),
          reason: 'markdownEnabled=$markdownEnabled',
        );
      }
    },
  );

  test(
    'keeps numeric schedule identifiers outside platform integer limits',
    () {
      final accepted = RichChatScheduleId.parse('18446744073709551616');
      expect(accepted.value, '18446744073709551616');
      expect(
        () => RichChatScheduleId.parse('018446744073709551616'),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => RichChatScheduleId.parse('1' * 41),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test('rejects a user-agent header injection attempt', () {
    expect(
      () => RichChatRequest.mentions(
        accountId: AccountId.parse('account-a'),
        requestId: ChatRequestId.parse('header-injection'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: _token('rooma123'),
        profile: _profile(),
        search: 'user',
        limit: 20,
        includeStatus: false,
        userAgent: 'valid\r\nInjected: value',
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });
}

final class _LookupLimitedParameters
    extends MapBase<String, ChatRichObjectParameter> {
  _LookupLimitedParameters({
    required ChatRichObjectParameter parameter,
    required this.maximumLookups,
  }) : _values = <String, ChatRichObjectParameter>{'a': parameter};

  final Map<String, ChatRichObjectParameter> _values;
  final int maximumLookups;
  int _lookups = 0;

  @override
  ChatRichObjectParameter? operator [](Object? key) {
    _lookups += 1;
    if (_lookups > maximumLookups) {
      throw StateError('Renderer exceeded its semantic-node lookup budget');
    }
    return _values[key];
  }

  @override
  void operator []=(String key, ChatRichObjectParameter value) =>
      throw UnsupportedError('read-only');

  @override
  void clear() => throw UnsupportedError('read-only');

  @override
  Iterable<String> get keys => _values.keys;

  @override
  ChatRichObjectParameter? remove(Object? key) =>
      throw UnsupportedError('read-only');
}

RichChatRequest _mentionsRequest() => RichChatRequest.mentions(
  accountId: AccountId.parse('account-a'),
  requestId: ChatRequestId.parse('security-mentions'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: _token('rooma123'),
  profile: _profile(),
  search: 'user',
  limit: 20,
  includeStatus: false,
);

RichChatRequest _editRequest({String message = 'Edited text'}) =>
    RichChatRequest.editMessage(
      accountId: AccountId.parse('account-a'),
      requestId: ChatRequestId.parse('security-edit'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      roomToken: _token('rooma123'),
      profile: _profile(),
      messageId: 120,
      message: message,
    );

RichChatRequest _recentThreadsRequest() => RichChatRequest.recentThreads(
  accountId: AccountId.parse('account-a'),
  requestId: ChatRequestId.parse('security-recent-threads'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: _token('rooma123'),
  profile: _profile(),
  limit: 20,
);

RichChatRequest _notifyRequest({
  String accountId = 'account-a',
  String requestId = 'security-notify-thread',
  int threadId = 120,
}) => RichChatRequest.setThreadNotificationLevel(
  accountId: AccountId.parse(accountId),
  requestId: ChatRequestId.parse(requestId),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: _token('rooma123'),
  profile: _profile(),
  threadId: threadId,
  level: 3,
);

RichChatRequest _scheduledRequest() => RichChatRequest.getScheduled(
  accountId: AccountId.parse('account-a'),
  requestId: ChatRequestId.parse('security-scheduled'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: _token('rooma123'),
  profile: RichChatCapabilityProfile.fromTalkFeatures(
    talkFeatures: const <Object?>['chat-v2'],
    talkLocalFeatures: const <Object?>['scheduled-messages'],
    federated: false,
    moderator: false,
    participantPermissions: 0,
  ),
);

RichChatCapabilityProfile _profile() =>
    RichChatCapabilityProfile.fromTalkFeatures(
      talkFeatures: <Object?>[
        'chat-v2',
        'threads',
        'reactions',
        'edit-messages',
        'delete-messages',
      ],
      talkLocalFeatures: const <Object?>[],
      federated: false,
      moderator: false,
      participantPermissions: 0,
    );

Map<String, Object?> _message() => <String, Object?>{
  'id': 120,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'user-a',
  'actorDisplayName': 'User A',
  'timestamp': 1787440000,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'root-120',
  'message': 'Original text',
  'messageParameters': <String, Object?>{},
  'markdown': false,
  'reactions': <String, Object?>{},
};

Object? _nestedValue(int depth) {
  Object? value = 'leaf';
  for (var index = 0; index < depth; index++) {
    value = <String, Object?>{'nested': value};
  }
  return value;
}

Uint8List _successBody(Object? data) =>
    _ocsBody(status: 'ok', statusCode: 200, data: data);

Uint8List _ocsBody({
  required String status,
  required int statusCode,
  required Object? data,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': status,
          'statuscode': statusCode,
          'message': 'Result',
        },
        'data': data,
      },
    }),
  ),
);

Map<String, Object?> _fixture(String id) {
  final root = _object(
    jsonDecode(
      File(
        '${_repoRoot().path}/contracts/rich-chat/fixtures/responses.cases.json',
      ).readAsStringSync(),
    ),
  );
  return (root['cases']! as List<Object?>)
      .map(_object)
      .singleWhere((fixture) => fixture['id'] == id);
}

ConversationToken _token(Object? value) => ConversationToken.parse(
  value,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidRichChatRequest,
);

Map<String, Object?> _object(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/rich-chat/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
