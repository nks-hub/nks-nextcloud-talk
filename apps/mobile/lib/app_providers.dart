import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart' show AppLifecycleListener, NavigatorObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'core/giphy_reference_load_coordinator.dart';
import 'core/connectivity_wake_source.dart';
import 'data/account_repository.dart';
import 'data/app_database.dart';
import 'data/attachment_repository.dart';
import 'data/chat_media_cache.dart';
import 'data/chat_media_repository.dart';
import 'data/chat_repository.dart';
import 'data/call_session_repository.dart';
import 'data/credential_vault.dart';
import 'data/conversation_avatar_repository.dart';
import 'data/thread_repository.dart';
import 'features/calls/call_lifecycle_controller.dart';
import 'features/calls/call_lifecycle_service.dart';
import 'features/calls/call_transport_service.dart';
import 'features/chat/attachment_service.dart';
import 'features/chat/chat_attachment_context.dart';
import 'features/chat/chat_message_actions_service.dart';
import 'features/chat/chat_service.dart';
import 'features/chat/outgoing_message_status.dart';
import 'features/chat/composer/giphy.dart';
import 'features/chat/composer/emoji_usage_store.dart';
import 'features/chat/composer/mention_suggestions.dart';
import 'features/conversations/conversation_sync_service.dart';
import 'features/newconversation/new_conversation_service.dart';
import 'features/search/message_search_service.dart';
import 'platform/media/voice_platform_adapters.dart';
import 'features/conversations/deep_link_bridge.dart';
import 'features/conversations/deep_link_coordinator.dart';
import 'features/onboarding/onboarding_coordinator.dart';
import 'features/profile/profile_service.dart';
import 'features/rooms/room_settings_service.dart';
import 'features/settings/account_removal_service.dart';
import 'features/settings/theme_preference.dart';
import 'features/threads/thread_management_service.dart';
import 'features/push/android_fcm_channel.dart';
import 'features/push/android_push_coordinator.dart';
import 'features/push/android_push_device_key_store.dart';
import 'features/push/android_push_transport.dart';
import 'features/push/android_web_push_bridge.dart';
import 'features/push/apple_push_channel.dart';
import 'features/push/apple_push_device_key_store.dart';
import 'features/push/apple_push_registration_coordinator.dart';
import 'features/push/client_push_coordinator.dart';
import 'features/push/client_push_session.dart';
import 'features/push/push_registration_coordinator.dart';
import 'network/attachment_transport.dart';
import 'network/nextcloud_api.dart';
import 'platform/media/durable_attachment_source_store.dart';

final connectivityWakeEventsProvider = Provider<Stream<void>>(
  (ref) => ConnectivityWakeSource().events,
);

final appLifecycleResumeEventsProvider = Provider<Stream<void>>((ref) {
  final controller = StreamController<void>.broadcast(sync: true);
  final listener = AppLifecycleListener(
    onResume: () {
      if (!controller.isClosed) {
        controller.add(null);
      }
    },
  );
  ref.onDispose(() {
    listener.dispose();
    unawaited(controller.close());
  });
  return controller.stream;
});

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(ref.watch(appDatabaseProvider));
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(ref.watch(appDatabaseProvider));
});

final threadRepositoryProvider = Provider<ThreadRepository>((ref) {
  return ThreadRepository(ref.watch(appDatabaseProvider));
});

final attachmentRepositoryProvider = Provider<AttachmentRepository>((ref) {
  return AttachmentRepository(ref.watch(appDatabaseProvider));
});

final credentialVaultProvider = Provider<CredentialVault>((ref) {
  return SecureCredentialVault();
});

final emojiUsageStoreProvider = Provider<EmojiUsageStore>((ref) {
  return FileEmojiUsageStore();
});

