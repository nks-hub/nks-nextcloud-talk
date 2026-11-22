part of 'call_lifecycle_service_test.dart';

void _registerCallForegroundLifecycleTests() {
  test(
    'no live signaling replacement releases foreground and REST without microphone',
    () async {
      final permission = Completer<void>();
      final foreground = _ForegroundCalls(startGate: permission.future);
      var microphones = 0;
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        _DelayedMicrophone(() async {
          microphones++;
        }),
        holdSettings: true,
      );
      addTearDown(() async {
        if (!permission.isCompleted) permission.complete();
        await fixture.close();
      });
      final joining = fixture.controller.join();
      await foreground.firstStart.future;
      await fixture.coordinator.dispose();
      permission.complete();
      await joining;
      final state = fixture.container.read(
        callJoinControllerProvider(_ForegroundJoinFixture.key),
      );
      expect(state.phase, CallJoinPhase.failed);
      expect(state.signalingUnavailable, isTrue);
      expect(microphones, 0);
      expect(foreground.active, isEmpty);
      expect(fixture.rest.server.callMethods.where((m) => m != 'GET'), [
        'POST',
        'DELETE',
      ]);
    },
  );
  test(
    'permission delay cannot bind media to the replaced chat signaling lease',
    () async {
      final permission = Completer<void>();
      final foreground = _ForegroundCalls(startGate: permission.future);
      final engine = _CameraForegroundEngine();
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        engine,
        holdSettings: true,
      );
      addTearDown(() async {
        if (!permission.isCompleted) permission.complete();
        await fixture.close();
      });
      const key = _ForegroundJoinFixture.key;
      final original = await fixture.container.read(
        chatRoomSignalingProvider(key).future,
      );
      final joining = fixture.controller.join();
      await foreground.firstStart.future;
      fixture.container.invalidate(chatRoomSignalingProvider(key));
      final replacement = await fixture.container.read(
        chatRoomSignalingProvider(key).future,
      );
      expect(identical(original.session, replacement.session), isFalse);
      expect(replacement.nextcloudSessionId, original.nextcloudSessionId);
      permission.complete();
      await joining;
      await pumpEventQueue();
      expect(
        fixture.container.read(callJoinControllerProvider(key)).phase,
        CallJoinPhase.joined,
      );
      expect(engine.audio.disposed, isFalse);
      expect(foreground.active, {foreground.started.single});
      expect(fixture.rest.server.callMethods.where((m) => m != 'GET'), [
        'POST',
      ]);
    },
  );

  test(
    'an offer sent while the microphone permission is pending is answered',
    () async {
      const local = 'session-rooma123';
      // Sorts after the local id, so the peer is the side that offers.
      const peer = 'zz-peer-session';
      final permission = Completer<void>();
      final foreground = _ForegroundCalls(startGate: permission.future);
      final engine = _AnsweringEngine();
      final signaling = _ScriptedInternalSignaling(local: local);
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        engine,
        signaling: signaling.handle,
      );
      addTearDown(() async {
        if (!permission.isCompleted) permission.complete();
        await fixture.close();
        await signaling.close();
      });
      signaling.deliver(peerInCall: peer, localInCall: 0);
      await signaling.pullStarted(2);

      final joining = fixture.controller.join();
      await foreground.firstStart.future;
      // The peer offers as soon as the REST join lists this side in the call,
      // while Android still shows the permission prompt. Its ICE candidate
      // follows on the next pull and replaces the lane's current state.
      signaling.deliver(
        peerInCall: peer,
        localInCall: 7,
        message: <String, Object?>{
          'type': 'offer',
          'sid': 'peer-sid-1',
          'payload': <String, Object?>{'type': 'offer', 'sdp': 'v=0 offer'},
        },
      );
      signaling.deliver(
        peerInCall: peer,
        localInCall: 7,
        message: <String, Object?>{
          'type': 'candidate',
          'sid': 'peer-sid-1',
          'payload': <String, Object?>{
            'candidate': <String, Object?>{
              'candidate': 'candidate:1 1 udp 1 192.0.2.10 9 typ host',
              'sdpMid': '0',
              'sdpMLineIndex': 0,
            },
          },
        },
      );
      await signaling.pullStarted(4);
      permission.complete();
      await joining;
      await pumpEventQueue();

      expect(
        fixture.container
            .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
            .phase,
        CallJoinPhase.joined,
      );
      final connection = engine.connections.single;
      expect(connection.remoteDescriptions, ['offer']);
      expect(connection.candidates, hasLength(1));
      expect(
        signaling.sent.where(
          (message) => message['type'] == 'answer' && message['to'] == peer,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'duplicate camera enable shares admission and camera off cancels it',
    () async {
      final ready = Completer<void>();
      final foreground = _ForegroundCalls(cameraGate: ready.future);
      final engine = _CameraForegroundEngine();
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        engine,
        holdSettings: true,
      );
      addTearDown(fixture.close);
      await fixture.controller.join();
      final pending = fixture.controller.setCameraEnabled(true);
      await fixture.controller.setCameraEnabled(true);
      expect(foreground.cameraChanges.map((change) => change.$2), [true]);
      await fixture.controller.setCameraEnabled(false);
      ready.complete();
      await pending;
      expect(engine.cameraOpens, 0);
      expect(foreground.cameraChanges.map((change) => change.$2), [
        true,
        false,
      ]);
      expect(foreground.active, {foreground.started.single});
    },
  );
  test(
    'camera waits for its foreground type and rolls back a failed capture',
    () async {
      final ready = Completer<void>();
      final foreground = _ForegroundCalls(cameraGate: ready.future);
      final engine = _CameraForegroundEngine(failCamera: true);
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        engine,
        holdSettings: true,
      );
      addTearDown(fixture.close);
      await fixture.controller.join();
      final turningOn = fixture.controller.setCameraEnabled(true);
      await pumpEventQueue();
      expect(engine.cameraOpens, 0);
      expect(foreground.cameraChanges.map((change) => change.$2), [true]);
      ready.complete();
      await turningOn;
      expect(engine.cameraOpens, 1);
      expect(foreground.cameraChanges.map((change) => change.$2), [
        true,
        false,
      ]);
      expect(foreground.active, {foreground.started.single});
      expect(engine.audio.disposed, isFalse);
    },
  );

  test(
    'camera foreground denial leaves the microphone and server seat running',
    () async {
      final foreground = _ForegroundCalls(cameraDenied: true);
      final engine = _CameraForegroundEngine();
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        engine,
        holdSettings: true,
      );
      addTearDown(fixture.close);
      await fixture.controller.join();
      await fixture.controller.setCameraEnabled(true);
      expect(engine.cameraOpens, 0);
      expect(engine.audio.disposed, isFalse);
      expect(foreground.active, {foreground.started.single});
      final state = fixture.container.read(
        callJoinControllerProvider(_ForegroundJoinFixture.key),
      );
      expect(state.phase, CallJoinPhase.joined);
      expect(state.mediaError, CallMediaError.cameraPermissionDenied);
      expect(
        fixture.rest.server.callMethods.where((method) => method != 'GET'),
        ['POST'],
      );
    },
  );

  test('a late camera permission cannot reopen media after leaving', () async {
    final ready = Completer<void>();
    final foreground = _ForegroundCalls(cameraGate: ready.future);
    final engine = _CameraForegroundEngine();
    final fixture = await _ForegroundJoinFixture.create(
      foreground,
      engine,
      holdSettings: true,
    );
    addTearDown(fixture.close);
    await fixture.controller.join();
    final turningOn = fixture.controller.setCameraEnabled(true);
    await pumpEventQueue();
    await fixture.controller.leave();
    ready.complete();
    await turningOn;
    expect(engine.cameraOpens, 0);
    expect(foreground.active, isEmpty);
  });

  test(
    'camera upgrades the call mode and turning it off keeps video',
    () async {
      final foreground = _ForegroundCalls();
      final engine = _CameraForegroundEngine();
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        engine,
        holdSettings: true,
      );
      addTearDown(fixture.close);
      await fixture.controller.join();
      expect(
        fixture.rest.server.callRequests
            .where(
              (request) => request.method == 'POST' || request.method == 'PUT',
            )
            .map((request) => request.bodyFields['flags']),
        ['3'],
      );
      await fixture.controller.setCameraEnabled(true);
      expect(engine.cameraOpens, 1);
      expect(
        fixture.rest.server.callRequests
            .where(
              (request) => request.method == 'POST' || request.method == 'PUT',
            )
            .map((request) => request.bodyFields['flags']),
        ['3', '7'],
        reason: 'turning on video upgrades the announced call mode',
      );
      await fixture.controller.setCameraEnabled(true);
      expect(foreground.cameraChanges.map((change) => change.$2), [true]);
      foreground.beforeCameraDisable = () =>
          expect(engine.video.disposed, isTrue);
      await fixture.controller.setCameraEnabled(false);
      expect(foreground.cameraChanges.map((change) => change.$2), [
        true,
        false,
      ]);
      expect(engine.audio.disposed, isFalse);
      expect(
        fixture.rest.server.callRequests
            .where(
              (request) => request.method == 'POST' || request.method == 'PUT',
            )
            .map((request) => request.bodyFields['flags']),
        ['3', '7'],
        reason: 'turning the camera off does not change the selected call mode',
      );
    },
  );
  test('camera upgrade reapplies permissions changed after joining', () async {
    final foreground = _ForegroundCalls();
    final engine = _CameraForegroundEngine();
    final fixture = await _ForegroundJoinFixture.create(
      foreground,
      engine,
      holdSettings: true,
    );
    addTearDown(fixture.close);
    await fixture.controller.join();
    await fixture.rest.seedRoom(
      token: 'rooma123',
      permissions: 255 - CallPermission.video,
    );

    await fixture.controller.setCameraEnabled(true);

    expect(engine.cameraOpens, 0);
    expect(foreground.cameraChanges.map((change) => change.$2), [true, false]);
    expect(
      fixture.container
          .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
          .phase,
      CallJoinPhase.joined,
    );
    expect(
      fixture.container
          .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
          .publishing
          .video,
      isFalse,
      reason: 'the camera control must disappear with the revoked permission',
    );
    expect(
      fixture.rest.server.callRequests
          .where(
            (request) => request.method == 'POST' || request.method == 'PUT',
          )
          .map((request) => request.bodyFields['flags']),
      ['3', '3'],
      reason: 'the current policy must remove video before the update',
    );
  });
  test('signaling refresh stops video after permission is revoked', () async {
    final foreground = _ForegroundCalls();
    final engine = _CameraForegroundEngine();
    final fixture = await _ForegroundJoinFixture.create(
      foreground,
      engine,
      holdSettings: true,
    );
    addTearDown(fixture.close);
    await fixture.controller.join();
    await fixture.controller.setCameraEnabled(true);
    expect(engine.video.disposed, isFalse);
    await fixture.rest.seedRoom(
      token: 'rooma123',
      permissions: 255 - CallPermission.video,
    );

    await fixture.controller.refreshCallFlagsForTesting();

    expect(engine.video.disposed, isTrue);
    expect(foreground.cameraChanges.map((change) => change.$2), [true, false]);
    final state = fixture.container.read(
      callJoinControllerProvider(_ForegroundJoinFixture.key),
    );
    expect(state.media.cameraOn, isFalse);
    expect(state.publishing.video, isFalse);
    expect(
      fixture.rest.server.callRequests
          .where(
            (request) => request.method == 'POST' || request.method == 'PUT',
          )
          .map((request) => request.bodyFields['flags']),
      ['3', '7', '3'],
    );
  });
  test('failed camera upgrade is followed by an audio refresh', () async {
    final firstUpdateStarted = Completer<void>();
    final releaseFirstUpdate = Completer<void>();
    var failVideoUpdate = false;
    final foreground = _ForegroundCalls();
    final engine = _CameraForegroundEngine();
    final fixture = await _ForegroundJoinFixture.create(
      foreground,
      engine,
      holdSettings: true,
      onCall: (request, index) async {
        if (failVideoUpdate &&
            request.method == 'PUT' &&
            request.bodyFields['flags'] == '7') {
          failVideoUpdate = false;
          firstUpdateStarted.complete();
          await releaseFirstUpdate.future;
          return _ocsResponse(409, <String, Object?>{});
        }
        return _ocsResponse(200, <String, Object?>{});
      },
    );
    addTearDown(fixture.close);
    await fixture.controller.join();
    await pumpEventQueue();

    failVideoUpdate = true;
    final camera = fixture.controller.setCameraEnabled(true);
    await firstUpdateStarted.future;
    final refresh = fixture.controller.refreshCallFlagsForTesting();
    releaseFirstUpdate.complete();
    await camera;
    await refresh;

    final flags = fixture.rest.server.callRequests
        .where((request) => request.method == 'POST' || request.method == 'PUT')
        .map((request) => request.bodyFields['flags'])
        .toList(growable: false);
    expect(flags.first, '3');
    expect(
      flags.sublist(flags.length - 2),
      ['7', '3'],
      reason: 'the queued refresh must read the rolled-back audio mode',
    );
    expect(engine.cameraOpens, 0);
    expect(foreground.cameraChanges.map((change) => change.$2), [true, false]);
  });
  test(
    'media disposal failure still stops its foreground owner and REST seat',
    () async {
      final foreground = _ForegroundCalls();
      final disposalFailure = StateError('synthetic audio disposal failure');
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        _DisposalFailureEngine(disposalFailure),
        holdSettings: true,
      );
      addTearDown(fixture.close);
      await fixture.controller.join();
      await expectLater(
        fixture.controller.leave(),
        throwsA(same(disposalFailure)),
      );
      expect(foreground.active, isEmpty);
      expect(foreground.stopped, [foreground.started.single]);
      expect(fixture.rest.server.callMethods.where((m) => m != 'GET'), [
        'POST',
        'DELETE',
      ]);
    },
  );
  test(
    'microphone waits for foreground acknowledgement and failure stops its owner',
    () async {
      final ready = Completer<void>();
      final foreground = _ForegroundCalls(startGate: ready.future);
      var microphones = 0;
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        _DelayedMicrophone(() async {
          microphones++;
        }),
      );
      addTearDown(fixture.close);
      final joining = fixture.controller.join();
      await foreground.firstStart.future;
      expect(microphones, 0);
      ready.complete();
      await joining;
      await foreground.firstStop.future;
      expect(microphones, 1);
      expect(foreground.stopped, [foreground.started.single]);
    },
  );

  test('a hang-up during the join gives the seat back', () async {
    // The system call screen can end a call the app is still joining: the
    // VoIP push rings, the person answers and hangs up during the several
    // round trips. `leave()` was a no-op while the state was busy, so the
    // join settled into a live call with an open microphone that the ring,
    // by then dropped, could no longer end.
    final ready = Completer<void>();
    final foreground = _ForegroundCalls(startGate: ready.future);
    final fixture = await _ForegroundJoinFixture.create(
      foreground,
      _DelayedMicrophone(() async {}),
    );
    addTearDown(fixture.close);

    final joining = fixture.controller.join();
    await foreground.firstStart.future;
    await fixture.controller.leave();
    ready.complete();
    await joining;

    expect(
      fixture.container
          .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
          .phase,
      CallJoinPhase.idle,
      reason: 'the hang-up has to win, not the join it interrupted',
    );
    expect(foreground.active, isEmpty);
    expect(fixture.rest.server.callMethods.where((m) => m != 'GET'), [
      'POST',
      'DELETE',
    ]);
  });

  test('leaving a call stops the screen capture service', () async {
    // The service is a foreground service of type mediaProjection: it keeps
    // running, notification and all, until something stops it. Only the
    // share button ever did, so leaving a call while sharing left the phone
    // telling its owner the screen was still being shared.
    final screenShare = _RecordingScreenShare();
    final foreground = _ForegroundCalls();
    final fixture = await _ForegroundJoinFixture.create(
      foreground,
      _ScreenShareEngine(),
      screenShare: screenShare,
    );
    addTearDown(fixture.close);
    await fixture.controller.join();
    final error = await fixture.controller.setScreenSharing(true);

    expect(error, isNull);
    expect(screenShare.starts, 1);
    expect(screenShare.stops, 0);

    await fixture.controller.leave();

    expect(screenShare.stops, 1, reason: 'the notification has to go too');
  });

  test(
    'failed foreground admission releases REST without opening a microphone',
    () async {
      final foreground = _ForegroundCalls(denied: true);
      var microphones = 0;
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        _DelayedMicrophone(() async {
          microphones++;
        }),
      );
      addTearDown(fixture.close);
      await fixture.controller.join();
      expect(microphones, 0);
      expect(fixture.rest.server.callMethods, ['POST', 'DELETE']);
      expect(foreground.active, isEmpty);
    },
  );

  test(
    'retry waits for old cleanup and cannot lose its new foreground owner',
    () async {
      final finishOld = Completer<void>(),
          secondMicrophone = Completer<void>(),
          finishNew = Completer<void>();
      final foreground = _ForegroundCalls(stopGate: finishOld.future);
      var microphones = 0;
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        _DelayedMicrophone(() async {
          if (++microphones == 2) {
            secondMicrophone.complete();
            await finishNew.future;
          }
        }),
      );
      addTearDown(() async {
        if (!finishOld.isCompleted) finishOld.complete();
        if (!finishNew.isCompleted) finishNew.complete();
        await fixture.close();
      });
      await fixture.controller.join();
      await foreground.firstStop.future;
      final oldOwner = foreground.started.single;
      final retry = fixture.controller.join();
      await pumpEventQueue();
      expect(foreground.started, [oldOwner]);
      expect(fixture.rest.server.callMethods.where((m) => m != 'GET'), [
        'POST',
      ]);
      finishOld.complete();
      await secondMicrophone.future;
      expect(foreground.started, hasLength(2));
      expect(foreground.started.last, isNot(oldOwner));
      expect(foreground.stopped, [oldOwner]);
      expect(foreground.active, {foreground.started.last});
      expect(fixture.rest.server.callMethods.where((m) => m != 'GET'), [
        'POST',
        'DELETE',
        'POST',
      ]);
      finishNew.complete();
      await retry;
    },
  );
}

