import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_signaling_session.dart';
import 'package:nextcloudtalk/features/chat/chat_typing_indicator.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test(
    'projects peer-scoped typing, stop, timeout and transport loss',
    () async {
      final scheduler = _ManualScheduler();
      final source = StreamController<CallSignalingUpdate>.broadcast(
        sync: true,
      );
      var released = false;
      final controller = ChatTypingController(
        key: _key,
        localLoginName: 'fixture-user',
        initial: _update(participants: [_self, _alice]),
        updates: source.stream,
        sendMessages: (_) async => true,
        release: () async => released = true,
        scheduler: scheduler,
      );

      source.add(
        _update(
          participants: [_self, _alice],
          messages: [_typingMessage('startedTyping', _alice.peerId)],
        ),
      );
      expect(controller.current.availability, ChatTypingAvailability.available);
      expect(controller.current.participants, [
        const ChatTypingParticipant(
          peerId: 'peer-alice',
          identity: 'user:alice',
          actorId: 'alice',
          displayName: 'alice',
        ),
      ]);
      controller.updateParticipantNames(const <String, String>{
        'session:alice-session': 'Alice Example',
      });
      expect(
        controller.current.participants.single.displayName,
        'Alice Example',
      );
      final firstTimeout = scheduler.singleActive(const Duration(seconds: 15));

      source.add(
        _update(
          participants: [_self, _alice],
          messages: [_typingMessage('startedTyping', _alice.peerId)],
        ),
      );
      expect(firstTimeout.isActive, isFalse);
      final refreshedTimeout = scheduler.singleActive(
        const Duration(seconds: 15),
      );

      source.add(
        _update(
          participants: [_self, _alice],
          messages: [_typingMessage('stoppedTyping', _alice.peerId)],
        ),
      );
      expect(refreshedTimeout.isActive, isFalse);
      expect(controller.current.participants, isEmpty);

      source.add(
        _update(
          participants: [_self, _alice],
          messages: [_typingMessage('startedTyping', _alice.peerId)],
        ),
      );
      scheduler.singleActive(const Duration(seconds: 15)).run();
      expect(controller.current.participants, isEmpty);

      source.add(
        _update(
          participants: [_self, _alice],
          messages: [_typingMessage('startedTyping', _self.peerId)],
        ),
      );
      expect(
        controller.current.participants,
        isEmpty,
        reason: 'self is hidden',
      );

      source.add(
        _update(
          key: (accountId: 'account-b', roomToken: 'roomb456'),
          participants: [_alice],
          messages: [_typingMessage('startedTyping', _alice.peerId)],
        ),
      );
      expect(
        controller.current.participants,
        isEmpty,
        reason: 'scope is exact',
      );

      source.add(
        _update(
          participants: [_self, _alice],
          phase: SignalingAccountPhase.reconnectWaiting,
          roomConfirmed: false,
        ),
      );
      expect(
        controller.current.availability,
        ChatTypingAvailability.connecting,
      );
      expect(controller.current.participants, isEmpty);

      await controller.dispose();
      await source.close();
      expect(released, isTrue);
      expect(scheduler.tasks.where((task) => task.isActive), isEmpty);
    },
  );

  test('broadcasts start, refresh, stop and catches a joining peer', () async {
    final sourceId = Object();
    final scheduler = _ManualScheduler();
    final source = StreamController<CallSignalingUpdate>.broadcast(sync: true);
    final sent = <List<SignalingPeerMessage>>[];
    final controller = ChatTypingController(
      key: _key,
      localLoginName: 'fixture-user',
      initial: _update(participants: [_self, _alice]),
      updates: source.stream,
      sendMessages: (messages) async {
        sent.add(messages.toList(growable: false));
        return true;
      },
      release: () async {},
      scheduler: scheduler,
    );

    await controller.recordLocalActivity(sourceId, true);
    expect(_wire(sent), [
      {'type': 'startedTyping', 'to': 'peer-alice'},
    ]);

    await controller.recordLocalActivity(sourceId, true);
    expect(sent, hasLength(1), reason: 'a keystroke is not a network frame');
    scheduler.singleActive(const Duration(seconds: 10)).run();
    await _flushAsync();
    expect(_wire(sent), [
      {'type': 'startedTyping', 'to': 'peer-alice'},
      {'type': 'startedTyping', 'to': 'peer-alice'},
    ]);

    await controller.recordLocalActivity(sourceId, false);
    expect(_wire(sent).last, {'type': 'stoppedTyping', 'to': 'peer-alice'});

    await controller.recordLocalActivity(sourceId, true);
    source.add(_update(participants: [_self, _alice, _bob]));
    await _flushAsync();
    expect(_wire(sent).last, {'type': 'startedTyping', 'to': 'peer-bob'});

    await controller.dispose();
    await source.close();
  });

  test('one inactive pane does not stop another active composer', () async {
    final source = StreamController<CallSignalingUpdate>.broadcast(sync: true);
    final sent = <List<SignalingPeerMessage>>[];
    final controller = ChatTypingController(
      key: _key,
      localLoginName: 'fixture-user',
      initial: _update(participants: [_self, _alice]),
      updates: source.stream,
      sendMessages: (messages) async {
        sent.add(messages.toList(growable: false));
        return true;
      },
      release: () async {},
      scheduler: _ManualScheduler(),
    );
    final rootPane = Object();
    final threadPane = Object();

    await controller.recordLocalActivity(rootPane, true);
    await controller.recordLocalActivity(threadPane, true);
    await controller.recordLocalActivity(rootPane, false);
    expect(
      _wire(sent).where((message) => message['type'] == 'stoppedTyping'),
      isEmpty,
    );

    await controller.recordLocalActivity(threadPane, false);
    expect(
      _wire(sent).where((message) => message['type'] == 'stoppedTyping'),
      hasLength(1),
    );

    await controller.dispose();
    await source.close();
  });

  test(
    'typing admission is authenticated, capability-bound and fail-closed',
    () {
      expect(chatTypingAllowed(_capabilities(typingPrivacy: 0)), isTrue);
      expect(chatTypingAllowed(_capabilities(typingPrivacy: 1)), isFalse);
      expect(
        chatTypingAllowed(_capabilities(typingPrivacy: null)),
        isFalse,
        reason: 'missing account policy is not assumed public',
      );
      expect(
        chatTypingAllowed(
          _capabilities(typingPrivacy: 0, features: const ['typing-privacy']),
        ),
        isFalse,
        reason: 'signaling-v3 is required',
      );
    },
  );

  test('room key uses the validated cached session and feature set', () {
    final fixture =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )!
            as Map<String, Object?>;
    final ocs = fixture['ocs']! as Map<String, Object?>;
    final data = ocs['data']! as List<Object?>;
    final room = data.first! as Map<String, Object?>;
    final account = StoredAccount(
      id: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeaturesJson: jsonEncode(['signaling-v3', 'typing-privacy']),
      selected: true,
      createdAtMillis: 0,
    );
    final conversation = CachedConversation(
      accountId: 'account-a',
      token: 'rooma123',
      displayName: 'Synthetic room A',
      description: '',
      lastActivity: 0,
      unreadMessages: 0,
      favorite: false,
      isArchived: false,
      readOnly: 0,
      roomType: 2,
      roomName: '',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      rawJson: jsonEncode(room),
    );

    expect(chatTypingRoomKeyFor(account: account, conversation: conversation), (
      accountId: 'account-a',
      roomToken: 'rooma123',
      nextcloudSessionId: 'fixture-session-a',
    ));
    expect(
      chatTypingRoomKeyFor(
        account: StoredAccount(
          id: account.id,
          serverUrl: account.serverUrl,
          loginName: account.loginName,
          serverProductName: account.serverProductName,
          talkFeaturesJson: '[]',
          selected: account.selected,
          createdAtMillis: account.createdAtMillis,
        ),
        conversation: conversation,
      ),
      isNull,
    );
  });
}

