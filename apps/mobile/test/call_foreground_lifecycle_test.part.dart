part of 'call_lifecycle_service_test.dart';

void _registerCallForegroundLifecycleTests() {
  test(
    'media disposal failure still stops its foreground owner and REST seat',
    () async {
      final foreground = _ForegroundCalls();
      final fixture = await _ForegroundJoinFixture.create(
        foreground,
        _DisposalFailureEngine(),
        holdSettings: true,
      );
      addTearDown(fixture.close);
      await fixture.controller.join();
      await expectLater(fixture.controller.leave(), throwsA(isA<StateError>()));
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
  _ForegroundCalls({this.startGate, this.stopGate, this.denied = false});
  final Future<void>? startGate;
  final Future<void>? stopGate;
  final bool denied;
  final started = <String>[], stopped = <String>[];
  final active = <String>{};
  final firstStart = Completer<void>(), firstStop = Completer<void>();

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
  }) async {
    final rest = await _CallHarness.create(
      onCall: (request, _) async => _ocsResponse(
        200,
        request.method == 'GET'
            ? <Object?>[_peer(token: 'rooma123', sessionId: 'session-rooma123')]
            : <String, Object?>{},
      ),
    );
    rest.server.signalingEnabled = true;
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

final class _DisposalFailureEngine implements CallMediaEngine {
  @override
  Future<CallLocalAudio> openMicrophone() async => _DisposalFailureAudio();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DisposalFailureAudio implements CallLocalAudio {
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
  Future<void> dispose() async =>
      throw StateError('synthetic audio disposal failure');
}