final class _ForegroundCalls implements CallForegroundService {
  _ForegroundCalls({
    this.startGate,
    this.stopGate,
    this.denied = false,
    this.cameraGate,
    this.cameraDenied = false,
  });
  final Future<void>? startGate;
  final Future<void>? stopGate;
  final Future<void>? cameraGate;
  final bool cameraDenied;
  final cameraChanges = <(String, bool)>[];
  void Function()? beforeCameraDisable;
  final bool denied;
  final started = <String>[], stopped = <String>[];
  final active = <String>{};
  final firstStart = Completer<void>(), firstStop = Completer<void>();

  @override
  Future<void> setCameraEnabled(String owner, bool enabled) async {
    cameraChanges.add((owner, enabled));
    if (!enabled) {
      beforeCameraDisable?.call();
      return;
    }
    await cameraGate;
    if (cameraDenied) {
      throw const CallMediaException(CallMediaError.cameraPermissionDenied);
    }
  }

  @override
  Future<void> start(String owner) async {
    started.add(owner);
    active.add(owner);
    if (!firstStart.isCompleted) firstStart.complete();
    await startGate;
    if (denied) {
      throw const CallMediaException(CallMediaError.microphonePermissionDenied);
    }
  }

  @override
  Future<void> stop(String owner) async {
    stopped.add(owner);
    if (!firstStop.isCompleted) firstStop.complete();
    if (stopped.length == 1) await stopGate;
    active.remove(owner);
  }
}