final conversationAvatarRepositoryProvider =
    Provider<ConversationAvatarRepository>((ref) {
      return ConversationAvatarRepository(
        database: ref.watch(appDatabaseProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
      );
    });

final chatMediaRepositoryProvider = Provider<ChatMediaRepository>((ref) {
  final repository = ChatMediaRepository(ref.watch(credentialVaultProvider));
  ref.onDispose(repository.close);
  return repository;
});

final nextcloudApiProvider = Provider<HttpNextcloudApi>((ref) {
  final api = HttpNextcloudApi();
  ref.onDispose(api.close);
  return api;
});

final loginPageLauncherProvider = Provider<LoginPageLauncher>((ref) {
  return ExternalLoginPageLauncher();
});

final onboardingCoordinatorProvider = Provider<OnboardingCoordinator>((ref) {
  return OnboardingCoordinator(
    api: ref.watch(nextcloudApiProvider),
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    launcher: ref.watch(loginPageLauncherProvider),
  );
});

final profileServiceProvider = Provider<ProfileService>((ref) {
  return ProfileService(
    ref.watch(accountRepositoryProvider),
    ref.watch(credentialVaultProvider),
    ref.watch(nextcloudApiProvider),
  );
});

final conversationSyncServiceProvider = Provider<ConversationSyncService>((
  ref,
) {
  return ConversationSyncService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

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
  return CallLifecycleService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    sessions: ref.watch(callLifecycleSessionRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    refreshConversationSession: ref
        .watch(callConversationSessionResolverProvider)
        .refresh,
  );
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

final newConversationServiceProvider = Provider<NewConversationService>((ref) {
  return HttpNewConversationService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final messageSearchServiceProvider = Provider<MessageSearchService>((ref) {
  return HttpMessageSearchService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final androidWebPushPlatformProvider = Provider<AndroidWebPushPlatform?>((ref) {
  if (!Platform.isAndroid) {
    return null;
  }
  final bridge = AndroidWebPushBridge();
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});

/// Nextcloud's own live channel, running for every signed-in account.
///
/// `notify_push` reaches every platform the app builds for, which is what
/// makes it worth having next to the Android-only Web Push path: it delivers
/// the moment a notification appears rather than at the next poll. It never
/// replaces Web Push, which is the only channel that can wake a killed app.
/// Whether the live channel should run at all.
///
/// Widget tests mount the app without a server behind it, and a socket that
/// starts there would reach for the account store and the network for no
/// reason. Production leaves this on.
final clientPushEnabledProvider = Provider<bool>((ref) => true);

final clientPushCoordinatorProvider = Provider<ClientPushCoordinator?>((ref) {
  if (!ref.watch(clientPushEnabledProvider)) {
    return null;
  }
  final accounts = ref.watch(accountRepositoryProvider);
  final credentials = ref.watch(credentialVaultProvider);
  final api = ref.watch(nextcloudApiProvider);

  Future<({StoredAccount account, String appPassword})?> credentialsFor(
    String accountId,
  ) async {
    final account = await accounts.getAccount(accountId);
    if (account == null) {
      return null;
    }
    final appPassword = await credentials.readAppPassword(accountId);
    if (appPassword == null) {
      return null;
    }
    return (account: account, appPassword: appPassword);
  }

  final coordinator = ClientPushCoordinator(
    resolve: (accountId) async {
      final resolved = await credentialsFor(accountId);
      if (resolved == null) {
        return null;
      }
      final capabilities = await api.getAuthenticatedCapabilities(
        server: ServerBase.parse(resolved.account.serverUrl),
        loginName: resolved.account.loginName,
        appPassword: resolved.appPassword,
      );
      return readClientPushEndpoints(capabilities.capabilities);
    },
    fetchToken: (accountId, endpoints) async {
      final resolved = await credentialsFor(accountId);
      if (resolved == null) {
        throw const ClientPushException(ClientPushFailure.rejected);
      }
      return api.fetchClientPushPreAuthToken(
        server: ServerBase.parse(resolved.account.serverUrl),
        loginName: resolved.account.loginName,
        appPassword: resolved.appPassword,
        preAuth: endpoints.preAuth,
      );
    },
    connector: const IoClientPushConnector(),
    onWakeUp: (accountId) =>
        unawaited(ref.read(conversationSyncServiceProvider).sync(accountId)),
  );
  ref.onDispose(() => unawaited(coordinator.dispose()));

  // Following the same account list the UI shows keeps the sockets in step
  // with sign-in and sign-out without a second place having to remember it,
  // and without reaching for the account store before an account exists.
  ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
    previous,
    next,
  ) {
    final signedIn = next.valueOrNull;
    if (signedIn == null) {
      return;
    }
    final live = signedIn.map((account) => account.id).toSet();
    for (final accountId in live) {
      coordinator.follow(accountId);
    }
    for (final accountId in previous?.valueOrNull
            ?.map((account) => account.id)
            .where((id) => !live.contains(id)) ??
        const <String>[]) {
      unawaited(coordinator.unfollow(accountId));
    }
  }, fireImmediately: true);
  return coordinator;
});

final androidPushTransportStoreProvider = Provider<AndroidPushTransportStore>((
  ref,
) {
  return FileAndroidPushTransportStore();
});

/// Which of the two Android push paths is live. Switchable at runtime, no new
/// build needed: the native path is our own proxy, Web Push over UnifiedPush
/// stays as the fallback.
final androidPushTransportProvider =
    NotifierProvider<AndroidPushTransportController, AndroidPushTransport>(
      AndroidPushTransportController.new,
    );

final class AndroidPushTransportController extends Notifier<AndroidPushTransport> {
  @override
  AndroidPushTransport build() {
    unawaited(_load());
    return androidPushTransportDefault;
  }

  Future<void> _load() async {
    final stored = await ref.read(androidPushTransportStoreProvider).read();
    if (state != stored) {
      state = stored;
    }
  }

  /// Hands the device over to [transport]. The old path is revoked first, so
  /// the two never hold a registration for this device at the same time; a
  /// failed revocation leaves the old path in force and rethrows.
  ///
  /// [revoke] is supplied by the caller rather than read here on purpose: both
  /// coordinator providers watch this notifier, so reading them back from
  /// inside it is a dependency cycle and Riverpod refuses it at the first
  /// switch. [revokeAndroidPushTransport] is the implementation to pass.
  Future<void> select(
    AndroidPushTransport transport, {
    required Future<void> Function(AndroidPushTransport live) revoke,
  }) async {
    state = await AndroidPushTransportSwitch(
      store: ref.read(androidPushTransportStoreProvider),
      revoke: revoke,
    ).select(transport, current: state);
  }
}

/// Unregisters this device from [live] — at Nextcloud and at whichever gateway
/// that transport uses. Call it from outside the provider graph (a widget) and
/// hand it to [AndroidPushTransportController.select].
Future<void> revokeAndroidPushTransport(
  WidgetRef ref,
  AndroidPushTransport live,
) async {
  switch (live) {
    case AndroidPushTransport.webPush:
      await ref.read(androidPushCoordinatorProvider)?.revokeAllRegistrations();
    case AndroidPushTransport.proxy:
      await ref.read(androidPushRegistrationCoordinatorProvider)?.unfollowAll();
  }
}

/// Runs on both transports, but only subscribes to Web Push on its own.
///
/// The notification a user taps and the reply they type come back through the
/// native layer whichever transport delivered them, so this coordinator has to
/// be alive either way; `subscribes` is what tells it whether the Web Push
/// registration is also its job.
final androidPushCoordinatorProvider = Provider<AndroidPushCoordinator?>((ref) {
  final platform = ref.watch(androidWebPushPlatformProvider);
  if (platform == null) {
    return null;
  }
  final subscribes =
      ref.watch(androidPushTransportProvider) == AndroidPushTransport.webPush;
  final coordinator = AndroidPushCoordinator(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    platform: platform,
    subscribes: subscribes,
    onWakeUp: (accountId) =>
        ref.read(conversationSyncServiceProvider).sync(accountId),
    onNotificationAction: (action) => _runNotificationAction(ref, action),
    reconciliationWakeEvents: <Stream<void>>[
      ref.watch(connectivityWakeEventsProvider),
      ref.watch(appLifecycleResumeEventsProvider),
    ],
    retryableError: (error) =>
        error is ConversationSyncException &&
        switch (error.code) {
          ConversationSyncError.network ||
          ConversationSyncError.rateLimited ||
          ConversationSyncError.serviceUnavailable => true,
          _ => false,
        },
  );
  ref.onDispose(() => unawaited(coordinator.close()));
  unawaited(coordinator.start());
  return coordinator;
});

/// Registers this Android device for push v2 against our own proxy — the same
/// wire contract iOS uses, which keeps the public UnifiedPush rewrite gateway
/// out of the path entirely.
///
/// Null off Android and while the Web Push fallback is selected.
///
/// NOT YET DELIVERING: nothing calls `installToken`, because the app has no
/// FCM integration to get a token from. Without a provider token the state
/// machine plans no effect at all, so this registers nowhere until the
/// Firebase project is wired in. Kept honest by a test.
final androidPushRegistrationCoordinatorProvider =
    Provider<PushRegistrationCoordinator?>((ref) {
      if (!Platform.isAndroid ||
          ref.watch(androidPushTransportProvider) !=
              AndroidPushTransport.proxy) {
        return null;
      }
      final coordinator = PushRegistrationCoordinator(
        accounts: ref.watch(accountRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        keyStore: AndroidPushDeviceKeyChannel(),
        gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
        tokenHandlePrefix: 'fcm-token',
      );
      final fcm = AndroidFcmChannel(onToken: coordinator.installToken);
      final platform = ref.watch(androidWebPushPlatformProvider);
      ref.onDispose(() {
        fcm.dispose();
        unawaited(coordinator.dispose());
      });

      // Same account-following shape as the Apple and Client Push
      // coordinators: track whoever the UI currently shows.
      ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
        previous,
        next,
      ) {
        final signedIn = next.valueOrNull;
        if (signedIn == null) {
          return;
        }
        final live = signedIn.map((account) => account.id).toSet();
        for (final accountId in live) {
          unawaited(coordinator.follow(accountId));
        }
        for (final accountId in previous?.valueOrNull
                ?.map((account) => account.id)
                .where((id) => !live.contains(id)) ??
            const <String>[]) {
          unawaited(coordinator.unfollow(accountId));
        }
        // Always, including when the last account goes: a delivery resolves
        // its account by trying each key, so a stale list would keep trying a
        // key that no longer exists.
        unawaited(fcm.setAccounts(live));
        if (live.isEmpty) {
          return;
        }
        // Only once somebody is signed in: a token, and the permission to
        // show what arrives with it, are both pointless before that. The
        // permission call is the same one the Web Push path uses — it is an
        // activity-level Android 13 prompt, not a Web Push detail.
        unawaited(_ensureAndroidNotificationPermission(platform));
        unawaited(fcm.start());
      }, fireImmediately: true);
      return coordinator;
    });

Future<void> _ensureAndroidNotificationPermission(
  AndroidWebPushPlatform? platform,
) async {
  if (platform == null) {
    return;
  }
  if (await platform.getNotificationPermission() ==
      AndroidNotificationPermission.notDetermined) {
    await platform.requestNotificationPermission();
  }
}

/// Asks iOS for notification permission, keeps the APNs device token, and
/// hands every token to [applePushRegistrationCoordinatorProvider] so it can
/// register (or refresh) push v2.
///
/// No macOS equivalent exists: `AppDelegate.swift` only exposes this channel
/// on the iOS runner, and adding a native macOS side is out of scope here.
final applePushCoordinatorProvider = Provider<ApplePushCoordinator?>((ref) {
  if (!Platform.isIOS) {
    return null;
  }
  final registration = ref.watch(applePushRegistrationCoordinatorProvider);
  final coordinator = ApplePushCoordinator(onToken: registration?.installToken);
  ref.onDispose(coordinator.dispose);

  // Asking only makes sense once someone is signed in, and only needs to
  // happen once per session — the coordinator itself guards against asking
  // twice, this just avoids firing before there is any account at all.
  ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
    previous,
    next,
  ) {
    final signedIn = next.valueOrNull;
    if (signedIn == null || signedIn.isEmpty) {
      return;
    }
    unawaited(coordinator.requestPermissionAndLogToken());
  }, fireImmediately: true);

  return coordinator;
});

/// Registers this device for Nextcloud push v2 and the `nks-talk-notify`
/// APNs proxy — see that project's README for the wire contract each effect
/// executes. `null` off iOS: there is no APNs token or Keychain device-key
/// channel to register without it.
final applePushRegistrationCoordinatorProvider =
    Provider<ApplePushRegistrationCoordinator?>((ref) {
      if (!Platform.isIOS) {
        return null;
      }
      final coordinator = ApplePushRegistrationCoordinator(
        accounts: ref.watch(accountRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        keyStore: ApplePushDeviceKeyChannel(),
        gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
      );
      ref.onDispose(() => unawaited(coordinator.dispose()));

      // Same account-following shape as clientPushCoordinatorProvider: track
      // whoever the UI currently shows, without a second place having to
      // remember the account list itself.
      ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
        previous,
        next,
      ) {
        final signedIn = next.valueOrNull;
        if (signedIn == null) {
          return;
        }
        final live = signedIn.map((account) => account.id).toSet();
        for (final accountId in live) {
          unawaited(coordinator.follow(accountId));
        }
        for (final accountId in previous?.valueOrNull
                ?.map((account) => account.id)
                .where((id) => !live.contains(id)) ??
            const <String>[]) {
          unawaited(coordinator.unfollow(accountId));
        }
      }, fireImmediately: true);
      return coordinator;
    });

/// Executes a notification-shade action for exactly `action.accountId`.
///
/// A reply goes through [ChatService.sendText] and therefore through the
/// durable text-send outbox: the same `referenceId` correlation, the same
/// ambiguous-send rules and the same visible retry entry in the room as a
/// reply typed in the composer. Sending straight from the notification would
/// be a second, uncorrelated POST and the documented duplicate risk of
/// `docs/architecture/chat-messages-api.md` would apply to it.
Future<AndroidPushActionOutcome> _runNotificationAction(
  Ref ref,
  AndroidNotificationAction action,
) async {
  try {
    switch (action.kind) {
      case AndroidNotificationActionKind.reply:
        await ref
            .read(chatServiceProvider)
            .sendText(
              accountId: action.accountId,
              roomToken: action.roomToken,
              message: action.replyText ?? '',
            );
      case AndroidNotificationActionKind.markRead:
        // The read marker is an explicit message id, so the cached room has
        // to know the newest message before the marker can move.
        await ref.read(conversationSyncServiceProvider).sync(action.accountId);
        await ref
            .read(roomSettingsServiceProvider)
            .markConversationRead(
              accountId: action.accountId,
              roomToken: action.roomToken,
            );
        await ref.read(conversationSyncServiceProvider).sync(action.accountId);
    }
    return AndroidPushActionOutcome.completed;
  } on ChatServiceException catch (error) {
    return switch (error.code) {
      ChatServiceError.network ||
      ChatServiceError.rateLimited ||
      ChatServiceError.serviceUnavailable ||
      ChatServiceError.talkUnavailable => AndroidPushActionOutcome.retry,
      _ => AndroidPushActionOutcome.failed,
    };
  } on RoomSettingsException catch (error) {
    return switch (error.code) {
      RoomSettingsError.network ||
      RoomSettingsError.rateLimited ||
      RoomSettingsError.serviceUnavailable => AndroidPushActionOutcome.retry,
      _ => AndroidPushActionOutcome.failed,
    };
  } on NextcloudApiException catch (error) {
    return switch (error.code) {
      NextcloudApiError.network ||
      NextcloudApiError.timeout => AndroidPushActionOutcome.retry,
      _ => AndroidPushActionOutcome.failed,
    };
  }
}

final deepLinkPlatformProvider = Provider<DeepLinkPlatform?>((ref) {
  if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
    return null;
  }
  final bridge = DeepLinkBridge();
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});

