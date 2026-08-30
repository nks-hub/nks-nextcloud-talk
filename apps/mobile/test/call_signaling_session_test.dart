import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/call_session_repository.dart';
import 'package:nextcloudtalk/features/calls/call_signaling_session.dart';
import 'package:nextcloudtalk/features/calls/hpb_socket_transport.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late CallSessionRepository sessions;
  late MemoryCredentialVault credentials;

  setUp(() {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    sessions = CallSessionRepository(database);
    credentials = MemoryCredentialVault();
  });

  tearDown(() => database.close());

  test(
    'internal settings poll publishes participants and ambiguous batch state',
    () async {
      await _insertAccount(accounts, credentials, accountId: 'account-a');
      final client = _InternalSignalingClient(failBatch: true);
      final api = HttpNextcloudApi(client: client);
      final coordinator = CallSignalingCoordinator(
        accounts: accounts,
        sessions: sessions,
        credentials: credentials,
        api: api,
        socketConnector: _FakeSocketConnector(),
        refreshConversationSession: (_, _) async =>
            ConversationSessionId.parse('refreshed-session'),
      );
      addTearDown(() async {
        await coordinator.dispose();
        api.close();
      });

      final session = await coordinator.start(
        accountId: 'account-a',
        roomToken: 'rooma123',
        nextcloudSessionId: 'session-a',
      );
      final populated = await _waitFor(
        session,
        (update) =>
            update.participants.length == 1 &&
            update.phase == SignalingAccountPhase.internalPolling,
      );

      expect(populated.transport, SignalingTransportKind.internal);
      expect(populated.phase, SignalingAccountPhase.internalPolling);
      expect(populated.participants.single.peerId.value, 'peer-session-a');
      expect(populated.signalingReady, isTrue);
      expect(await session.sendPeerMessage(_peerMessage()), isTrue);

      final ambiguous = await _waitFor(
        session,
        (update) => update.renegotiationRequired,
      );
      final stored = await database.select(database.callSessions).getSingle();
      expect(ambiguous.failure, isNull);
      expect(client.batchAttempts, 1);
      expect(stored.renegotiationRequired, isTrue);

      await session.release();
      expect(await database.select(database.callSessions).get(), isEmpty);
      expect(await session.sendPeerMessage(_peerMessage()), isFalse);
    },
  );

  test(
    'HPB welcome, hello and room reach ready then resume in-window',
    () async {
      await _insertAccount(accounts, credentials, accountId: 'account-a');
      final api = HttpNextcloudApi(client: _ExternalSettingsClient());
      final sockets = _FakeSocketConnector();
      final clock = _FakeClock(1000000);
      final scheduler = _FakeScheduler(clock);
      final coordinator = CallSignalingCoordinator(
        accounts: accounts,
        sessions: sessions,
        credentials: credentials,
        api: api,
        socketConnector: sockets,
        scheduler: scheduler,
        refreshConversationSession: (_, _) async =>
            ConversationSessionId.parse('refreshed-session'),
        nowMicros: clock.now,
        reconnectJitterUnit: () => 0,
      );
      addTearDown(() async {
        await coordinator.dispose();
        api.close();
      });

      final session = await coordinator.start(
        accountId: 'account-a',
        roomToken: 'rooma123',
        nextcloudSessionId: 'session-a',
      );
      await _waitFor(
        session,
        (update) => update.phase == SignalingAccountPhase.hpbAwaitingWelcome,
      );
      final firstSocket = await sockets.waitForSocket(0);

      final helloCommitted = _waitFor(
        session,
        (update) =>
            update.phase == SignalingAccountPhase.hpbHelloPending &&
            update.outcome == SignalingRuntimeOutcome.unchanged,
      );
      firstSocket.addFrame(_welcomeFrame());
      final hello = await firstSocket.waitForSent(0);
      await helloCommitted;
      final helloJson = jsonDecode(hello) as Map<String, Object?>;
      expect(helloJson['type'], 'hello');
      expect(
        (helloJson['hello']! as Map<String, Object?>).containsKey('resumeid'),
        isFalse,
      );

      final roomCommitted = _waitFor(
        session,
        (update) =>
            update.phase == SignalingAccountPhase.hpbRoomPending &&
            update.outcome == SignalingRuntimeOutcome.unchanged,
      );
      firstSocket.addFrame(
        _helloFrame(requestId: helloJson['id']! as String, withResumeId: true),
      );
      final room = await firstSocket.waitForSent(1);
      await roomCommitted;
      final roomJson = jsonDecode(room) as Map<String, Object?>;
      expect(roomJson['type'], 'room');
      firstSocket.addFrame(_roomFrame(requestId: roomJson['id']! as String));

      final ready = await _waitFor(
        session,
        (update) => update.phase == SignalingAccountPhase.signalingReady,
      );
      expect(ready.roomConfirmed, isTrue);
      expect(ready.topology, SignalingTopology.externalMcu);

      await firstSocket.disconnect();
      await _waitFor(
        session,
        (update) => update.phase == SignalingAccountPhase.reconnectWaiting,
      );
      final reconnect = await scheduler.waitForActiveTask();
      reconnect.run();
      final secondSocket = await sockets.waitForSocket(1);
      await _waitFor(
        session,
        (update) => update.phase == SignalingAccountPhase.hpbAwaitingWelcome,
      );

      final resumeCommitted = _waitFor(
        session,
        (update) =>
            update.phase == SignalingAccountPhase.hpbHelloPending &&
            update.outcome == SignalingRuntimeOutcome.unchanged,
      );
      secondSocket.addFrame(_welcomeFrame());
      final resume = await secondSocket.waitForSent(0);
      await resumeCommitted;
      final resumeJson = jsonDecode(resume) as Map<String, Object?>;
      expect(
        (resumeJson['hello']! as Map<String, Object?>)['resumeid'],
        'hpb-resume-a',
      );
      secondSocket.addFrame(
        _helloFrame(
          requestId: resumeJson['id']! as String,
          withResumeId: false,
        ),
      );
      await _waitFor(
        session,
        (update) => update.phase == SignalingAccountPhase.signalingReady,
      );
    },
  );

  test('HPB peer batch serializes every recipient frame', () async {
    await _insertAccount(accounts, credentials, accountId: 'account-a');
    final api = HttpNextcloudApi(client: _ExternalSettingsClient());
    final sockets = _FakeSocketConnector();
    final coordinator = CallSignalingCoordinator(
      accounts: accounts,
      sessions: sessions,
      credentials: credentials,
      api: api,
      socketConnector: sockets,
      refreshConversationSession: (_, _) async =>
          ConversationSessionId.parse('refreshed-session'),
    );
    addTearDown(() async {
      await coordinator.dispose();
      api.close();
    });

    final session = await coordinator.start(
      accountId: 'account-a',
      roomToken: 'rooma123',
      nextcloudSessionId: 'session-a',
    );
    await _waitFor(
      session,
      (update) => update.phase == SignalingAccountPhase.hpbAwaitingWelcome,
    );
    final socket = await sockets.waitForSocket(0);
    final helloCommitted = _waitFor(
      session,
      (update) => update.phase == SignalingAccountPhase.hpbHelloPending,
    );
    socket.addFrame(_welcomeFrame());
    final hello =
        jsonDecode(await socket.waitForSent(0)) as Map<String, Object?>;
    await helloCommitted;
    final roomCommitted = _waitFor(
      session,
      (update) => update.phase == SignalingAccountPhase.hpbRoomPending,
    );
    socket.addFrame(
      _helloFrame(requestId: hello['id']! as String, withResumeId: true),
    );
    final room =
        jsonDecode(await socket.waitForSent(1)) as Map<String, Object?>;
    await roomCommitted;
    socket.addFrame(_roomFrame(requestId: room['id']! as String));
    await _waitFor(
      session,
      (update) => update.phase == SignalingAccountPhase.signalingReady,
    );

    expect(
      await session.sendPeerMessages([
        _typingPeerMessage('peer-a'),
        _typingPeerMessage('peer-b'),
      ]),
      isTrue,
    );
    final first =
        jsonDecode(await socket.waitForSent(2)) as Map<String, Object?>;
    final second =
        jsonDecode(await socket.waitForSent(3)) as Map<String, Object?>;
    expect(_peerRecipient(first), 'peer-a');
    expect(_peerRecipient(second), 'peer-b');
    expect(
      (first['message']! as Map<String, Object?>)['data'],
      <String, Object?>{'type': 'startedTyping'},
    );
    expect(
      (second['message']! as Map<String, Object?>)['data'],
      <String, Object?>{'type': 'startedTyping'},
    );

    await session.release();
  });

  test('persistence failure blocks an internal signaling batch', () async {
    await _insertAccount(accounts, credentials, accountId: 'account-a');
    final client = _InternalSignalingClient(failBatch: false);
    final api = HttpNextcloudApi(client: client);
    final coordinator = CallSignalingCoordinator(
      accounts: accounts,
      sessions: sessions,
      credentials: credentials,
      api: api,
      socketConnector: _FakeSocketConnector(),
      refreshConversationSession: (_, _) async =>
          ConversationSessionId.parse('refreshed-session'),
    );
    addTearDown(() async {
      await coordinator.dispose();
      api.close();
    });

    final session = await coordinator.start(
      accountId: 'account-a',
      roomToken: 'rooma123',
      nextcloudSessionId: 'session-a',
    );
    await _waitFor(
      session,
      (update) =>
          update.participants.length == 1 &&
          update.phase == SignalingAccountPhase.internalPolling,
    );
    final failure = session.updates.firstWhere(
      (update) => update.failure == CallSignalingFailure.persistence,
    );

    await accounts.purgeAccount('account-a');

    expect(await session.sendPeerMessage(_peerMessage()), isFalse);
    expect((await failure).failure, CallSignalingFailure.persistence);
    expect(client.batchAttempts, 0);
  });

  test(
    'process restart recovers durable epochs and room replacement is isolated',
    () async {
      await _insertAccount(accounts, credentials, accountId: 'account-a');
      await sessions.persist(
        _initialState(
          accountId: 'account-a',
          roomToken: 'rooma123',
          connectionEpoch: 4,
          roomEpoch: 6,
        ),
      );
      final client = _HeldSettingsClient();
      final api = HttpNextcloudApi(client: client);
      final coordinator = CallSignalingCoordinator(
        accounts: accounts,
        sessions: sessions,
        credentials: credentials,
        api: api,
        refreshConversationSession: (_, _) async => null,
      );
      addTearDown(() async {
        await coordinator.dispose();
        api.close();
      });

      final first = await coordinator.start(
        accountId: 'account-a',
        roomToken: 'rooma123',
        nextcloudSessionId: 'session-account-a',
      );
      await client.waitForRequestCount(1);
      var stored = await database.select(database.callSessions).getSingle();
      expect(stored.connectionEpoch, 5);
      expect(stored.roomEpoch, 7);
      expect(stored.renegotiationRequired, isTrue);

      final replacement = await coordinator.start(
        accountId: 'account-a',
        roomToken: 'roomc123',
        nextcloudSessionId: 'session-c',
      );
      await client.waitForRequestCount(2);
      stored = await database.select(database.callSessions).getSingle();
      expect(stored.roomToken, 'roomc123');
      expect(first.key.roomToken, 'rooma123');
      expect(replacement.key.roomToken, 'roomc123');
      expect(await first.sendPeerMessage(_peerMessage()), isFalse);
    },
  );
}