final class _CameraForegroundEngine implements CallMediaEngine {
  _CameraForegroundEngine({this.failCamera = false});
  final bool failCamera;
  final audio = _CameraForegroundAudio();
  final video = _CameraForegroundVideo();
  int cameraOpens = 0;
  @override
  Future<CallLocalAudio> openMicrophone() async => audio;
  @override
  Future<CallLocalVideo> openCamera() async {
    cameraOpens++;
    if (failCamera) {
      throw const CallMediaException(CallMediaError.cameraUnavailable);
    }
    return video;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CameraForegroundAudio implements CallLocalAudio {
  bool disposed = false;
  @override
  Stream<void> get routeChanges => const Stream.empty();
  @override
  Future<List<CallAudioRoute>> routes() async => [];
  @override
  Future<void> selectRoute(CallAudioRoute route) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setSpeakerphone(bool on) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

final class _CameraForegroundVideo implements CallLocalVideo {
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Internal signalling for one room, answered one scripted pull at a time.
/// A pull with nothing scripted waits for the next [deliver].
final class _ScriptedInternalSignaling {
  _ScriptedInternalSignaling({required this.local});

  final String local;
  final _pulls = StreamController<List<Object?>>();
  late final _next = StreamIterator<List<Object?>>(_pulls.stream);
  final sent = <Map<String, Object?>>[];
  int _pullCount = 0;
  final _pullWaiters = <int, Completer<void>>{};

  /// Queues one pull: an optional message from [peerInCall], then the roster.
  void deliver({
    required String peerInCall,
    required int localInCall,
    Map<String, Object?>? message,
  }) {
    Map<String, Object?> session(String id, int inCall) => <String, Object?>{
      'sessionId': id,
      'roomId': 42,
      'lastPing': 1,
      'userId': 'user-$id',
      'inCall': inCall,
      'participantPermissions': 255,
      'actorType': 'users',
      'actorId': 'user-$id',
    };
    _pulls.add(<Object?>[
      if (message != null)
        <String, Object?>{
          'type': 'message',
          'data': jsonEncode(<String, Object?>{
            'to': local,
            'from': peerInCall,
            'roomType': 'video',
            ...message,
          }),
        },
      <String, Object?>{
        'type': 'usersInRoom',
        'data': <Object?>[session(local, localInCall), session(peerInCall, 7)],
      },
    ]);
  }

  /// Completes once the lane has asked for its [count]th pull.
  Future<void> pullStarted(int count) {
    if (_pullCount >= count) return Future<void>.value();
    return _pullWaiters
        .putIfAbsent(count, Completer<void>.new)
        .future
        .timeout(const Duration(seconds: 5));
  }

  Future<void> close() => _pulls.close();

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/signaling/settings')) {
      return _ocsResponse(200, <String, Object?>{
        'signalingMode': 'internal',
        'userId': 'fixture-user',
        'hideWarning': true,
        'server': '',
        'federation': null,
        'stunservers': <Object?>[],
        'turnservers': <Object?>[],
        'sipDialinInfo': '',
      });
    }
    if (request.method == 'POST') {
      final batch = jsonDecode(request.bodyFields['messages']!) as List<Object?>;
      for (final entry in batch.cast<Map<String, Object?>>()) {
        sent.add(jsonDecode(entry['fn']! as String) as Map<String, Object?>);
      }
      return _ocsResponse(200, const <Object?>[]);
    }
    _pullCount++;
    _pullWaiters.remove(_pullCount)?.complete();
    if (!await _next.moveNext()) {
      throw http.ClientException('signalling closed');
    }
    return _ocsResponse(200, _next.current);
  }
}

/// Records what a mesh peer connection was told and answers every offer.
final class _AnsweringEngine implements CallMediaEngine {
  final connections = <_AnsweringConnection>[];

  @override
  Future<CallLocalAudio> openMicrophone() async => _CameraForegroundAudio();

  @override
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio? audio,
    CallLocalVideo? video,
    bool sendOnly = false,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
    void Function(String type, Object? payload)? onStatusMessage,
  }) async {
    final connection = _AnsweringConnection();
    connections.add(connection);
    return connection;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _AnsweringConnection implements CallPeerConnection {
  final remoteDescriptions = <String>[];
  final candidates = <CallIceCandidate>[];

  @override
  Future<void> setRemoteDescription(CallSessionDescription description) async {
    remoteDescriptions.add(description.type);
  }

  @override
  Future<CallSessionDescription> createAnswer() async =>
      (type: 'answer', sdp: 'v=0 answer');

  @override
  Future<void> setLocalDescription(CallSessionDescription description) async {}

  @override
  Future<void> addIceCandidate(CallIceCandidate candidate) async {
    candidates.add(candidate);
  }

  @override
  bool sendStatus(String type, {Object? payload}) => false;

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DelayedMicrophone implements CallMediaEngine {
  _DelayedMicrophone(this.onOpen);
  final Future<void> Function() onOpen;
  @override
  Future<CallLocalAudio> openMicrophone() async {
    await onOpen();
    throw const CallMediaException(CallMediaError.microphonePermissionDenied);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ForegroundJoinFixture {
  _ForegroundJoinFixture(
    this.rest,
    this.coordinator,
    this.container,
    this.listener,
  );
  final _CallHarness rest;
  final CallSignalingCoordinator coordinator;
  final ProviderContainer container;
  final ProviderSubscription<Object?> listener;
  static const key = (accountId: 'account-a', roomToken: 'rooma123');
  CallJoinController get controller =>
      container.read(callJoinControllerProvider(key).notifier);

  static Future<_ForegroundJoinFixture> create(
    CallForegroundService foreground,
    CallMediaEngine engine, {
    bool holdSettings = false,
    CallTelecom telecom = const NoCallTelecom(),
    CallScreenShareService? screenShare,
    _CallHandler? onCall,
    Future<http.Response> Function(http.Request request)? signaling,
  }) async {
    final rest = await _CallHarness.create(
      onCall:
          onCall ??
          (request, _) async => _ocsResponse(
            200,
            request.method == 'GET'
                ? <Object?>[
                    _peer(token: 'rooma123', sessionId: 'session-rooma123'),
                  ]
                : <String, Object?>{},
          ),
    );
    rest.server.signalingEnabled = true;
    rest.server.signaling = signaling;
    if (holdSettings) rest.server.signalingGate = Completer<void>();
    await rest.accounts.updateCapabilities('account-a', {
      'signaling-v3',
    }, serverThemeColor: null);
    final coordinator = CallSignalingCoordinator(
      accounts: rest.accounts,
      sessions: CallSessionRepository(rest.database),
      credentials: rest.credentials,
      api: rest.api,
      refreshConversationSession: rest.refresh,
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(rest.database),
        accountRepositoryProvider.overrideWithValue(rest.accounts),
        chatRepositoryProvider.overrideWithValue(rest.chat),
        credentialVaultProvider.overrideWithValue(rest.credentials),
        nextcloudApiProvider.overrideWithValue(rest.api),
        callLifecycleServiceProvider.overrideWithValue(rest.service),
        callSignalingCoordinatorProvider.overrideWithValue(coordinator),
        callMediaEngineProvider.overrideWithValue(engine),
        callForegroundServiceProvider.overrideWithValue(foreground),
        callTelecomProvider.overrideWithValue(telecom),
        if (screenShare != null)
          callScreenShareServiceProvider.overrideWithValue(screenShare),
        callAudioInterruptionsProvider.overrideWithValue(
          const SilentCallAudioInterruptions(),
        ),
        windowActiveProvider.overrideWithValue(true),
      ],
    );
    container
        .read(chatRoomVisibilityProvider.notifier)
        .setVisible(Object(), key);
    final listener = container.listen(
      callJoinControllerProvider(key),
      (_, _) {},
    );
    await container.read(chatRoomSignalingProvider(key).future);
    return _ForegroundJoinFixture(rest, coordinator, container, listener);
  }

  Future<void> close() async {
    await controller.leave();
    listener.close();
    container.dispose();
    if (rest.server.signalingGate?.isCompleted == false) {
      rest.server.signalingGate!.complete();
    }
    await coordinator.dispose();
    await rest.service.dispose();
    await pumpEventQueue();
    await rest.dispose();
  }
}

/// An engine that can also open a screen, so a share really starts.
final class _ScreenShareEngine implements CallMediaEngine {
  final audio = _CameraForegroundAudio();
  final screen = _CameraForegroundVideo();

  @override
  Future<CallLocalAudio> openMicrophone() async => audio;

  @override
  Future<bool> requestScreenConsent() async => true;

  @override
  Future<CallLocalVideo> openScreen({CallScreenSource? source}) async => screen;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts what the platform was told about the screen-capture service.
final class _RecordingScreenShare implements CallScreenShareService {
  int starts = 0;
  int stops = 0;

  @override
  Future<bool> start() async {
    starts++;
    return true;
  }

  @override
  Future<void> stop() async => stops++;
}

final class _DisposalFailureEngine implements CallMediaEngine {
  _DisposalFailureEngine(this.failure);
  final StateError failure;

  @override
  Future<CallLocalAudio> openMicrophone() async =>
      _DisposalFailureAudio(failure);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DisposalFailureAudio implements CallLocalAudio {
  _DisposalFailureAudio(this.failure);
  final StateError failure;

  @override
  Stream<void> get routeChanges => const Stream.empty();
  @override
  Future<List<CallAudioRoute>> routes() async => [];
  @override
  Future<void> selectRoute(CallAudioRoute route) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setSpeakerphone(bool on) async {}
  @override
  Future<void> dispose() async => throw failure;
}
