import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('rich-chat capability fixtures', () {
    for (final testCase in _cases('capability.cases.json')) {
      final id = testCase['id']! as String;
      test(id, () {
        RichChatCapabilityProfile action() => _profile(testCase);
        if (testCase['expectedError'] == true) {
          expect(action, throwsA(isA<TalkProtocolException>()));
          return;
        }
        final profile = action();
        final expected = _object(testCase['expected']);
        expect(<String, bool>{
          'mentions': profile.mentions,
          'threadMetadata': profile.threadMetadata,
          'threadMessageFetch': profile.threadMessageFetch,
          'reactions': profile.reactions,
          'canReact': profile.canReact,
          'edit': profile.edit,
          'delete': profile.delete,
          'pin': profile.pin,
          'hidePinned': profile.hidePinned,
          'reminders': profile.reminders,
          'scheduled': profile.scheduled,
        }, expected);
      });
    }
  });

  group('rich-chat request fixtures', () {
    for (final testCase in _cases('request.cases.json')) {
      final id = testCase['id']! as String;
      test(id, () {
        final before = jsonEncode(testCase);
        RichChatRequest action() => _requestFromCase(id, testCase);
        if (testCase['expectedError'] == true) {
          expect(action, throwsA(isA<TalkProtocolException>()));
          expect(jsonEncode(testCase), before);
          return;
        }
        final request = action();
        final expected = _object(testCase['expected']);
        expect(request.operation.operationId, expected['operationId']);
        expect(request.method.name.toUpperCase(), expected['method']);
        expect(request.requestPath, expected['path']);
        expect(request.queryParameters, _object(expected['query']));
        expect(request.headers, _object(expected['headers']));
        expect(request.formBody, expected['body']);
        final input = _object(testCase['input']);
        if (input.containsKey('messageId')) {
          expect(request.messageId, input['messageId']);
        }
        if (<Object?>{
          'getThread',
          'renameThread',
          'notifyThread',
        }.contains(testCase['kind'])) {
          expect(request.threadId, input['threadId']);
        }
        if (testCase['kind'] == 'notifyThread') {
          expect(request.messageId, isNull);
        }
        expect(jsonEncode(testCase), before);
      });
    }

    test('builds a subpath-aware URI without logging private query values', () {
      final request = RichChatRequest.mentions(
        accountId: AccountId.parse('account-a'),
        requestId: ChatRequestId.parse('subpath-rich-chat'),
        server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
        roomToken: _token('rooma123'),
        profile: _fullProfile(),
        search: 'private-search',
        limit: 20,
        includeStatus: true,
      );
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/nextcloud'
        '/ocs/v2.php/apps/spreed/api/v1/chat/rooma123/mentions'
        '?format=json&search=private-search&limit=20&includeStatus=1',
      );
      expect(request.toString(), isNot(contains('private-search')));
      expect(request.toString(), isNot(contains('rooma123')));
    });
  });

  group('rich-chat response fixtures', () {
    for (final testCase in _cases('responses.cases.json')) {
      final id = testCase['id']! as String;
      test(id, () {
        final request = _responseRequest(id, testCase);
        final response = decodeRichChatResponse(
          request: request,
          statusCode: testCase['status']! as int,
          body: _body(testCase['body']),
        );
        expect(
          response.classification,
          _classification(testCase['expectedClassification']! as String),
        );
        expect(identical(response.request, request), isTrue);
        expect(response.automaticReplayAllowed, isFalse);
        if (response.classification != RichChatResponseClassification.success) {
          expect(response.mentions, isEmpty);
          expect(response.threads, isEmpty);
          expect(response.scheduledMessages, isEmpty);
          return;
        }
        switch (request.operation) {
          case RichChatOperation.getMentionSuggestions:
            expect(response.mentions, hasLength(2));
          case RichChatOperation.getRecentThreads:
          case RichChatOperation.getSubscribedThreads:
          case RichChatOperation.getThread:
          case RichChatOperation.renameThread:
          case RichChatOperation.setThreadNotificationLevel:
            expect(response.threads, isNotEmpty);
          case RichChatOperation.getMessageReactions:
          case RichChatOperation.addMessageReaction:
          case RichChatOperation.deleteMessageReaction:
            expect(response.reactionAggregate, isNotNull);
          case RichChatOperation.editChatMessage:
          case RichChatOperation.deleteChatMessage:
          case RichChatOperation.pinChatMessage:
          case RichChatOperation.unpinChatMessage:
            expect(response.messageMutation?.parent, isA<ChatFullParent>());
          case RichChatOperation.getChatReminder:
          case RichChatOperation.setChatReminder:
            expect(response.reminder, isNotNull);
          case RichChatOperation.getScheduledChatMessages:
          case RichChatOperation.scheduleChatMessage:
          case RichChatOperation.editScheduledChatMessage:
            expect(response.scheduledMessages, isNotEmpty);
          case RichChatOperation.hidePinnedChatMessage:
          case RichChatOperation.deleteChatReminder:
          case RichChatOperation.deleteScheduledChatMessage:
            expect(response.rawData, anyOf(isNull, isEmpty));
        }
      });
    }
  });

  group('rich-chat render fixtures', () {
    for (final testCase in _cases('render.cases.json')) {
      final id = testCase['id']! as String;
      test(id, () {
        final parameters = <String, ChatRichObjectParameter>{};
        for (final entry in _object(testCase['parameters']).entries) {
          parameters[entry.key] = ChatRichObjectParameter.fromJson(entry.value);
        }
        final document = renderRichChatMessage(
          message: testCase['message']! as String,
          markdownEnabled: testCase['markdown']! as bool,
          parameters: parameters,
          server: ServerBase.parse('https://cloud.example.org'),
        );
        final nodes = document.nodes.toList(growable: false);
        final richObjects = nodes
            .where((node) => node.kind == RichChatSemanticKind.richObject)
            .toList();
        if (testCase.containsKey('expectedRichObjects')) {
          expect(richObjects.length, testCase['expectedRichObjects']);
        }
        if (testCase.containsKey('expectedLiteralKnownPlaceholders')) {
          var literals = 0;
          for (final key in parameters.keys) {
            literals += nodes
                .where((node) => node.kind == RichChatSemanticKind.text)
                .where((node) => node.text!.contains('{$key}'))
                .length;
          }
          expect(literals, testCase['expectedLiteralKnownPlaceholders']);
        }
        if (testCase.containsKey('expectedCodeLiteral')) {
          expect(
            nodes
                .where(
                  (node) =>
                      node.kind == RichChatSemanticKind.inlineCode ||
                      node.kind == RichChatSemanticKind.codeBlock,
                )
                .map((node) => node.text),
            contains(testCase['expectedCodeLiteral']),
          );
        }
        if (testCase.containsKey('expectedText')) {
          expect(document.root.flattenedText, testCase['expectedText']);
        }
        final kinds = nodes.map((node) => node.kind.name).toSet();
        if (testCase.containsKey('expectedElementKinds')) {
          expect(
            kinds,
            containsAll((testCase['expectedElementKinds']! as List<Object?>)),
          );
        }
        if (testCase.containsKey('forbiddenElementKinds')) {
          for (final forbidden
              in testCase['forbiddenElementKinds']! as List<Object?>) {
            expect(kinds, isNot(contains(forbidden)));
          }
        }
        if (testCase.containsKey('expectedActiveLinks')) {
          expect(document.activeLinks, testCase['expectedActiveLinks']);
        }
      });
    }
  });
}