Future<void> _insertAccount(
  AccountRepository accounts,
  MemoryCredentialVault credentials, {
  required String accountId,
}) async {
  await accounts.upsertAccount(
    accountId: accountId,
    serverUrl: 'https://cloud.example.invalid/nextcloud',
    loginName: '$accountId-user',
    serverProductName: 'Nextcloud',
    talkFeatures: const <String>{'signaling-v3'},
    createdAt: DateTime.utc(2026, 8, 26),
  );
  credentials.values[accountId] = 'fixture-password';
}

Future<CallSignalingUpdate> _waitFor(
  CallSignalingSession session,
  bool Function(CallSignalingUpdate update) predicate,
) {
  if (predicate(session.current)) {
    return Future<CallSignalingUpdate>.value(session.current);
  }
  return session.updates
      .firstWhere(predicate)
      .timeout(const Duration(seconds: 5));
}

SignalingPeerMessage _peerMessage() => SignalingPeerMessage(
  type: 'offer',
  roomType: 'video',
  sid: 'stream-a',
  recipient: SignalingPeerId.parse('peer-b'),
  sender: null,
  payload: SignalingOpaquePayload.fromJson(<String, Object?>{
    'sdp': 'synthetic-sdp',
  }),
);

SignalingPeerMessage _typingPeerMessage(String peerId) => SignalingPeerMessage(
  type: 'startedTyping',
  roomType: '',
  sid: null,
  recipient: SignalingPeerId.parse(peerId),
  sender: null,
  payload: null,
);

