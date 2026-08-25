import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'core/giphy_reference_load_coordinator.dart';
import 'data/account_repository.dart';
import 'data/app_database.dart';
import 'data/attachment_repository.dart';
import 'data/chat_media_cache.dart';
import 'data/chat_media_repository.dart';
import 'data/chat_repository.dart';
import 'data/credential_vault.dart';
import 'data/conversation_avatar_repository.dart';
import 'features/chat/attachment_service.dart';
import 'features/chat/chat_attachment_context.dart';
import 'features/chat/chat_service.dart';
import 'features/chat/outgoing_message_status.dart';
import 'features/chat/composer/giphy.dart';
import 'features/chat/composer/mention_suggestions.dart';
import 'features/conversations/conversation_sync_service.dart';
import 'features/newconversation/new_conversation_service.dart';
import 'features/conversations/deep_link_bridge.dart';
import 'features/conversations/deep_link_coordinator.dart';
import 'features/onboarding/onboarding_coordinator.dart';
import 'features/push/android_push_coordinator.dart';
import 'features/push/android_web_push_bridge.dart';
import 'features/settings/theme_preference.dart';
import 'network/attachment_transport.dart';
import 'network/nextcloud_api.dart';
import 'platform/media/durable_attachment_source_store.dart';

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

final attachmentRepositoryProvider = Provider<AttachmentRepository>((ref) {
  return AttachmentRepository(ref.watch(appDatabaseProvider));
});

final credentialVaultProvider = Provider<CredentialVault>((ref) {
  return SecureCredentialVault();
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

final androidWebPushPlatformProvider = Provider<AndroidWebPushPlatform?>((ref) {
  if (!Platform.isAndroid) {
    return null;
  }
  final bridge = AndroidWebPushBridge();
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});

final androidPushCoordinatorProvider = Provider<AndroidPushCoordinator?>((ref) {
  final platform = ref.watch(androidWebPushPlatformProvider);
  if (platform == null) {
    return null;
  }
  final coordinator = AndroidPushCoordinator(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    platform: platform,
    onWakeUp: (accountId) =>
        ref.read(conversationSyncServiceProvider).sync(accountId),
  );
  ref.onDispose(() => unawaited(coordinator.close()));
  unawaited(coordinator.start());
  return coordinator;
});

final deepLinkPlatformProvider = Provider<DeepLinkPlatform?>((ref) {
  if (!Platform.isAndroid) {
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
    resolver: ref.watch(deepLinkResolverProvider),
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
            chat.syncRoom(
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
      return coordinator.load(
        accountId: request.accountId,
        resourceUrl: request.resourceUrl,
        loader: () => repository.loadReference(
          request.resourceUrl,
          abortTrigger: abort.future,
        ),
      );
    });

final accountsProvider = StreamProvider<List<StoredAccount>>((ref) {
  ref.watch(attachmentServiceProvider);
  return ref.watch(accountRepositoryProvider).watchAccounts();
});

final selectedAccountProvider = StreamProvider<StoredAccount?>((ref) {
  return ref.watch(accountRepositoryProvider).watchSelectedAccount();
});

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

final conversationsProvider =
    StreamProvider.family<List<CachedConversation>, String>((ref, accountId) {
      return ref.watch(accountRepositoryProvider).watchConversations(accountId);
    });

typedef ChatRoomProviderKey = ({
  String accountId,
  String roomToken,
  int? threadId,
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
      final room = ConversationRoom.fromJson(
        jsonDecode(conversation.rawJson),
      );
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
        participantPermissions: room.attendeePermissions,
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
      final loaded = await ref
          .watch(chatMediaRepositoryProvider)
          .loadPreview(account: key.account, uri: key.uri);
      if (loaded != null) {
        cache.write(cacheKey, loaded);
      }
      return loaded;
    });

typedef ChatVoiceProviderKey = ({StoredAccount account, Uri uri, int messageId});

/// A voice message is fetched once per room visit and materialised in the
/// app cache directory so a platform player can open it.
final chatVoiceFileProvider = FutureProvider.autoDispose
    .family<ChatVoiceFile, ChatVoiceProviderKey>((ref, key) async {
      final directory = Directory(
        '${(await getApplicationCacheDirectory()).path}'
        '${Platform.pathSeparator}voice',
      );
      return ref
          .watch(chatMediaRepositoryProvider)
          .loadVoiceFile(
            account: key.account,
            uri: key.uri,
            directory: directory,
            cacheKey:
                '${key.account.id}-${key.messageId}'.replaceAll(
                  RegExp(r'[^A-Za-z0-9._-]'),
                  '_',
                ),
          );
    });

final chatMessagesProvider =
    StreamProvider.family<List<CachedChatMessage>, ChatRoomProviderKey>((
      ref,
      key,
    ) {
      return ref
          .watch(chatRepositoryProvider)
          .watchMessages(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });

final outgoingMessageStatusesProvider =
    StreamProvider.family<List<OutgoingMessageStatus>, ChatRoomProviderKey>((
      ref,
      key,
    ) {
      return ref
          .watch(chatServiceProvider)
          .watchOutgoingMessageStatuses(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });

final textSendOperationsProvider =
    StreamProvider.family<List<StoredTextSendOperation>, ChatRoomProviderKey>((
      ref,
      key,
    ) {
      return ref
          .watch(chatRepositoryProvider)
          .watchTextSendOperations(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });

final chatScopeProvider =
    StreamProvider.family<StoredChatScope?, ChatRoomProviderKey>((ref, key) {
      return ref
          .watch(chatRepositoryProvider)
          .watchScope(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
          );
    });
