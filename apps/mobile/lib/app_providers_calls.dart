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
