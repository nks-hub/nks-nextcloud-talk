import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/call_session_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/calls/call_signaling_session.dart';
import 'package:nextcloudtalk/features/calls/hpb_socket_transport.dart';
import 'package:nextcloudtalk/features/chat/chat_room_signaling.dart';
import 'package:nextcloudtalk/features/chat/chat_typing_indicator.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'chat_typing_provider_lifecycle.part.dart';
part 'chat_relay_provider_lifecycle.part.dart';

void main() {
  _registerTypingProviderLifecycleTests();
  _registerRelayProviderLifecycleTests();
  test('stale draft is not typing activity during a lifecycle sync', () {
    expect(
      chatTypingActivityUpdate(
        composerChanged: false,
        canPost: true,
        hasFocus: true,
        text: 'Existing draft',
      ),
      ChatTypingActivityUpdate.unchanged,
    );
    expect(
      chatTypingActivityUpdate(
        composerChanged: true,
        canPost: true,
        hasFocus: true,
        text: 'Existing draft plus a key',
      ),
      ChatTypingActivityUpdate.active,
    );
    expect(
      chatTypingActivityUpdate(
        composerChanged: false,
        canPost: true,
        hasFocus: false,
        text: 'Existing draft',
      ),
      ChatTypingActivityUpdate.inactive,
    );
  });

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
  chatRelay: null,
  roomEpoch: 1,
  chatRelaySupported: false,
  localPeerId: null,
  iceServers: const <IceServerConfiguration>[],
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

CachedConversation _sessionZeroConversation() {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final room = Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
  )..['sessionId'] = '0';
  return CachedConversation(
    accountId: 'account-a',
    token: room['token']! as String,
    displayName: room['displayName']! as String,
    description: room['description']! as String,
    lastActivity: room['lastActivity']! as int,
    unreadMessages: room['unreadMessages']! as int,
    favorite: room['isFavorite']! as bool,
    isArchived: room['isArchived']! as bool,
    readOnly: room['readOnly']! as int,
    roomType: room['type']! as int,
    roomName: room['name']! as String,
    objectType: room['objectType']! as String,
    avatarVersion: room['avatarVersion']! as String,
    isCustomAvatar: room['isCustomAvatar']! as bool,
    rawJson: jsonEncode(room),
  );
}

Future<ChatTypingState> _firstTypingState(List<ChatTypingState> states) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    for (final state in states) {
      if (state.participants.isNotEmpty) return state;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Typing state was not published');
}

String _activeWelcome() => jsonEncode(<String, Object?>{
  'type': 'welcome',
  'welcome': <String, Object?>{
    'features': <Object?>['hello-v2', 'mcu'],
  },
});

String _activeHello(String id) => jsonEncode(<String, Object?>{
  'id': id,
  'type': 'hello',
  'hello': <String, Object?>{
    'version': '2.0',
    'sessionid': 'hpb-session',
    'resumeid': 'hpb-resume',
  },
});

String _activeRoom(String id) => jsonEncode(<String, Object?>{
  'id': id,
  'type': 'room',
  'room': <String, Object?>{'roomid': 'rooma123'},
});

String _activePeerJoin() => jsonEncode(<String, Object?>{
  'type': 'event',
  'event': <String, Object?>{
    'target': 'room',
    'type': 'join',
    'join': <Object?>[
      <String, Object?>{
        'sessionid': 'peer-alice',
        'roomsessionid': 'alice-session',
        'userid': 'alice',
        'inCall': 0,
        'participantPermissions': 0,
        'actorType': 'users',
        'actorId': 'alice',
        'federated': false,
      },
    ],
  },
});

String _activeTyping() => jsonEncode(<String, Object?>{
  'type': 'message',
  'message': <String, Object?>{
    'sender': <String, Object?>{'type': 'session', 'sessionid': 'peer-alice'},
    'data': <String, Object?>{'type': 'startedTyping'},
  },
});

final class _ActiveTypingClient extends http.BaseClient {
  _ActiveTypingClient({this.holdActive = false, this.activeStatus = 200});