final deepLinkResolverProvider = Provider<DeepLinkResolver>((ref) {
  return DeepLinkResolver(ref.watch(accountRepositoryProvider));
});

final deepLinkCoordinatorProvider = Provider<DeepLinkCoordinator?>((ref) {
  final platform = ref.watch(deepLinkPlatformProvider);
  if (platform == null) {
    return null;
  }
  final coordinator = DeepLinkCoordinator(
    platform: platform,
    resolver: () => ref.read(deepLinkResolverProvider),
  );
  ref.onDispose(() => unawaited(coordinator.close()));
  unawaited(coordinator.start());
  return coordinator;
});

final chatServiceProvider = Provider<ChatService>((ref) {
  return ChatService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final threadManagementServiceProvider = Provider<ThreadManagementService>((
  ref,
) {
  return ThreadManagementService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    threads: ref.watch(threadRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final attachmentSourceProvider = FutureProvider<DurableAttachmentSourceStore>((
  ref,
) {
  return DurableAttachmentSourceStore.openApplicationSupport();
});

final attachmentUploadPolicyProvider = Provider<AttachmentUploadPolicy>((ref) {
  return AttachmentUploadPolicy(
    normalUploadMaximumBytes: 1024 * 1024,
    chunkSizeBytes: 1024000,
  );
});

final chatMessageActionsServiceProvider = Provider<ChatMessageActionsService>((
  ref,
) {
  return ChatMessageActionsService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final chatMessageActionsProfileProvider = FutureProvider.autoDispose
    .family<RichChatCapabilityProfile, ChatRoomProviderKey>((ref, key) async {
      return ref
          .watch(chatMessageActionsServiceProvider)
          .resolveProfile(accountId: key.accountId, roomToken: key.roomToken);
    });

final chatAttachmentContextResolverProvider =
    Provider<ChatAttachmentContextResolver>((ref) {
      return ChatAttachmentContextResolver(
        accounts: ref.watch(accountRepositoryProvider),
        chat: ref.watch(chatRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        uploadPolicy: ref.watch(attachmentUploadPolicyProvider),
      );
    });

final attachmentServiceProvider = FutureProvider<AttachmentService>((
  ref,
) async {
  final source = await ref.watch(attachmentSourceProvider.future);
  final chat = ref.watch(chatServiceProvider);
  final service = AttachmentService(
    repository: ref.watch(attachmentRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    releaseSource: (attachment) => source.discard(attachment.handle),
    transport: HttpAttachmentTransport(
      client: http.Client(),
      sourceProvider: source,
    ),
    catchUpConfirmation:
        ({required accountId, required roomToken, required threadId}) =>
            chat.catchUpRoom(
              accountId: accountId.value,
              roomToken: roomToken.value,
              threadId: threadId,
            ),
  );
  ref.onDispose(() {
    unawaited(service.close());
  });
  await service.ready;
  return service;
});

typedef GiphyRepositoryFactory =
    HttpGiphyRepository Function({
      required ServerBase server,
      required GiphyAuthorization authorization,
    });

final giphyRepositoryFactoryProvider = Provider<GiphyRepositoryFactory>((ref) {
  return ({
    required ServerBase server,
    required GiphyAuthorization authorization,
  }) => HttpGiphyRepository(server: server, authorization: authorization);
});

final giphyRepositoryProvider = FutureProvider.autoDispose
    .family<HttpGiphyRepository?, String>((ref, accountId) async {
      HttpGiphyRepository? repository;
      var disposed = false;
      ref.onDispose(() {
        disposed = true;
        repository?.close();
        repository = null;
      });
      final accounts = ref.watch(accountRepositoryProvider);
      final credentials = ref.watch(credentialVaultProvider);
      final api = ref.watch(nextcloudApiProvider);
      final createRepository = ref.watch(giphyRepositoryFactoryProvider);

      void ensureActive() {
        if (disposed) {
          throw const GiphyException(GiphyError.cancelled);
        }
      }

      final account = await accounts.getAccount(accountId);
      ensureActive();
      if (account == null) {
        throw const GiphyException(GiphyError.integrationUnavailable);
      }
      final appPassword = await credentials.readAppPassword(accountId);
      ensureActive();
      if (appPassword == null) {
        throw const GiphyException(GiphyError.integrationUnavailable);
      }
      final server = ServerBase.parse(account.serverUrl);
      final capabilities = await api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
      );
      ensureActive();
      final availability = GiphyAvailability.fromCapabilities(capabilities);
      if (availability.state == GiphyAvailabilityState.unavailable) {
        return null;
      }
      final createdRepository = createRepository(
        server: server,
        authorization: GiphyAuthorization(
          loginName: account.loginName,
          appPassword: appPassword,
        ),
      );
      repository = createdRepository;
      if (availability.shouldProbe) {
        try {
          await createdRepository.probeAvailability();
          ensureActive();
        } on GiphyException catch (error) {
          createdRepository.close();
          repository = null;
          if (disposed) {
            throw const GiphyException(GiphyError.cancelled);
          }
          if (error.error == GiphyError.integrationUnavailable) {
            return null;
          }
          rethrow;
        } on Object {
          createdRepository.close();
          repository = null;
          if (disposed) {
            throw const GiphyException(GiphyError.cancelled);
          }
          rethrow;
        }
      }
      return repository;
    });

final giphyReferenceLoadCoordinatorProvider =
    Provider<GiphyReferenceLoadCoordinator<GiphyReferenceMedia>>((ref) {
      return GiphyReferenceLoadCoordinator<GiphyReferenceMedia>(
        byteSizeOf: (media) => media.body.lengthInBytes,
      );
    });

final giphyReferenceMediaProvider = FutureProvider.autoDispose
    .family<GiphyReferenceMedia, GiphyReferenceRequest>((ref, request) async {
      final abort = Completer<void>();
      final coordinator = ref.watch(giphyReferenceLoadCoordinatorProvider);
      ref.onDispose(() {
        if (!abort.isCompleted) {
          abort.complete();
        }
      });
      final repository = await ref.watch(
        giphyRepositoryProvider(request.accountId).future,
      );
      if (repository == null) {
        throw const GiphyException(GiphyError.integrationUnavailable);
      }
      final media = await coordinator.load(
        accountId: request.accountId,
        resourceUrl: request.resourceUrl,
        loader: () => repository.loadReference(
          request.resourceUrl,
          abortTrigger: abort.future,
        ),
      );
      // Scrolling a GIF out of view used to dispose this provider and the
      // repository behind it, so scrolling back re-ran the whole capabilities
      // round trip before the already cached bytes were even consulted. The
      // keep-alive lives exactly as long as the coordinator keeps the bytes,
      // so retention stays inside the cache budget it already enforces.
      final link = ref.keepAlive();
      coordinator.retainWhileCached(
        accountId: request.accountId,
        resourceUrl: request.resourceUrl,
        release: link.close,
      );
      return media;
    });

final accountsProvider = StreamProvider<List<StoredAccount>>((ref) {
  ref.watch(attachmentServiceProvider);
  return ref.watch(accountRepositoryProvider).watchAccounts();
});

final selectedAccountProvider = StreamProvider<StoredAccount?>((ref) {
  return ref.watch(accountRepositoryProvider).watchSelectedAccount();
});

final conversationsProvider =
    StreamProvider.family<List<CachedConversation>, String>((ref, accountId) {
      return ref.watch(accountRepositoryProvider).watchConversations(accountId);
    });

typedef ChatRoomProviderKey = ({
  String accountId,
  String roomToken,
  int? threadId,
});

typedef ThreadRoomProviderKey = ({String accountId, String roomToken});

typedef ThreadProviderKey = ({
  String accountId,
  String roomToken,
  int threadId,
});

final recentThreadsProvider = StreamProvider.autoDispose
    .family<List<CachedThread>, ThreadRoomProviderKey>((ref, key) {
      return ref
          .watch(threadRepositoryProvider)
          .watchRecent(accountId: key.accountId, roomToken: key.roomToken);
    });

final subscribedThreadsProvider = StreamProvider.autoDispose
    .family<List<CachedThread>, String>((ref, accountId) {
      return ref.watch(threadRepositoryProvider).watchSubscribed(accountId);
    });

final threadDetailProvider = StreamProvider.autoDispose
    .family<CachedThread?, ThreadProviderKey>((ref, key) {
      return ref
          .watch(threadRepositoryProvider)
          .watch(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });

typedef ChatAttachmentDependencies = ({
  DurableAttachmentSourceStore source,
  AttachmentService service,
  ChatAttachmentContextResolver resolver,
  AttachmentCapabilityProfile profile,
});

final chatAttachmentDependenciesProvider = FutureProvider.autoDispose
    .family<ChatAttachmentDependencies, ChatRoomProviderKey>((ref, key) async {
      final source = await ref.watch(attachmentSourceProvider.future);
      final service = await ref.watch(attachmentServiceProvider.future);
      final resolver = ref.watch(chatAttachmentContextResolverProvider);
      final profile = await resolver.resolveProfile(
        accountId: AccountId.parse(key.accountId),
        roomToken: ConversationToken.parse(key.roomToken, path: r'$.roomToken'),
      );
      return (
        source: source,
        service: service,
        resolver: resolver,
        profile: profile,
      );
    });

typedef MentionSuggestionsRoomKey = ({String accountId, String roomToken});

/// Resolves the account, room and freshly fetched capabilities needed to
/// query `@`-mention suggestions. A failure here (missing account, missing
/// credentials, capabilities unavailable, mentions unsupported by the room)
/// just leaves mentions unavailable for this composer session; the chat
/// pane's own sync error handling already covers the underlying account and
/// connectivity problems.
final mentionSuggestionSourceProvider = FutureProvider.autoDispose
    .family<MentionSuggestionSource, MentionSuggestionsRoomKey>((
      ref,
      key,
    ) async {
      final accounts = ref.watch(accountRepositoryProvider);
      final chat = ref.watch(chatRepositoryProvider);
      final credentials = ref.watch(credentialVaultProvider);
      final api = ref.watch(nextcloudApiProvider);

      final account = await accounts.getAccount(key.accountId);
      if (account == null) {
        throw const MentionSuggestionException(
          MentionSuggestionError.unsupported,
        );
      }
      final conversation = await chat.getConversation(
        accountId: key.accountId,
        roomToken: key.roomToken,
      );
      if (conversation == null) {
        throw const MentionSuggestionException(
          MentionSuggestionError.unsupported,
        );
      }
      final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
      final appPassword = await credentials.readAppPassword(key.accountId);
      if (appPassword == null || appPassword.isEmpty) {
        throw const MentionSuggestionException(
          MentionSuggestionError.unsupported,
        );
      }
      final server = ServerBase.parse(account.serverUrl);
      final capabilities = await api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
      );
      if (!capabilities.hasTalk) {
        throw const MentionSuggestionException(
          MentionSuggestionError.unsupported,
        );
      }
      final rawSpreed = capabilities.capabilities['spreed'];
      final spreed = rawSpreed is Map<String, Object?>
          ? rawSpreed
          : const <String, Object?>{};
      final role = participantRoleFor(room.participantType);
      final profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: spreed['features'] ?? const <Object?>[],
        talkLocalFeatures: spreed['features-local'] ?? const <Object?>[],
        federated: room.isFederated,
        moderator:
            role == ParticipantRole.moderator ||
            role == ParticipantRole.guestModerator,
        // The effective permission for this user, not the per-attendee
        // override: `attendeePermissions` is 0 whenever no override is
        // set, which is the normal case and would gate away every
        // permission-guarded action, reactions included.
        participantPermissions: room.permissions,
      );
      return HttpMentionSuggestionSource(
        accountId: AccountId.parse(key.accountId),
        server: server,
        roomToken: ConversationToken.parse(key.roomToken, path: r'$.roomToken'),
        profile: profile,
        loginName: account.loginName,
        appPassword: appPassword,
        api: api,
      );
    });

@immutable
final class ConversationAvatarProviderKey {
  const ConversationAvatarProviderKey({
    required this.account,
    required this.uri,
    required this.versioned,
  });

  final StoredAccount account;
  final Uri uri;
  final bool versioned;

  @override
  int get hashCode => Object.hash(
    account.id,
    account.serverUrl,
    account.loginName,
    uri,
    versioned,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationAvatarProviderKey &&
          other.account.id == account.id &&
          other.account.serverUrl == account.serverUrl &&
          other.account.loginName == account.loginName &&
          other.uri == uri &&
          other.versioned == versioned);
}

typedef ChatMediaProviderKey = ({StoredAccount account, Uri uri});

final conversationAvatarProvider = FutureProvider.autoDispose
    .family<ConversationAvatarImage?, ConversationAvatarProviderKey>((
      ref,
      key,
    ) {
      return ref
          .watch(conversationAvatarRepositoryProvider)
          .load(account: key.account, uri: key.uri, versioned: key.versioned);
    });

final accountRemovalServiceProvider = Provider<AccountRemovalService>((ref) {
  return AccountRemovalService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    mediaCache: ref.watch(chatMediaCacheProvider),
    mediaDiskCache: ref.watch(chatMediaDiskCacheProvider),
    emojiUsage: ref.watch(emojiUsageStoreProvider),
    voiceDirectory: ref.watch(chatVoiceCacheDirectoryProvider),
    chatAttachmentDirectory: getApplicationCacheDirectory,
    attachmentSources: () => ref.read(attachmentSourceProvider.future),
    onRemovalStarted: (accountId) async {
      await ref.read(androidPushCoordinatorProvider)?.suspendAccount(accountId);
    },
  );
});

/// Navigator observers contributed by telemetry, empty in every build that
/// has no telemetry configured. Overridden once at startup so the widget tree
/// never has to know whether an SDK is present.
final telemetryNavigatorObserversProvider = Provider<List<NavigatorObserver>>(
  (ref) => const [],
);

final themePreferenceStoreProvider = Provider<ThemePreferenceStore>((ref) {
  return FileThemePreferenceStore();
});

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

final class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    unawaited(_load());
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final stored = await ref.read(themePreferenceStoreProvider).read();
    if (state != stored) {
      state = stored;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await ref.read(themePreferenceStoreProvider).write(mode);
  }
}

final chatMediaCacheProvider = Provider<ChatMediaCache>((ref) {
  return ChatMediaCache();
});

/// Previews are chat content, so they stay in the private app cache directory
/// that `allowBackup="false"` and the platform sandbox already cover.
final chatMediaDiskCacheProvider = Provider<ChatMediaDiskCache>((ref) {
  return ChatMediaDiskCache(
    rootDirectory: () async => Directory(
      '${(await getApplicationCacheDirectory()).path}'
      '${Platform.pathSeparator}previews',
    ),
  );
});

final chatMediaProvider = FutureProvider.autoDispose
    .family<ChatMediaImage?, ChatMediaProviderKey>((ref, key) async {
      final cache = ref.watch(chatMediaCacheProvider);
      final cacheKey = ChatMediaCache.keyOf(
        accountId: key.account.id,
        uri: key.uri,
      );
      final cached = cache.read(cacheKey);
      if (cached != null) {
        return cached;
      }
      final disk = ref.watch(chatMediaDiskCacheProvider);
      final persisted = await disk.read(
        accountId: key.account.id,
        uri: key.uri,
      );
      if (persisted != null) {
        cache.write(cacheKey, persisted);
        return persisted;
      }
      final loaded = await ref
          .watch(chatMediaRepositoryProvider)
          .loadPreview(account: key.account, uri: key.uri);
      if (loaded != null) {
        cache.write(cacheKey, loaded);
        await disk.write(
          accountId: key.account.id,
          uri: key.uri,
          image: loaded,
        );
      }
      return loaded;
    });

typedef ChatVoiceProviderKey = ({
  StoredAccount account,
  Uri uri,
  int messageId,
});

/// Player a chat bubble uses for a voice message. Injected so widget tests can
/// drive playback without a platform audio session.
final chatVoicePlaybackBackendProvider =
    Provider<VoicePlaybackBackend Function()>(
      (ref) => AudioplayersVoicePlaybackBackend.new,
    );

/// Where downloaded voice messages are materialised. Shared with account
/// removal so both sides agree on the directory that has to be cleaned.
final chatVoiceCacheDirectoryProvider = Provider<Future<Directory> Function()>((
  ref,
) {
  return () async => Directory(
    '${(await getApplicationCacheDirectory()).path}'
    '${Platform.pathSeparator}voice',
  );
});

/// A voice message is fetched once per room visit and materialised in the
/// app cache directory so a platform player can open it.
final chatVoiceFileProvider = FutureProvider.autoDispose
    .family<ChatVoiceFile, ChatVoiceProviderKey>((ref, key) async {
      final directory = await ref.watch(chatVoiceCacheDirectoryProvider)();
      final file = await ref
          .watch(chatMediaRepositoryProvider)
          .loadVoiceFile(
            account: key.account,
            uri: key.uri,
            directory: directory,
            cacheKey: chatVoiceCacheKey(
              accountId: key.account.id,
              messageId: key.messageId,
            ),
          );
      // The file just written is the newest, so the bound never drops the one
      // about to play. Nothing else evicts this directory outside account
      // removal, so without this it grows for as long as the account exists.
      await pruneAccountVoiceFiles(
        directory: directory,
        accountId: key.account.id,
      );
      return file;
    });

final chatMessagesProvider = StreamProvider.autoDispose
    .family<List<CachedChatMessage>, ChatRoomProviderKey>((ref, key) {
      return ref
          .watch(chatRepositoryProvider)
          .watchMessages(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });

final outgoingMessageStatusesProvider = StreamProvider.autoDispose
    .family<List<OutgoingMessageStatus>, ChatRoomProviderKey>((ref, key) {
      return ref
          .watch(chatServiceProvider)
          .watchOutgoingMessageStatuses(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });

final textSendOperationsProvider = StreamProvider.autoDispose
    .family<List<StoredTextSendOperation>, ChatRoomProviderKey>((ref, key) {
      return ref
          .watch(chatRepositoryProvider)
          .watchTextSendOperations(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });

final chatScopeProvider = StreamProvider.autoDispose
    .family<StoredChatScope?, ChatRoomProviderKey>((ref, key) {
      return ref
          .watch(chatRepositoryProvider)
          .watchScope(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });
