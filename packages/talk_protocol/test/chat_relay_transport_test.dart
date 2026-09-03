import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/signaling_test_support.dart';

/// The HPB chat relay is the second inlet of the chat sync engine. These
/// tests pin the two properties that make it safe to have two: a relayed
/// message reaches the database through the same `planChatGetMerge` the long
/// poll uses, and a transport handover neither loses nor duplicates a
/// message.
///
/// The wire shape is the one three upstream sources agree on: the Talk
/// server's `Listener::notifyMessageSent`, talk-android's
/// `processChatMessageWebSocketMessage` and talk-ios' `processRoomMessage
/// Event` — `event.message.data.chat.comment`, `.comments` or a bare
/// `.refresh`.
void main() {
  group('relay frame parsing', () {
    test('carries the chat payload and the room it belongs to', () {
      final frame =
          HpbServerFrame.decode(_relayFrame(roomToken: 'rooma123', ids: [110]))
              as HpbEventServerFrame;
      expect(frame.target, 'room');
      expect(frame.eventType, 'message');
      expect(frame.roomToken, _room);
      expect(frame.chatRelay, isNotNull);

      final event = decodeChatRelayEvent(frame.chatRelay!, roomToken: _room);
      expect(event.refreshRequested, isFalse);
      expect(event.comments.single.messageId, 110);
    });

    test('accepts the batched comments array', () {
      final frame =
          HpbServerFrame.decode(
                _relayFrame(roomToken: 'rooma123', ids: [112, 110, 111]),
              )
              as HpbEventServerFrame;
      final event = decodeChatRelayEvent(frame.chatRelay!, roomToken: _room);
      expect(event.comments.map((comment) => comment.messageId), <int>[
        110,
        111,
        112,
      ]);
    });

    test('a refresh without a comment asks for a fetch, not a merge', () {
      final frame =
          HpbServerFrame.decode(
                _relayFrame(roomToken: 'rooma123', ids: const <int>[]),
              )
              as HpbEventServerFrame;
      final event = decodeChatRelayEvent(frame.chatRelay!, roomToken: _room);
      expect(event.refreshRequested, isTrue);
      expect(event.comments, isEmpty);
    });

    test('a room message that is not chat carries no relay payload', () {
      final frame =
          HpbServerFrame.decode(
                '{"type":"event","event":{"target":"room","type":"message",'
                '"message":{"roomid":"rooma123",'
                '"data":{"type":"recording","recording":{"status":1}}}}}',
              )
              as HpbEventServerFrame;
      expect(frame.chatRelay, isNull);
    });

    test('a comment from another room is refused, not silently dropped', () {
      final frame =
          HpbServerFrame.decode(_relayFrame(roomToken: 'roomb999', ids: [110]))
              as HpbEventServerFrame;
      expect(frame.roomToken, isNot(_room));
      expect(
        () => decodeChatRelayEvent(frame.chatRelay!, roomToken: _room),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('a frame measured on a live High Performance Backend', () {
    // Captured on 2026-09-03 from a standalone-signaling 2.1.0 backend that
    // answered the `chat-relay` feature: a message posted over OCS arrived on
    // the signalling socket in this exact shape. Kept verbatim (only the text
    // replaced) so a parser change that would break the real wire fails here.
    const live =
        '{"type":"event","event":{"target":"room","type":"message","messa'
        'ge":{"roomid":"<room-token>","data":{"type":"chat","chat":{"comment"'
        ':{"id":78949,"token":"<room-token>","actorType":"users","actorId":"n'
        'ctalk-test2","actorDisplayName":"NCloudTalk Test 2","timestamp":'
        '1788468853,"message":"relay probe","messageParameters":[],"syste'
        'mMessage":"","messageType":"comment","isReplyable":true,"referen'
        'ceId":"relayprobe1","reactions":{},"expirationTimestamp":0,"mark'
        'down":true,"threadId":78949,"lastCommonRead":78931}}}}}}';

    test('parses into one relayed comment', () {
      final frame = HpbServerFrame.decode(live) as HpbEventServerFrame;
      expect(frame.roomToken!.value, '<room-token>');
      final event = decodeChatRelayEvent(
        frame.chatRelay!,
        roomToken: frame.roomToken!,
      );
      final comment = event.comments.single;
      expect(comment.messageId, 78949);
      expect(comment.actorId, 'fixture-user2');
      expect(comment.referenceId, 'relayprobe1');
      // The server sends an empty `messageParameters` as a JSON array, not an
      // object — PHP's json_encode of an empty map.
      expect(comment.messageParameters, isEmpty);
      // A single `comment`, not the `comments` array: this backend speaks the
      // older shape, so both have to keep working.
      expect(event.refreshRequested, isFalse);
    });
  });

  group('relay runtime admission', () {
    test('a confirmed room hands the payload out transiently', () {
      final runtime = externalReadySignalingSnapshot();
      final result = _relayInto(runtime, roomToken: 'rooma123');
      expect(result.outcome, SignalingRuntimeOutcome.chatRelayReceived);
      expect(result.chatRelay, isNotNull);
      // Nothing about chat is kept in the signaling snapshot.
      expect(identical(commitSignaling(runtime, result), runtime), isTrue);
    });

    test('a relay event for another room is rejected', () {
      final runtime = externalReadySignalingSnapshot();
      final result = _relayInto(runtime, roomToken: 'roomb999');
      expect(result.outcome, SignalingRuntimeOutcome.rejected);
      expect(result.chatRelay, isNull);
      expect(result.canCommit, isFalse);
    });
  });

  group('relay merge input', () {
    test('extends the scope exactly like a future poll would', () {
      final snapshot = _chatSnapshot();
      final request = _futureRequest('109');
      final response = chatRelayGetResponse(
        request: request,
        comments: <ChatMessage>[_message(110), _message(111)],
      )!;
      expect(response.classification, ChatGetClassification.messages);
      expect(response.cursor!.value, '111');

      final merge = planChatGetMerge(snapshot, response);
      expect(merge.outcome, ChatMergeOutcome.applied);
      final scope = merge.plan!
          .commit(snapshot)
          .accounts[_account]!
          .scopes[ChatScopeKey(roomToken: _room, threadId: null)]!;
      expect(scope.futureCursor.value, '111');
      expect(scope.messageIds, <int>[109, 110, 111]);
      expect(scope.blocks, hasLength(1));
      expect(scope.blocks.single.end.value, '111');
    });

    test('a message the scope already merged is dropped by its id', () {
      expect(
        chatRelayGetResponse(
          request: _futureRequest('109'),
          comments: <ChatMessage>[_message(109)],
        ),
        isNull,
      );
    });

    test('a relayed duplicate of a message this client sent merges once', () {
      // Same referenceId, one server id: `referenceId` correlates, the
      // message id deduplicates.
      var snapshot = _chatSnapshot();
      final first = chatRelayGetResponse(
        request: _futureRequest('109'),
        comments: <ChatMessage>[_message(110, referenceId: 'ref-a')],
      )!;
      snapshot = planChatGetMerge(snapshot, first).plan!.commit(snapshot);
      final second = chatRelayGetResponse(
        request: _futureRequest('110'),
        comments: <ChatMessage>[_message(110, referenceId: 'ref-a')],
      );
      expect(second, isNull);
      final scope = snapshot
          .accounts[_account]!
          .scopes[ChatScopeKey(roomToken: _room, threadId: null)]!;
      expect(scope.messageIds.where((id) => id == 110), hasLength(1));
    });

    test('a stale anchor is discarded instead of reopening a closed block', () {
      var snapshot = _chatSnapshot();
      final ahead = chatRelayGetResponse(
        request: _futureRequest('109'),
        comments: <ChatMessage>[_message(110)],
      )!;
      snapshot = planChatGetMerge(snapshot, ahead).plan!.commit(snapshot);
      // A second relay frame built against the now-outdated anchor.
      final late = chatRelayGetResponse(
        request: _futureRequest('109'),
        comments: <ChatMessage>[_message(111)],
      )!;
      final merge = planChatGetMerge(snapshot, late);
      expect(merge.outcome, ChatMergeOutcome.stale);
      expect(merge.canCommit, isFalse);
    });
  });

  group('transport handover', () {
    test('long poll to relay to long poll loses and duplicates nothing', () {
      var snapshot = _chatSnapshot();
      final seen = <int>[];

      void mergeThrough(ChatGetResponse response) {
        final result = planChatGetMerge(snapshot, response);
        expect(result.outcome, ChatMergeOutcome.applied);
        seen.addAll(result.plan!.messageUpserts.map((m) => m.messageId));
        snapshot = result.plan!.commit(snapshot);
      }

      String cursor() => snapshot
          .accounts[_account]!
          .scopes[ChatScopeKey(roomToken: _room, threadId: null)]!
          .futureCursor
          .value;

      // 1. Long poll delivers 110.
      mergeThrough(_pollResponse(cursor(), <int>[110]));

      // 2. Relay takes over and delivers 111 and 112.
      mergeThrough(
        chatRelayGetResponse(
          request: _futureRequest(cursor()),
          comments: <ChatMessage>[_message(111), _message(112)],
        )!,
      );

      // 3. The relay drops. 113 was created while nothing was listening, and
      //    114 arrives after. The long poll resumes from the confirmed
      //    anchor, so the gap is closed by the fetch, not by the relay.
      mergeThrough(_pollResponse(cursor(), <int>[113, 114]));

      // 4. The relay comes back and repeats what it already delivered.
      expect(
        chatRelayGetResponse(
          request: _futureRequest(cursor()),
          comments: <ChatMessage>[_message(113), _message(114)],
        ),
        isNull,
      );

      expect(seen, <int>[110, 111, 112, 113, 114]);
      final scope = snapshot
          .accounts[_account]!
          .scopes[ChatScopeKey(roomToken: _room, threadId: null)]!;
      expect(scope.messageIds, <int>[109, 110, 111, 112, 113, 114]);
      // One block: no transport left a hole behind.
      expect(scope.blocks, hasLength(1));
      expect(scope.blocks.single.end.value, '114');
    });
  });
}

final _account = AccountId.parse('relay-account');
final _server = ServerBase.parse('https://relay.example.invalid');
final _room = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidChatState,
);

ChatCapabilityProfile _chatProfile() => ChatCapabilityProfile.fromTalkFeatures(
  <Object?>['chat-v2'],
  federated: false,
);

ChatFetchRequest _futureRequest(String cursor) => ChatFetchRequest(
  accountId: _account,
  requestId: ChatRequestId.parse('relay-$cursor'),
  server: _server,
  roomToken: _room,
  profile: _chatProfile(),
  direction: ChatFetchDirection.future,
  cursor: ChatCursor.parse(cursor),
  lastCommonRead: ChatCursor.parse('100'),
  limit: 100,
  includeLastKnown: false,
  timeoutSeconds: 0,
  interactive: true,
  threadId: null,
  futureConverged: true,
);

/// The same response the long poll produces, built without the HTTP layer so
/// both transports can be interleaved in one test.
ChatGetResponse _pollResponse(String anchor, List<int> ids) =>
    chatRelayGetResponse(
      request: _futureRequest(anchor),
      comments: ids.map(_message).toList(growable: false),
    )!;

ChatMessage _message(int id, {String? referenceId}) =>
    ChatMessage.fromJson(<String, Object?>{
      'id': id,
      'token': 'rooma123',
      'actorType': 'users',
      'actorId': 'someone',
      'actorDisplayName': 'Someone',
      'timestamp': 1700000000 + id,
      'systemMessage': '',
      'messageType': 'comment',
      'isReplyable': true,
      'referenceId': referenceId ?? '',
      'message': 'relayed $id',
      'messageParameters': <String, Object?>{},
    });

ChatRuntimeSnapshot _chatSnapshot() {
  final cursor = ChatCursor.parse('109');
  return ChatRuntimeSnapshot(
    accounts: <AccountId, ChatAccountState>{
      _account: ChatAccountState(
        accountId: _account,
        server: _server,
        lane: ChatAccountLane.ready,
        credentialGeneration: 1,
        capabilityGeneration: 1,
        scopes: <ChatScopeKey, ChatScopeState>{
          ChatScopeKey(roomToken: _room, threadId: null): ChatScopeState(
            messageIds: const <int>[109],
            historyCursor: cursor,
            futureCursor: cursor,
            lastCommonRead: ChatCursor.parse('100'),
            lastReadMessage: 109,
            unreadMessages: 0,
            hasHistory: true,
            futureConverged: true,
            blocks: <ChatBlock>[ChatBlock(start: cursor, end: cursor)],
          ),
        },
        operations: const {},
      ),
    },
  );
}

String _relayFrame({required String roomToken, required List<int> ids}) {
  final comments = ids
      .map(
        (id) =>
            '{"id":$id,"token":"$roomToken","actorType":"users",'
            '"actorId":"someone","actorDisplayName":"Someone",'
            '"timestamp":${1700000000 + id},"systemMessage":"",'
            '"messageType":"comment","isReplyable":true,"referenceId":"",'
            '"message":"relayed $id","messageParameters":{}}',
      )
      .join(',');
  final chat = ids.isEmpty
      ? '{"refresh":true}'
      : '{"refresh":true,"comments":[$comments]}';
  return '{"type":"event","event":{"target":"room","type":"message",'
      '"message":{"roomid":"$roomToken",'
      '"data":{"type":"chat","chat":$chat}}}}';
}

SignalingRuntimeResult _relayInto(
  SignalingRuntimeSnapshot snapshot, {
  required String roomToken,
}) => applyHpbServerFrame(
  snapshot,
  accountId: signalingAccountA,
  authority: signalingAuthority(),
  connectionEpoch: snapshot.accounts[signalingAccountA]!.connectionEpoch,
  roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
  frame: HpbServerFrame.decode(_relayFrame(roomToken: roomToken, ids: [110])),
  nowMicros: 2000,
);
