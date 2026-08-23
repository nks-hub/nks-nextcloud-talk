import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final responseFixtures = <String, Map<String, Object?>>{
    for (final fixture in _cases('responses.cases.json'))
      fixture['id']! as String: fixture,
  };

  group('rich-chat state fixtures', () {
    for (final testCase in _cases('state.cases.json')) {
      final id = testCase['id']! as String;
      test(id, () {
        var state = _snapshot();
        final fixture = responseFixtures[testCase['responseFixture']]!;
        final response = _responseForState(testCase, fixture);

        if (testCase['expectedRejected'] == true) {
          final targetAccountId = AccountId.parse(
            testCase['accountId']! as String,
          );
          final projected = RichChatRuntimeSnapshot(
            chat: state.chat,
            accounts: <AccountId, RichChatAccountState>{
              targetAccountId: state.accounts[targetAccountId]!,
            },
          );
          final result = planRichChatMerge(projected, response);
          expect(result.outcome, RichChatMergeOutcome.rejected);
          expect(result.plan, isNull);
          return;
        }

        final repeat = testCase['repeat'] as int? ?? 1;
        for (var index = 0; index < repeat; index++) {
          final result = planRichChatMerge(state, response);
          if (response.classification ==
              RichChatResponseClassification.ambiguous) {
            expect(result.outcome, RichChatMergeOutcome.unchanged);
            expect(result.plan, isNull);
            expect(response.automaticReplayAllowed, isFalse);
            continue;
          }
          expect(result.outcome, RichChatMergeOutcome.applied);
          state = result.plan!.complete(
            state,
            persisted: testCase['transaction'] == 'commit',
          );
        }
        expect(_summary(state, testCase), _object(testCase['expected']));
      });
    }
  });

  test('response context cannot mutate another account lane', () {
    final fixture = responseFixtures['edit-message-success']!;
    final testCase = <String, Object?>{
      'accountId': 'account-a',
      'roomToken': 'rooma123',
      'messageId': 120,
    };
    final response = _responseForState(testCase, fixture);
    final source = _snapshot();
    final otherBefore = source.accounts[AccountId.parse('account-b')]!;
    final committed = planRichChatMerge(source, response).plan!.commit(source);

    expect(
      committed
          .accounts[AccountId.parse('account-a')]!
          .rooms[_token('rooma123')]!
          .messages[120]!
          .message,
      'Edited **text**',
    );
    expect(
      identical(committed.accounts[AccountId.parse('account-b')], otherBefore),
      isTrue,
    );
  });

  test('reauthentication pauses only the request account', () {
    final fixture = responseFixtures['edit-unauthorized']!;
    final response = _responseForState(<String, Object?>{
      'accountId': 'account-a',
      'roomToken': 'rooma123',
      'messageId': 120,
    }, fixture);
    final source = _snapshot();
    final result = planRichChatMerge(source, response);
    expect(result.outcome, RichChatMergeOutcome.reauthenticationRequired);
    final committed = result.plan!.commit(source);
    expect(
      committed.chat.accounts[AccountId.parse('account-a')]!.lane,
      ChatAccountLane.reauthenticationRequired,
    );
    expect(
      committed.chat.accounts[AccountId.parse('account-b')]!.lane,
      ChatAccountLane.ready,
    );
  });

  test('state plan rejects stale and repeated application', () {
    final fixture = responseFixtures['edit-message-success']!;
    final response = _responseForState(<String, Object?>{
      'accountId': 'account-a',
      'roomToken': 'rooma123',
      'messageId': 120,
    }, fixture);
    final source = _snapshot();
    final stalePlan = planRichChatMerge(source, response).plan!;
    expect(
      () => stalePlan.commit(_snapshot()),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.code,
          'code',
          TalkProtocolErrorCode.invalidRichChatMerge,
        ),
      ),
    );

    final singleUse = planRichChatMerge(source, response).plan!;
    singleUse.commit(source);
    expect(
      () => singleUse.commit(source),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('cross-origin response is rejected before a state plan exists', () {
    final fixture = responseFixtures['edit-message-success']!;
    final response = _decodeFixture(
      fixture,
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse('https://other.example.invalid'),
    );
    final result = planRichChatMerge(_snapshot(), response);
    expect(result.outcome, RichChatMergeOutcome.rejected);
    expect(result.plan, isNull);
  });

  test('message changes update every embedded reply parent atomically', () {
    for (final fixtureId in <String>[
      'addMessageReaction',
      'edit-message-success',
      'delete-message-accepted',
    ]) {
      final fixture = fixtureId == 'addMessageReaction'
          ? responseFixtures['reaction-created']!
          : responseFixtures[fixtureId]!;
      final source = _snapshot(includeReply: true);
      final response = _decodeFixture(
        fixture,
        accountId: AccountId.parse('account-a'),
        server: _server(AccountId.parse('account-a')),
      );
      final committed = planRichChatMerge(
        source,
        response,
      ).plan!.commit(source);
      final room = committed
          .accounts[AccountId.parse('account-a')]!
          .rooms[_token('rooma123')]!;
      final root = room.messages[120]!;
      final reply = room.messages[121]!;
      final parent = reply.parent! as ChatFullParent;
      final threadParent =
          room.threads[120]!.lastMessage!.parent! as ChatFullParent;
      final previewParent = room.lastMessage!.parent! as ChatFullParent;
      final scheduled = room.scheduledMessages.values.single;
      final scheduledParent = scheduled.parent!;

      for (final embedded in <ChatMessage>[
        parent.message,
        threadParent.message,
        previewParent.message,
        scheduledParent,
      ]) {
        expect(embedded.message, root.message, reason: fixtureId);
        expect(embedded.deleted, root.deleted, reason: fixtureId);
        expect(embedded.reactions, root.reactions, reason: fixtureId);
        expect(identical(embedded, root), isTrue, reason: fixtureId);
      }
      final reparsed = ChatMessage.fromJson(reply.wire);
      final wireParent = reparsed.parent! as ChatFullParent;
      expect(wireParent.message.message, root.message, reason: fixtureId);
      expect(wireParent.message.deleted, root.deleted, reason: fixtureId);
      expect(wireParent.message.reactions, root.reactions, reason: fixtureId);
      final reparsedScheduled = RichChatScheduledMessage.fromJson(
        scheduled.wire,
        roomToken: room.roomToken,
      );
      expect(
        reparsedScheduled.parent!.message,
        root.message,
        reason: fixtureId,
      );
      expect(
        reparsedScheduled.parent!.deleted,
        root.deleted,
        reason: fixtureId,
      );
      expect(
        reparsedScheduled.parent!.reactions,
        root.reactions,
        reason: fixtureId,
      );
      final otherParent = committed
          .accounts[AccountId.parse('account-b')]!
          .rooms[_token('rooma123')]!
          .scheduledMessages
          .values
          .single
          .parent!;
      expect(otherParent.message, 'Original text', reason: fixtureId);
      expect(otherParent.deleted, isFalse, reason: fixtureId);
      expect(otherParent.reactions, isEmpty, reason: fixtureId);
    }
  });

  test(
    'threads, reminders, pins and schedules complete their state lifecycle',
    () {
      var state = _snapshot();

      state = _commitFixture(
        state,
        responseFixtures['recent-threads-success']!,
      );
      var room = state
          .accounts[AccountId.parse('account-a')]!
          .rooms[_token('rooma123')]!;
      expect(room.threads[120]!.lastMessageId, 122);
      expect(room.threads[120]!.firstMessage?.messageId, 120);
      expect(room.threads[120]!.lastMessage, isNull);

      state = _commitFixture(state, responseFixtures['thread-rename-success']!);
      room = state
          .accounts[AccountId.parse('account-a')]!
          .rooms[_token('rooma123')]!;
      expect(room.threads[120]!.title, 'Updated design');
      expect(room.threads[120]!.firstMessage?.messageId, 120);

      state = _commitFixture(state, responseFixtures['pin-message-success']!);
      room = state
          .accounts[AccountId.parse('account-a')]!
          .rooms[_token('rooma123')]!;
      expect(room.messages[120]!.metadata['pinnedAt'], 1787443500);
      expect(room.lastMessage?.metadata['pinnedAt'], 1787443500);

      state = _commitFixture(state, responseFixtures['reminder-created']!);
      expect(
        state
            .accounts[AccountId.parse('account-a')]!
            .rooms[_token('rooma123')]!
            .reminders[120]
            ?.timestamp,
        1787529600,
      );
      state = _commitFixture(state, responseFixtures['reminder-deleted']!);
      expect(
        state
            .accounts[AccountId.parse('account-a')]!
            .rooms[_token('rooma123')]!
            .reminders,
        isEmpty,
      );

      state = _commitFixture(state, responseFixtures['schedule-list-success']!);
      state = _commitFixture(state, responseFixtures['schedule-edited']!);
      room = state
          .accounts[AccountId.parse('account-a')]!
          .rooms[_token('rooma123')]!;
      expect(room.scheduledMessages.values.single.message, 'Updated later');
      state = _commitFixture(state, responseFixtures['schedule-deleted']!);
      expect(
        state
            .accounts[AccountId.parse('account-a')]!
            .rooms[_token('rooma123')]!
            .scheduledMessages,
        isEmpty,
      );
    },
  );
}