  final bool holdActive;
  final int activeStatus;
  final List<String> paths = <String>[];
  final Completer<void> activeStarted = Completer<void>();
  final Completer<void> releaseActive = Completer<void>();
  int deletes = 0;
  int settings = 0;
  late final Map<String, Object?> _room = _activeRoomJson();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return _activeRawResponse(_activeCapabilitiesJson());
    }
    if (request.url.path.endsWith('/participants/active')) {
      if (request.method == 'DELETE') {
        deletes++;
        return _activeResponse(null);
      }
      if (!activeStarted.isCompleted) activeStarted.complete();
      if (holdActive) await releaseActive.future;
      if (activeStatus == 401) {
        return _activeRawResponse(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'failure',
              'statuscode': 401,
              'message': 'Unauthorised',
            },
            'data': <String, Object?>{},
          },
        }, statusCode: 401);
      }
      return _activeResponse(_room, cookie: 'nc_session=account-a');
    }
    if (request.url.path.endsWith('/settings')) {
      settings++;
      if (request.headers['Cookie'] != 'nc_session=account-a') {
        throw StateError('Settings did not receive the account cookie');
      }
      return _activeResponse(<String, Object?>{
        'signalingMode': 'external',
        'userId': 'fixture-user',
        'hideWarning': true,
        'server': 'https://hpb.example.invalid/signaling',
        'federation': null,
        'stunservers': <Object?>[],
        'turnservers': <Object?>[],
        'sipDialinInfo': '',
        'helloAuthParams': <String, Object?>{
          '2.0': <String, Object?>{'token': 'synthetic-token'},
        },
      });
    }
    if (request.url.path.endsWith('/participants')) {
      return _activeResponse(const <Object?>[]);
    }
    throw StateError('Unexpected request');
  }
}

Map<String, Object?> _activeCapabilitiesJson() => <String, Object?>{
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
          'features': <Object?>['signaling-v3', 'typing-privacy'],
          'config': <String, Object?>{
            'chat': <String, Object?>{'typing-privacy': 0},
          },
          'version': '24.0.2',
        },
      },
    },
  },
};

Map<String, Object?> _activeRoomJson() {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  return Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
  )..['sessionId'] = 'active-session';
}

http.StreamedResponse _activeResponse(Object? data, {String? cookie}) {
  final bytes = utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': data,
      },
    }),
  );
  return http.StreamedResponse(
    Stream.value(bytes),
    200,
    contentLength: bytes.length,
    headers: <String, String>{
      'content-type': 'application/json',
      if (cookie != null) 'set-cookie': '$cookie; Path=/; HttpOnly',
    },
  );
}

http.StreamedResponse _activeRawResponse(Object? json, {int statusCode = 200}) {
  final bytes = utf8.encode(jsonEncode(json));
  return http.StreamedResponse(
    Stream.value(bytes),
    statusCode,
    contentLength: bytes.length,
    headers: const {'content-type': 'application/json'},
  );
}

final class _ActiveTypingSockets implements HpbSocketConnector {
  final Completer<_ActiveTypingSocket> connected = Completer();

  @override
  Future<HpbSocketConnection> connect(HpbEndpoint endpoint) async {
    final socket = _ActiveTypingSocket();
    connected.complete(socket);
    return socket;
  }
}

final class _ActiveTypingSocket implements HpbSocketConnection {
  final StreamController<String> _frames = StreamController(sync: true);
  final List<String> _sent = <String>[];
  final List<Completer<void>> _events = <Completer<void>>[];

  @override
  Stream<String> get frames => _frames.stream;

  void add(String frame) => _frames.add(frame);

  Future<String> sent(int index) async {
    if (_sent.length <= index) {
      final event = Completer<void>();
      _events.add(event);
      await event.future.timeout(const Duration(seconds: 5));
    }
    return _sent[index];
  }

  @override
  Future<void> send(String frame) async {
    _sent.add(frame);
    for (final event in _events) {
      if (!event.isCompleted) event.complete();
    }
    _events.clear();
  }

  @override
  Future<void> close(HpbCloseReason reason) => _frames.close();
}

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
