part of 'app_providers.dart';

final callTransportServiceProvider = Provider<CallTransportService>((ref) {
  return CallTransportService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

/// Resolves how a room's call is signalled. Kept out of the conversation
/// stream because it costs a request per room and only matters while an
/// ongoing call is actually on screen.
final callTransportProvider = FutureProvider.autoDispose
    .family<CallTransport, CallRoomKey>((ref, key) {
      return ref
          .watch(callTransportServiceProvider)
          .resolve(accountId: key.accountId, roomToken: key.roomToken);
    });

/// Whether a relay-only call is worth offering at all: true as soon as one
/// signed-in account's server hands out a TURN server.
///
/// The setting is app-wide while the answer is per server, so any server that
/// offers one keeps the switch. A server that cannot be asked counts as
/// offering one — see [CallTransportService.offersRelay].
/// `autoDispose`, and every dependency is READ rather than watched. The room
/// list is a live database stream whose rows change on every arriving message;
/// watching it would send a settings request per message for the rest of the
/// run, long after the settings screen was closed.
final callRelayOfferedProvider = FutureProvider.autoDispose<bool>((ref) async {
  final repository = ref.read(accountRepositoryProvider);
  final transport = ref.read(callTransportServiceProvider);
  for (final account in await repository.listAccounts()) {
    final rooms = await repository.watchConversations(account.id).first;
    if (rooms.isEmpty) {
      // Nobody to ask about: a freshly added account before its first sync
      // has no room to name in the request. Unknown counts as offered, the
      // same as a server that cannot be reached — hiding a working switch is
      // worse than showing one that may do nothing.
      return true;
    }
    if (await transport.offersRelay(
      accountId: account.id,
      roomToken: rooms.first.token,
    )) {
      return true;
    }
  }
  return false;
});

final callSessionRepositoryProvider = Provider<CallSessionRepository>((ref) {
  return CallSessionRepository(ref.watch(appDatabaseProvider));
});

final callSignalingCoordinatorProvider = Provider<CallSignalingCoordinator>((
  ref,
) {
  final coordinator = CallSignalingCoordinator(
    accounts: ref.watch(accountRepositoryProvider),
    sessions: ref.watch(callSessionRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    refreshConversationSession: ref
        .watch(callConversationSessionResolverProvider)
        .refresh,
  );
  ref.onDispose(() => unawaited(coordinator.dispose()));
  return coordinator;
});

final callLifecycleSessionRepositoryProvider =
    Provider<CallLifecycleSessionRepository>((ref) {
      return CallLifecycleSessionRepository(ref.watch(appDatabaseProvider));
    });

final callLifecyclePersistedProvider = FutureProvider.autoDispose
    .family<bool, CallRoomKey>((ref, key) {
      return ref
          .watch(callLifecycleSessionRepositoryProvider)
          .exists(accountId: key.accountId, roomToken: key.roomToken);
    });

final callConversationSessionResolverProvider =
    Provider<CallConversationSessionResolver>((ref) {
      return CallConversationSessionResolver(
        accounts: ref.watch(accountRepositoryProvider),
        conversations: ref.watch(conversationSyncServiceProvider),
      );
    });

final callLifecycleServiceProvider = Provider<CallLifecycleService>((ref) {
  final service = CallLifecycleService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    sessions: ref.watch(callLifecycleSessionRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    refreshConversationSession: ref
        .watch(callConversationSessionResolverProvider)
        .refresh,
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final callLifecycleControllerProvider = Provider<CallLifecycleController>((
  ref,
) {
  return CallLifecycleController(ref.watch(callLifecycleServiceProvider));
});

final callLifecycleStatusProvider = FutureProvider.autoDispose
    .family<CallLifecycleRoomStatus, CallRoomKey>((ref, key) async {
      try {
        return await ref.watch(callLifecycleControllerProvider).load(key);
      } finally {
        ref.invalidate(callLifecyclePersistedProvider(key));
      }
    });

/// The WebRTC engine behind call media. Overridden in tests so negotiation can
/// be driven without a platform channel.
final callMediaEngineProvider = Provider<CallMediaEngine>((ref) {
  return WebRtcCallMediaEngine(relayOnly: ref.watch(callRelayOnlyProvider));
});

/// Where a call hears that the system took its audio — an incoming telephone
/// call, an alarm. Without this the microphone keeps capturing through the
/// interruption, which the other participants hear.
final callAudioInterruptionsProvider = Provider<CallAudioInterruptions>((ref) {
  return const PlatformCallAudioInterruptions();
});

/// The small window a call shrinks into when the user leaves the app. Armed
/// only while the call screen is showing.
final callPictureInPictureProvider = Provider<CallPictureInPicture>((ref) {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return PlatformCallPictureInPicture();
  }
  return const UnavailableCallPictureInPicture();
});

/// The foreground service a screen capture needs on Android. Elsewhere it
/// answers "no service needed" and the capture stands on its own.
final callScreenShareServiceProvider = Provider<CallScreenShareService>((ref) {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return const PlatformCallScreenShareService();
  }
  return const NoCallScreenShareService();
});

/// Joining and leaving one room's call with audio.
final callJoinControllerProvider =
    AutoDisposeNotifierProviderFamily<
      CallJoinController,
      CallJoinState,
      CallRoomKey
    >(CallJoinController.new);

/// The system call lifecycle on Android. A joined call is registered with
/// Telecom, so the phone knows a call is up: a headset's hang-up button lands
/// here, and an incoming cellular call is arbitrated against the Talk call
/// rather than dropped on top of it.
///
/// Off Android this answers "no system call lifecycle" — iOS has CallKit,
/// which is [callKitChannelProvider] — and a call runs as it always did.
final callTelecomProvider = Provider<CallTelecom>((ref) {
  // `Platform`, not `defaultTargetPlatform`: this builds a channel and claims
  // its handler, which a test host has no binding for. Same reason
  // [callKitChannelProvider] asks the same way.
  if (!Platform.isAndroid) {
    return const NoCallTelecom();
  }
  final telecom = AndroidCallTelecom();
  ref.onDispose(telecom.dispose);
  bindSystemCallActions(ref, telecom);
  return telecom;
});

/// The system call screen on iOS: a VoIP push rings it while the app is not
/// running, and this turns what the user pressed there into the same join and
/// leave the in-app banner performs.
///
/// It also carries the PushKit token into the push registration — without
/// that token the proxy has nothing to send a call push to, so nothing rings
/// in the first place. `null` off iOS: CallKit is Apple's and macOS has no
/// PushKit at all.
final callKitChannelProvider = Provider<CallKitChannel?>((ref) {
  if (!Platform.isIOS) {
    return null;
  }
  final registration = ref.watch(applePushRegistrationCoordinatorProvider);
  if (registration == null) {
    return null;
  }
  final channel = CallKitChannel(onVoipToken: registration.installVoipToken);
  ref.onDispose(channel.dispose);
  unawaited(channel.checkLaunchVoipToken());
  bindSystemCallActions(ref, channel);
  return channel;
});

/// Routes what the platform's own call screen decided through the same join
/// and leave an in-app call uses — CallKit on iOS, Telecom on Android.
void bindSystemCallActions(Ref ref, SystemCallScreen<SystemCallRing> channel) {
  var disposed = false;
  final rings = <CallRoomKey, SystemCallRing>{};
  final listeners = <CallRoomKey, ProviderSubscription<CallJoinState>>{};

  void release(CallRoomKey key, SystemCallRing ring) {
    if (disposed || !identical(rings[key], ring)) return;
    rings.remove(key);
    listeners.remove(key)?.close();
    unawaited(channel.endCall(ring.callId));
  }

  Future<void> answer(SystemCallRing ring) async {
    final key = (accountId: ring.accountId, roomToken: ring.roomToken);
    rings[key] = ring;
    listeners.remove(key)?.close();
    // Native answers may precede the first Flutter call screen. Keep the
    // controller alive until this exact ring ends or the join is refused.
    listeners[key] = ref.listen(callJoinControllerProvider(key), (_, next) {
      if (next.phase == CallJoinPhase.failed ||
          next.phase == CallJoinPhase.idle) {
        release(key, ring);
      }
    });
    try {
      await ref.read(callJoinControllerProvider(key).notifier).join();
      if (disposed || !identical(rings[key], ring)) return;
      final phase = ref.read(callJoinControllerProvider(key)).phase;
      if (phase == CallJoinPhase.failed || phase == CallJoinPhase.idle) {
        release(key, ring);
      }
    } on Object {
      // An unexpected join failure must also release the native call screen.
      release(key, ring);
    }
  }

  final answered = channel.answered.listen((ring) {
    unawaited(answer(ring));
  });
  final ended = channel.ended.listen((ring) {
    if (ring == null) {
      rings.clear();
      for (final listener in listeners.values) {
        listener.close();
      }
      listeners.clear();
      return;
    }
    final key = (accountId: ring.accountId, roomToken: ring.roomToken);
    final current = rings[key];
    if (current != null && current.callId != ring.callId) return;
    rings.remove(key);
    listeners.remove(key)?.close();
    unawaited(ref.read(callJoinControllerProvider(key).notifier).leave());
  });
  ref.onDispose(() {
    disposed = true;
    rings.clear();
    unawaited(answered.cancel());
    unawaited(ended.cancel());
  });
}
