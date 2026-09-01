import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, NavigatorObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

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
import 'features/calls/call_signaling_session.dart';
import 'features/calls/call_transport_service.dart';
import 'features/chat/attachment_service.dart';
import 'features/chat/chat_background_surface.dart';
import 'features/chat/chat_attachment_context.dart';
import 'features/chat/chat_message_actions_service.dart';
import 'features/chat/message_translation_service.dart';
import 'features/chat/references/reference_resolver.dart';
import 'features/chat/location_share_service.dart';
import 'features/chat/poll_service.dart';
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
import 'features/push/client_push_coordinator.dart';
import 'features/push/client_push_session.dart';
import 'features/push/push_gateway_client.dart';
import 'features/push/push_registration_coordinator.dart';
import 'features/push/windows_notification.dart';
import 'network/attachment_transport.dart';
import 'network/nextcloud_api.dart';
import 'platform/app_settings.dart';
import 'platform/media/durable_attachment_source_store.dart';

part 'app_providers_push.dart';
part 'app_providers_calls.dart';
part 'app_providers_reference.dart';
part 'app_providers_settings.dart';

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

final androidNotificationPermissionProvider = StreamProvider.autoDispose
    .family<AndroidNotificationPermission?, bool>((ref, enabled) async* {
      final platform = ref.watch(androidWebPushPlatformProvider);
      if (!enabled || platform == null) {
        yield null;
        return;
      }
      yield await platform.getNotificationPermission();
      await for (final _ in ref.watch(appLifecycleResumeEventsProvider)) {
        yield await platform.getNotificationPermission();
      }
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
    onWakeUp: (accountId) => unawaited(
      // `unawaited` marks the future as deliberately not awaited; it does not
      // handle its failure. A sync that failed here escaped to the zone and
      // was reported as a fatal crash - seen on build 7 as a plain
      // "network" code, moments after the device fell back to cellular.
      // The push transport already treats the same codes as retryable, so
      // swallowing them here keeps the two wake-up paths consistent. Anything
      // the service did not classify still surfaces with its own stack.
      ref
          .read(conversationSyncServiceProvider)
          .sync(accountId)
          .catchError(
            (Object _, StackTrace _) {},
            test: (error) =>
                error is ConversationSyncException && error.isTransient,
          ),
    ),
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
    for (final accountId
        in previous?.valueOrNull
                ?.map((account) => account.id)
                .where((id) => !live.contains(id)) ??
            const <String>[]) {
      unawaited(coordinator.unfollow(accountId));
    }
  }, fireImmediately: true);
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

final messageTranslationServiceProvider = Provider<MessageTranslationService>((
  ref,
) {
  return HttpMessageTranslationService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final currentLocationSourceProvider = Provider<CurrentLocationSource>((ref) {
  return GeolocatorCurrentLocationSource();
});

final appSettingsOpenerProvider = Provider<AppSettingsOpener>((ref) {
  return const GeolocatorAppSettingsOpener();
});

final locationShareServiceProvider = Provider<LocationShareSender>((ref) {
  return LocationShareService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final pollServiceProvider = Provider<PollSender>((ref) {
  return PollService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final pollAvailabilityProvider = FutureProvider.autoDispose
    .family<bool, PollRoomKey>((ref, key) {
      return ref.watch(pollServiceProvider).isAvailable(key);
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

final selectedAccountThemeColorProvider = StreamProvider<String?>((ref) {
  return ref.watch(accountRepositoryProvider).watchSelectedThemeColor();
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