String _peerRecipient(Map<String, Object?> frame) =>
    ((frame['message']! as Map<String, Object?>)['recipient']!
            as Map<String, Object?>)['sessionid']!
        as String;

SignalingAccountState _initialState({
  required String accountId,
  required String roomToken,
  required int connectionEpoch,
  required int roomEpoch,
}) {
  final authority = SignalingAuthority(
    accountId: AccountId.parse(accountId),
    server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
    credentialGeneration: 1,
    capabilityGeneration: 1,
    settingsRevision: 'revision-a',
    profile: SignalingCapabilityProfile.fromTalkFeatures(const <String>[
      'signaling-v3',
    ]),
    roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
    nextcloudSessionId: ConversationSessionId.parse('session-$accountId'),
  );
  return SignalingAccountState.initial(
    authority: authority,
  ).copyWith(connectionEpoch: connectionEpoch, roomEpoch: roomEpoch);
}

String _welcomeFrame() => jsonEncode(<String, Object?>{
  'type': 'welcome',
  'welcome': <String, Object?>{
    'features': <Object?>['hello-v2', 'mcu', 'federation'],
  },
});

String _helloFrame({required String requestId, required bool withResumeId}) =>
    jsonEncode(<String, Object?>{
      'id': requestId,
      'type': 'hello',
      'hello': <String, Object?>{
        'version': '2.0',
        'sessionid': 'hpb-session-a',
        if (withResumeId) 'resumeid': 'hpb-resume-a',
      },
    });