RichChatRequest _requestFromCase(String id, Map<String, Object?> testCase) {
  final input = _object(testCase['input']);
  final profile = _profile(_object(testCase['profile']));
  final common = (
    accountId: AccountId.parse('fixture-account'),
    requestId: ChatRequestId.parse('rich-request-$id'),
    server: ServerBase.parse('https://cloud.example.invalid'),
  );
  ConversationToken room() => _token(input['roomToken']);
  return switch (testCase['kind']) {
    'mentions' => RichChatRequest.mentions(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      search: input['search']! as String,
      limit: input['limit']! as int,
      includeStatus: input['includeStatus']! as bool,
    ),
    'recentThreads' => RichChatRequest.recentThreads(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      limit: input['limit']! as int,
    ),
    'subscribedThreads' => RichChatRequest.subscribedThreads(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      profile: profile,
      limit: input['limit']! as int,
      offset: input['offset']! as int,
    ),
    'getThread' => RichChatRequest.getThread(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      threadId: input['threadId']! as int,
    ),
    'renameThread' => RichChatRequest.renameThread(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      threadId: input['threadId']! as int,
      threadTitle: input['threadTitle']! as String,
    ),
    'notifyThread' => RichChatRequest.setThreadNotificationLevel(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      threadId: input['threadId']! as int,
      level: input['level']! as int,
    ),
    'getReactions' => RichChatRequest.getReactions(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
      reaction: input['reaction']! as String,
      actor: _actor(),
    ),
    'addReaction' => RichChatRequest.addReaction(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
      reaction: input['reaction']! as String,
      actor: _actor(),
    ),
    'deleteReaction' => RichChatRequest.deleteReaction(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
      reaction: input['reaction']! as String,
      actor: _actor(),
    ),
    'editMessage' => RichChatRequest.editMessage(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
      message: input['message']! as String,
    ),
    'deleteMessage' => RichChatRequest.deleteMessage(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
    ),
    'pinMessage' => RichChatRequest.pinMessage(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
      pinUntil: input['pinUntil']! as int,
      now: input['now']! as int,
    ),
    'unpinMessage' => RichChatRequest.unpinMessage(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
    ),
    'hidePinnedMessage' => RichChatRequest.hidePinnedMessage(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
    ),
    'getReminder' => RichChatRequest.getReminder(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
    ),
    'setReminder' => RichChatRequest.setReminder(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
      timestamp: input['timestamp']! as int,
    ),
    'deleteReminder' => RichChatRequest.deleteReminder(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      messageId: input['messageId']! as int,
    ),
    'getScheduled' => RichChatRequest.getScheduled(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
    ),
    'createScheduled' => RichChatRequest.createScheduled(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      message: input['message']! as String,
      sendAt: input['sendAt']! as int,
      silent: input['silent']! as bool,
      threadId: input['threadId']! as int,
      threadTitle: input['threadTitle']! as String,
      now: input['now']! as int,
    ),
    'editScheduled' => RichChatRequest.editScheduled(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      scheduleId: RichChatScheduleId.parse(input['scheduleId']),
      message: input['message']! as String,
      sendAt: input['sendAt']! as int,
      silent: input['silent']! as bool,
      threadTitle: input['threadTitle']! as String,
      now: input['now']! as int,
    ),
    'deleteScheduled' => RichChatRequest.deleteScheduled(
      accountId: common.accountId,
      requestId: common.requestId,
      server: common.server,
      roomToken: room(),
      profile: profile,
      scheduleId: RichChatScheduleId.parse(input['scheduleId']),
    ),
    _ => throw StateError('Unknown rich-chat request fixture'),
  };
}

