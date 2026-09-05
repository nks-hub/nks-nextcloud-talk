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
  return const WebRtcCallMediaEngine();
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
  if (defaultTargetPlatform == TargetPlatform.android) {
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
  channel.answered.listen((ring) {
    final key = (accountId: ring.accountId, roomToken: ring.roomToken);
    unawaited(ref.read(callJoinControllerProvider(key).notifier).join());
  });
  channel.ended.listen((ring) {
    if (ring == null) {
      return;
    }
    final key = (accountId: ring.accountId, roomToken: ring.roomToken);
    unawaited(ref.read(callJoinControllerProvider(key).notifier).leave());
  });
  return channel;
});