String _roomFrame({required String requestId}) => jsonEncode(<String, Object?>{
  'id': requestId,
  'type': 'room',
  'room': <String, Object?>{'roomid': 'rooma123'},
});

http.StreamedResponse _ocsResponse(int statusCode, Object? data) {
  final bytes = utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': statusCode == 200 ? 'ok' : 'failure',
          'statuscode': statusCode,
          'message': statusCode == 200 ? 'OK' : 'Synthetic failure',
        },
        'data': data,
      },
    }),
  );
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    statusCode,
    contentLength: bytes.length,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

Map<String, Object?> _settingsData(String mode) => <String, Object?>{
  'signalingMode': mode,
  'userId': 'user-a',
  'hideWarning': true,
  'server': mode == 'internal' ? '' : 'https://hpb.example.invalid/signaling',
  'federation': null,
  'stunservers': <Object?>[],
  'turnservers': <Object?>[],
  'sipDialinInfo': '',
  if (mode == 'external')
    'helloAuthParams': <String, Object?>{
      '1.0': <String, Object?>{
        'userid': 'user-a',
        'ticket': 'synthetic-ticket',
      },
      '2.0': <String, Object?>{'token': 'synthetic-token'},
    },
};

final class _InternalSignalingClient extends http.BaseClient {
  _InternalSignalingClient({required this.failBatch});

  final bool failBatch;
  int pullAttempts = 0;
  int batchAttempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/settings')) {
      return _ocsResponse(200, _settingsData('internal'));
    }
    if (request.method == 'POST') {
      batchAttempts++;
      if (failBatch) {
        throw http.ClientException('synthetic ambiguous batch failure');
      }
      return _ocsResponse(200, const <Object?>[]);
    }
    pullAttempts++;
    if (pullAttempts == 1) {
      return _ocsResponse(200, <Object?>[
        <String, Object?>{
          'type': 'usersInRoom',
          'data': <Object?>[
            <String, Object?>{
              'sessionId': 'peer-session-a',
              'roomId': 42,
              'lastPing': 1,
              'userId': 'user-a',
              'inCall': 1,
              'participantPermissions': 7,
              'actorType': 'users',
              'actorId': 'user-a',
            },
          ],
        },
      ]);
    }
    final abortable = request as http.Abortable;
    await abortable.abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}

