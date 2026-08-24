import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

import 'data/account_repository.dart';
import 'data/app_database.dart';
import 'data/attachment_repository.dart';
import 'data/chat_media_repository.dart';
import 'data/chat_repository.dart';
import 'data/credential_vault.dart';
import 'data/conversation_avatar_repository.dart';
import 'features/chat/attachment_service.dart';
import 'features/chat/chat_attachment_context.dart';
import 'features/chat/chat_service.dart';
import 'features/chat/composer/giphy.dart';
import 'features/conversations/conversation_sync_service.dart';
import 'features/onboarding/onboarding_coordinator.dart';
import 'features/push/android_push_coordinator.dart';
import 'features/push/android_web_push_bridge.dart';
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
  final service = AttachmentService(
    repository: ref.watch(attachmentRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    releaseSource: (attachment) => source.discard(attachment.handle),
    transport: HttpAttachmentTransport(
      client: http.Client(),
      sourceProvider: source,
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

final accountsProvider = StreamProvider<List<StoredAccount>>((ref) {
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

final chatMediaProvider = FutureProvider.autoDispose
    .family<ChatMediaImage?, ChatMediaProviderKey>((ref, key) {
      return ref
          .watch(chatMediaRepositoryProvider)
          .loadPreview(account: key.account, uri: key.uri);
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
