part of 'call_lifecycle_service_test.dart';

void _registerCallJoinSessionRebindTests() {
  test(
    'media starts only after signaling has rebound to the renewed room',
    () async {
      var activations = 0;
      final harness = await _CallHarness.create(
        onActiveRoom: (request, _) async {
          if (request.method == 'DELETE') return _ocsResponse(200, null);
          return _activeRoomResponse('rooma123', 'active-${++activations}');
        },
        onCall: (request, index) async =>
            _ocsResponse(index == 0 ? 404 : 200, <String, Object?>{}),
      );
      harness.server.signalingEnabled = true;
      await harness.accounts.updateCapabilities('account-a', {
        'signaling-v3',
      }, serverThemeColor: null);
      final coordinator = CallSignalingCoordinator(
        accounts: harness.accounts,
        sessions: CallSessionRepository(harness.database),
        credentials: harness.credentials,
        api: harness.api,
        refreshConversationSession: harness.refresh,
      );
      const key = (accountId: 'account-a', roomToken: 'rooma123');
      late ProviderContainer container;
      String? mediaSession;
      final engine = _RebindMicrophone(() {
        mediaSession = container
            .read(chatRoomSignalingProvider(key))
            .valueOrNull
            ?.nextcloudSessionId;
      });
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(harness.database),
          accountRepositoryProvider.overrideWithValue(harness.accounts),
          chatRepositoryProvider.overrideWithValue(harness.chat),
          credentialVaultProvider.overrideWithValue(harness.credentials),
          nextcloudApiProvider.overrideWithValue(harness.api),
          callLifecycleServiceProvider.overrideWithValue(harness.service),
          callSignalingCoordinatorProvider.overrideWithValue(coordinator),
          callMediaEngineProvider.overrideWithValue(engine),
          callForegroundServiceProvider.overrideWithValue(
            const NoCallForegroundService(),
          ),
          callAudioInterruptionsProvider.overrideWithValue(
            const SilentCallAudioInterruptions(),
          ),
          windowActiveProvider.overrideWithValue(true),
        ],
      );
      addTearDown(() async {
        await container.read(callJoinControllerProvider(key).notifier).leave();
        container.dispose();
        await coordinator.dispose();
        await harness.service.dispose();
        await pumpEventQueue();
        await harness.dispose();
      });
      container
          .read(chatRoomVisibilityProvider.notifier)
          .setVisible(Object(), key);
      final listener = container.listen(
        callJoinControllerProvider(key),
        (_, _) {},
      );
      addTearDown(listener.close);
      final initial = await container.read(
        chatRoomSignalingProvider(key).future,
      );
      expect(initial.nextcloudSessionId, 'active-1');
      await container.read(callJoinControllerProvider(key).notifier).join();
      expect(mediaSession, 'active-2');
      final renewed = await container.read(
        chatRoomSignalingProvider(key).future,
      );
      expect(identical(initial.session, renewed.session), isFalse);
      expect(activations, 2);
      expect(
        harness.server.activeRoomRequests.where((r) => r.method == 'DELETE'),
        isEmpty,
      );
    },
  );
}

final class _RebindMicrophone implements CallMediaEngine {
  _RebindMicrophone(this.onOpen);
  final void Function() onOpen;

  @override
  Future<CallLocalAudio> openMicrophone() async {
    onOpen();
    throw const CallMediaException(CallMediaError.microphonePermissionDenied);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