RichChatRequest _responseRequest(String id, Map<String, Object?> testCase) {
  final operation = RichChatOperation.values.singleWhere(
    (value) => value.operationId == testCase['operationId'],
  );
  final context = _object(testCase['context']);
  final accountId = AccountId.parse('account-a');
  final requestId = ChatRequestId.parse('response-$id');
  final server = ServerBase.parse('https://cloud.example.invalid');
  final room = context['roomToken'] == null
      ? null
      : _token(context['roomToken']);
  final messageId = context['messageId'] as int? ?? 120;
  return switch (operation) {
    RichChatOperation.getMentionSuggestions => RichChatRequest.mentions(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      search: 'user',
      limit: 20,
      includeStatus: true,
    ),
    RichChatOperation.getRecentThreads => RichChatRequest.recentThreads(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      limit: 50,
    ),
    RichChatOperation.getSubscribedThreads => RichChatRequest.subscribedThreads(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: _fullProfile(),
      limit: 100,
      offset: 0,
    ),
    RichChatOperation.getThread => RichChatRequest.getThread(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      threadId: context['threadId']! as int,
    ),
    RichChatOperation.renameThread => RichChatRequest.renameThread(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      threadId: context['threadId']! as int,
      threadTitle: 'Updated design',
    ),
    RichChatOperation.setThreadNotificationLevel =>
      RichChatRequest.setThreadNotificationLevel(
        accountId: accountId,
        requestId: requestId,
        server: server,
        roomToken: room!,
        profile: _fullProfile(),
        threadId: context['threadId']! as int,
        level: 3,
      ),
    RichChatOperation.getMessageReactions => RichChatRequest.getReactions(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
      reaction: '👍',
      actor: _actor(),
    ),
    RichChatOperation.addMessageReaction => RichChatRequest.addReaction(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
      reaction: '👍',
      actor: _actor(),
    ),
    RichChatOperation.deleteMessageReaction => RichChatRequest.deleteReaction(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
      reaction: '👍',
      actor: _actor(),
    ),
    RichChatOperation.editChatMessage => RichChatRequest.editMessage(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
      message: 'Edited text',
    ),
    RichChatOperation.deleteChatMessage => RichChatRequest.deleteMessage(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
    ),
    RichChatOperation.pinChatMessage => RichChatRequest.pinMessage(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
      pinUntil: 1787529600,
      now: 1787440000,
    ),
    RichChatOperation.unpinChatMessage => RichChatRequest.unpinMessage(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
    ),
    RichChatOperation.hidePinnedChatMessage =>
      RichChatRequest.hidePinnedMessage(
        accountId: accountId,
        requestId: requestId,
        server: server,
        roomToken: room!,
        profile: _fullProfile(),
        messageId: messageId,
      ),
    RichChatOperation.getChatReminder => RichChatRequest.getReminder(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
    ),
    RichChatOperation.setChatReminder => RichChatRequest.setReminder(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
      timestamp: 1787529600,
    ),
    RichChatOperation.deleteChatReminder => RichChatRequest.deleteReminder(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      messageId: messageId,
    ),
    RichChatOperation.getScheduledChatMessages => RichChatRequest.getScheduled(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
    ),
    RichChatOperation.scheduleChatMessage => RichChatRequest.createScheduled(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      message: 'Later',
      sendAt: 1787529600,
      silent: false,
      threadId: 0,
      threadTitle: '',
      now: 1787440000,
    ),
    RichChatOperation.editScheduledChatMessage => RichChatRequest.editScheduled(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: room!,
      profile: _fullProfile(),
      scheduleId: RichChatScheduleId.parse(context['scheduleId']),
      message: 'Updated later',
      sendAt: 1787533200,
      silent: true,
      threadTitle: '',
      now: 1787440000,
    ),
    RichChatOperation.deleteScheduledChatMessage =>
      RichChatRequest.deleteScheduled(
        accountId: accountId,
        requestId: requestId,
        server: server,
        roomToken: room!,
        profile: _fullProfile(),
        scheduleId: RichChatScheduleId.parse(context['scheduleId']),
      ),
  };
}