const ChatTypingRoomKey _key = (
  accountId: 'account-a',
  roomToken: 'rooma123',
  nextcloudSessionId: 'session-local',
);

final SignalingParticipant _self = _participant(
  peerId: 'peer-local',
  sessionId: 'session-local',
  userId: 'fixture-user',
);
final SignalingParticipant _alice = _participant(
  peerId: 'peer-alice',
  sessionId: 'alice-session',
  userId: 'alice',
);
final SignalingParticipant _bob = _participant(
  peerId: 'peer-bob',
  sessionId: 'bob-session',
  userId: 'bob',
);

SignalingParticipant _participant({
  required String peerId,
  required String sessionId,
  required String userId,
}) => SignalingParticipant(
  peerId: SignalingPeerId.parse(peerId),
  nextcloudSessionId: ConversationSessionId.parse(sessionId),
  userId: userId,
  inCall: 0,
  permissions: 0,
  actorType: 'users',
  actorId: userId,
  federated: false,
  features: const <String>[],
);

CallSignalingUpdate _update({
  CallSignalingKey key = const (accountId: 'account-a', roomToken: 'rooma123'),
  List<SignalingParticipant> participants = const [],
  List<SignalingPeerMessage> messages = const [],
  SignalingAccountPhase phase = SignalingAccountPhase.signalingReady,
  bool roomConfirmed = true,
}) => CallSignalingUpdate(
  key: key,
  outcome: SignalingRuntimeOutcome.unchanged,
  phase: phase,
  transport: SignalingTransportKind.externalHpb,
  topology: SignalingTopology.externalPeerToPeer,
  participants: participants,
  roomConfirmed: roomConfirmed,
  federationInterrupted: false,
  renegotiationRequired: false,
  messages: messages,
  controls: const <HpbControlMessage>[],
  failure: null,
);

SignalingPeerMessage _typingMessage(String type, SignalingPeerId sender) =>
    SignalingPeerMessage(
      type: type,
      roomType: '',
      sid: null,
      recipient: null,
      sender: sender,
      payload: null,
    );

List<Map<String, Object?>> _wire(List<List<SignalingPeerMessage>> batches) => [
  for (final batch in batches)
    for (final message in batch) Map<String, Object?>.from(message.toWire()),
];

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

CapabilitySnapshot _capabilities({
  required int? typingPrivacy,
  List<String> features = const ['signaling-v3', 'typing-privacy'],
}) => CapabilitySnapshot.fromJson(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'version': <String, Object?>{
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': <String, Object?>{
        'spreed': <String, Object?>{
          'features': <Object?>[...features],
          'config': <String, Object?>{
            'chat': <String, Object?>{'typing-privacy': ?typingPrivacy},
          },
          'version': '24.0.2',
        },
      },
    },
  },
}, context: CapabilityContext.authenticated);

final class _ManualScheduler implements SignalingScheduler {
  final List<_ManualTask> tasks = [];

  @override
  SignalingScheduledTask schedule(Duration delay, void Function() callback) {
    final task = _ManualTask(delay, callback);
    tasks.add(task);
    return task;
  }

  _ManualTask singleActive(Duration delay) =>
      tasks.singleWhere((task) => task.isActive && task.delay == delay);
}

final class _ManualTask implements SignalingScheduledTask {
  _ManualTask(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void run() {
    if (!_active) {
      return;
    }
    _active = false;
    callback();
  }
}