final class _ExternalSettingsClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return _ocsResponse(200, _settingsData('external'));
  }
}

final class _HeldSettingsClient extends http.BaseClient {
  final List<Completer<void>> _requestEvents = <Completer<void>>[];
  int requestCount = 0;

  Future<void> waitForRequestCount(int expected) {
    if (requestCount >= expected) {
      return Future<void>.value();
    }
    final event = Completer<void>();
    _requestEvents.add(event);
    return event.future.timeout(const Duration(seconds: 5));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    for (final event in _requestEvents.toList(growable: false)) {
      if (!event.isCompleted) {
        event.complete();
      }
    }
    _requestEvents.clear();
    final abortable = request as http.Abortable;
    await abortable.abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}

final class _FakeSocketConnector implements HpbSocketConnector {
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  final List<Completer<void>> _events = <Completer<void>>[];

  Future<_FakeSocket> waitForSocket(int index) async {
    if (sockets.length <= index) {
      final event = Completer<void>();
      _events.add(event);
      await event.future.timeout(const Duration(seconds: 5));
    }
    return sockets[index];
  }

  @override
  Future<HpbSocketConnection> connect(HpbEndpoint endpoint) async {
    final socket = _FakeSocket();
    sockets.add(socket);
    for (final event in _events.toList(growable: false)) {
      if (!event.isCompleted) {
        event.complete();
      }
    }
    _events.clear();
    return socket;
  }
}

final class _FakeSocket implements HpbSocketConnection {
  final StreamController<String> _frames = StreamController<String>.broadcast(
    sync: true,
  );
  final List<String> sent = <String>[];
  final List<Completer<void>> _sendEvents = <Completer<void>>[];
  bool _closed = false;

  @override
  Stream<String> get frames => _frames.stream;

  void addFrame(String frame) => _frames.add(frame);

  Future<String> waitForSent(int index) async {
    if (sent.length <= index) {
      final event = Completer<void>();
      _sendEvents.add(event);
      await event.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'Timed out waiting for frame $index; sent ${sent.length}',
        ),
      );
    }
    return sent[index];
  }

  Future<void> disconnect() async {
    if (!_closed) {
      _closed = true;
      await _frames.close();
    }
  }

  @override
  Future<void> send(String frame) async {
    sent.add(frame);
    for (final event in _sendEvents.toList(growable: false)) {
      if (!event.isCompleted) {
        event.complete();
      }
    }
    _sendEvents.clear();
  }

  @override
  Future<void> close(HpbCloseReason reason) => disconnect();
}

final class _FakeClock {
  _FakeClock(this.micros);

  int micros;

  int now() => micros;
}

final class _FakeScheduler implements SignalingScheduler {
  _FakeScheduler(this.clock);

  final _FakeClock clock;
  final List<_FakeScheduledTask> tasks = <_FakeScheduledTask>[];
  final List<Completer<void>> _events = <Completer<void>>[];

  @override
  SignalingScheduledTask schedule(Duration delay, void Function() callback) {
    final task = _FakeScheduledTask(clock, delay, callback);
    tasks.add(task);
    for (final event in _events.toList(growable: false)) {
      if (!event.isCompleted) {
        event.complete();
      }
    }
    _events.clear();
    return task;
  }

  Future<_FakeScheduledTask> waitForActiveTask() async {
    var active = tasks.where((task) => task.isActive).toList(growable: false);
    if (active.isEmpty) {
      final event = Completer<void>();
      _events.add(event);
      await event.future.timeout(const Duration(seconds: 5));
      active = tasks.where((task) => task.isActive).toList(growable: false);
    }
    return active.last;
  }
}

final class _FakeScheduledTask implements SignalingScheduledTask {
  _FakeScheduledTask(this.clock, this.delay, this.callback);

  final _FakeClock clock;
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
    clock.micros += delay.inMicroseconds;
    callback();
  }
}