RichChatCapabilityProfile _profile(Map<String, Object?> source) =>
    RichChatCapabilityProfile.fromTalkFeatures(
      talkFeatures: source['talkFeatures'],
      talkLocalFeatures: source['talkLocalFeatures'],
      federated: source['federated']! as bool,
      moderator: source['moderator']! as bool,
      participantPermissions: source['participantPermissions']! as int,
    );

RichChatCapabilityProfile _fullProfile() =>
    RichChatCapabilityProfile.fromTalkFeatures(
      talkFeatures: <Object?>[
        'chat-v2',
        'threads',
        'reactions',
        'react-permission',
        'edit-messages',
        'delete-messages',
        'pinned-messages',
        'remind-me-later',
      ],
      talkLocalFeatures: <Object?>['scheduled-messages'],
      federated: false,
      moderator: true,
      participantPermissions: 256,
    );

RichChatActorIdentity _actor() =>
    RichChatActorIdentity(actorType: 'users', actorId: 'user-a');

RichChatResponseClassification _classification(String value) => switch (value) {
  'success' => RichChatResponseClassification.success,
  'reauth' => RichChatResponseClassification.reauthenticationRequired,
  'deterministic-failure' =>
    RichChatResponseClassification.deterministicFailure,
  'ambiguous' => RichChatResponseClassification.ambiguous,
  'server-error' => RichChatResponseClassification.serverError,
  _ => throw StateError('Unknown rich-chat classification'),
};

List<Map<String, Object?>> _cases(String filename) {
  final root = _readJsonObject('contracts/rich-chat/fixtures/$filename');
  return (root['cases']! as List<Object?>).map(_object).toList(growable: false);
}

Uint8List _body(Object? body) =>
    Uint8List.fromList(utf8.encode(jsonEncode(body)));

ConversationToken _token(Object? value) => ConversationToken.parse(
  value,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidRichChatRequest,
);

Map<String, Object?> _readJsonObject(String relativePath) => _object(
  jsonDecode(File('${_repoRoot().path}/$relativePath').readAsStringSync()),
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