RichChatRuntimeSnapshot _commitFixture(
  RichChatRuntimeSnapshot state,
  Map<String, Object?> fixture,
) {
  final response = _decodeFixture(
    fixture,
    accountId: AccountId.parse('account-a'),
    server: _server(AccountId.parse('account-a')),
  );
  final result = planRichChatMerge(state, response);
  expect(result.outcome, RichChatMergeOutcome.applied);
  return result.plan!.commit(state);
}

RichChatResponse _responseForState(
  Map<String, Object?> testCase,
  Map<String, Object?> fixture,
) {
  final requestAccount = AccountId.parse(
    testCase['requestAccountId'] as String? ?? testCase['accountId']! as String,
  );
  return _decodeFixture(
    fixture,
    accountId: requestAccount,
    server: _server(requestAccount),
  );
}

RichChatResponse _decodeFixture(
  Map<String, Object?> fixture, {
  required AccountId accountId,
  required ServerBase server,
}) {
  final context = _object(fixture['context']);
  final operation = RichChatOperation.values.singleWhere(
    (value) => value.operationId == fixture['operationId'],
  );
  final roomToken = _token(context['roomToken'] ?? 'rooma123');
  final requestId = ChatRequestId.parse(
    'state-${fixture['id']}-${accountId.value}',
  );
  final messageId = context['messageId'] as int? ?? 120;
  final request = switch (operation) {
    RichChatOperation.getRecentThreads => RichChatRequest.recentThreads(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      limit: 50,
    ),
    RichChatOperation.renameThread => RichChatRequest.renameThread(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      threadId: context['threadId']! as int,
      threadTitle: 'Updated design',
    ),
    RichChatOperation.addMessageReaction => RichChatRequest.addReaction(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      messageId: messageId,
      reaction: '👍',
      actor: RichChatActorIdentity(actorType: 'users', actorId: 'user-a'),
    ),
    RichChatOperation.editChatMessage => RichChatRequest.editMessage(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      messageId: messageId,
      message: 'Edited text',
    ),
    RichChatOperation.deleteChatMessage => RichChatRequest.deleteMessage(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      messageId: messageId,
    ),
    RichChatOperation.pinChatMessage => RichChatRequest.pinMessage(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      messageId: messageId,
      pinUntil: 1787529600,
      now: 1787440000,
    ),
    RichChatOperation.getChatReminder => RichChatRequest.getReminder(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      messageId: messageId,
    ),
    RichChatOperation.setChatReminder => RichChatRequest.setReminder(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      messageId: messageId,
      timestamp: 1787529600,
    ),
    RichChatOperation.deleteChatReminder => RichChatRequest.deleteReminder(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
      messageId: messageId,
    ),
    RichChatOperation.getScheduledChatMessages => RichChatRequest.getScheduled(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: _fullProfile(),
    ),
    RichChatOperation.scheduleChatMessage => RichChatRequest.createScheduled(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
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
      roomToken: roomToken,
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
        roomToken: roomToken,
        profile: _fullProfile(),
        scheduleId: RichChatScheduleId.parse(context['scheduleId']),
      ),
    _ => throw StateError('Unsupported state response operation'),
  };
  return decodeRichChatResponse(
    request: request,
    statusCode: fixture['status']! as int,
    body: _body(fixture['body']),
  );
}

RichChatRuntimeSnapshot _snapshot({bool includeReply = false}) {
  final accountA = AccountId.parse('account-a');
  final accountB = AccountId.parse('account-b');
  final accounts = <AccountId>[accountA, accountB];
  final roomToken = _token('rooma123');
  final message = ChatMessage.fromJson(_initialMessage());
  final reply = ChatMessage.fromJson(_replyMessage());
  final scheduledReply = RichChatScheduledMessage.fromJson(<String, Object?>{
    'id': '18446744073709551616',
    'actorId': 'user-a',
    'actorType': 'users',
    'threadId': 120,
    'threadTitle': 'Design',
    'parent': _initialMessage(),
    'message': 'Later reply',
    'messageType': 'comment',
    'createdAt': 1787443600,
    'sendAt': 1787529600,
    'silent': false,
  }, roomToken: roomToken);
  final thread = RichChatThread.fromJson(<String, Object?>{
    'thread': <String, Object?>{
      'id': 120,
      'roomToken': 'rooma123',
      'title': 'Design',
      'lastMessageId': includeReply ? 121 : 120,
      'lastActivity': 1787440000,
      'numReplies': includeReply ? 1 : 0,
    },
    'attendee': <String, Object?>{'notificationLevel': 1},
    'first': _initialMessage(),
    'last': includeReply ? _replyMessage() : _initialMessage(),
  });
  final chatAccounts = <AccountId, ChatAccountState>{};
  final richAccounts = <AccountId, RichChatAccountState>{};
  for (final accountId in accounts) {
    final server = _server(accountId);
    chatAccounts[accountId] = ChatAccountState(
      accountId: accountId,
      server: server,
      lane: ChatAccountLane.ready,
      credentialGeneration: 1,
      capabilityGeneration: 1,
      scopes: const {},
      operations: const {},
    );
    final room = RichChatRoomState(
      roomToken: roomToken,
      messages: <int, ChatMessage>{120: message, if (includeReply) 121: reply},
      threads: <int, RichChatThread>{120: thread},
      reminders: const {},
      scheduledMessages: <RichChatScheduleId, RichChatScheduledMessage>{
        if (includeReply) scheduledReply.scheduleId: scheduledReply,
      },
      lastMessageId: includeReply ? 121 : 120,
    );
    richAccounts[accountId] = RichChatAccountState(
      accountId: accountId,
      server: server,
      rooms: <ConversationToken, RichChatRoomState>{roomToken: room},
    );
  }
  return RichChatRuntimeSnapshot(
    chat: ChatRuntimeSnapshot(accounts: chatAccounts),
    accounts: richAccounts,
  );
}

Map<String, Object?> _summary(
  RichChatRuntimeSnapshot state,
  Map<String, Object?> testCase,
) {
  final accountId = AccountId.parse(testCase['accountId']! as String);
  final room = state.accounts[accountId]!.rooms[_token('rooma123')]!;
  return switch (testCase['kind']) {
    'reaction' => <String, Object?>{
      'reactionCounts': room.messages[120]!.reactions,
      'reactionsSelf': room.messages[120]!.reactionsSelf,
    },
    'messageMutation' => <String, Object?>{
      'message': room.messages[120]!.message,
      'threadFirstMessage': room.threads[120]!.firstMessage!.message,
      'roomPreviewMessage': room.lastMessage!.message,
      'deleted': room.messages[120]!.deleted,
    },
    'reminder' => <String, Object?>{
      'targetReminderTimestamp': room.reminders[120]?.timestamp,
      'otherAccountReminderTimestamp': state
          .accounts[AccountId.parse(
            accountId.value == 'account-a' ? 'account-b' : 'account-a',
          )]!
          .rooms[_token('rooma123')]!
          .reminders[120]
          ?.timestamp,
    },
    'schedule' => <String, Object?>{
      'scheduleIds':
          room.scheduledMessages.keys
              .map((id) => id.value)
              .toList(growable: false)
            ..sort(),
      'automaticReplay': false,
    },
    _ => throw StateError('Unknown state summary kind'),
  };
}

Map<String, Object?> _initialMessage() => <String, Object?>{
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
  'reactionsSelf': <Object?>[],
  'deleted': null,
  'threadId': 120,
  'isThread': true,
  'threadTitle': 'Design',
  'threadReplies': 0,
};

Map<String, Object?> _replyMessage() => <String, Object?>{
  ..._initialMessage(),
  'id': 121,
  'referenceId': 'reply-121',
  'message': 'Reply text',
  'isThread': false,
  'parent': _initialMessage(),
};

ServerBase _server(AccountId accountId) => ServerBase.parse(
  accountId.value == 'account-a'
      ? 'https://a.example.invalid'
      : 'https://b.example.invalid',
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

List<Map<String, Object?>> _cases(String filename) {
  final root = _object(
    jsonDecode(
      File(
        '${_repoRoot().path}/contracts/rich-chat/fixtures/$filename',
      ).readAsStringSync(),
    ),
  );
  return (root['cases']! as List<Object?>).map(_object).toList(growable: false);
}

Uint8List _body(Object? body) =>
    Uint8List.fromList(utf8.encode(jsonEncode(body)));

ConversationToken _token(Object? value) => ConversationToken.parse(
  value,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidRichChatState,
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
