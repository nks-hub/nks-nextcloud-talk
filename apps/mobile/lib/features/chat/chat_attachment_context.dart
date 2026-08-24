import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import 'attachment_service.dart';

enum ChatAttachmentContextError {
  accountMissing,
  conversationMissing,
  credentialMissing,
  contextChanged,
  invalidConversation,
  readOnly,
  federatedUnsupported,
  reauthenticationRequired,
  capabilitiesUnavailable,
  invalidCapabilities,
  talkUnavailable,
  attachmentUnsupported,
  sourceUnsupported,
  identityUnverified,
}

final class ChatAttachmentContextException implements Exception {
  const ChatAttachmentContextException(this.code);

  final ChatAttachmentContextError code;

  @override
  String toString() => 'ChatAttachmentContextException(${code.name})';
}

/// Resolves the current authenticated room authority for a durable attachment.
final class ChatAttachmentContextResolver {
  factory ChatAttachmentContextResolver({
    required AccountRepository accounts,
    required ChatRepository chat,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    required AttachmentUploadPolicy uploadPolicy,
    DateTime Function()? clock,
  }) => ChatAttachmentContextResolver._(
    accounts,
    chat,
    credentials,
    api,
    uploadPolicy,
    clock ?? DateTime.now,
  );

  ChatAttachmentContextResolver._(
    this._accounts,
    this._chat,
    this._credentials,
    this._api,
    this._uploadPolicy,
    this._clock,
  );

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final AttachmentUploadPolicy _uploadPolicy;
  final DateTime Function() _clock;

  Future<AttachmentCapabilityProfile> resolveProfile({
    required AccountId accountId,
    required ConversationToken roomToken,
  }) async {
    final authority = await _resolveAuthority(
      accountId: accountId,
      roomToken: roomToken,
    );
    return authority.profile;
  }

  Future<AttachmentEnqueueRequest> resolve({
    required AccountId accountId,
    required ConversationToken roomToken,
    required PreparedAttachmentSource source,
    required AttachmentMetadata metadata,
  }) async {
    if (!metadata.supportsSource(source)) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.sourceUnsupported,
      );
    }

    final authority = await _resolveAuthority(
      accountId: accountId,
      roomToken: roomToken,
    );
    if (!authority.profile.supports(metadata)) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.attachmentUnsupported,
      );
    }

    return AttachmentEnqueueRequest(
      accountId: accountId,
      server: authority.server,
      roomToken: roomToken,
      source: source,
      metadata: metadata,
      davUserId: authority.davUserId,
      profile: authority.profile,
      credentialGeneration: authority.credentialGeneration,
      capabilityGeneration: authority.capabilityGeneration,
      roomCanWrite: true,
      policy: _uploadPolicy,
    );
  }

  Future<_ResolvedAttachmentAuthority> _resolveAuthority({
    required AccountId accountId,
    required ConversationToken roomToken,
  }) async {
    final initial = await _loadLocalContext(
      accountId: accountId,
      roomToken: roomToken,
      missingIsContextChange: false,
    );
    final appPassword = await _credentials.readAppPassword(accountId.value);
    if (appPassword == null || appPassword.isEmpty) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.credentialMissing,
      );
    }
    final server = _parseServer(initial.account.serverUrl);

    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: initial.account.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId.value);
        throw const ChatAttachmentContextException(
          ChatAttachmentContextError.reauthenticationRequired,
        );
      }
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.capabilitiesUnavailable,
      );
    } on TalkProtocolException {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.invalidCapabilities,
      );
    }
    if (!capabilities.hasTalk) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.talkUnavailable,
      );
    }

    final current = await _loadLocalContext(
      accountId: accountId,
      roomToken: roomToken,
      missingIsContextChange: true,
    );
    if (current.account.serverUrl != initial.account.serverUrl ||
        current.account.loginName != initial.account.loginName) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.contextChanged,
      );
    }
    final currentPassword = await _credentials.readAppPassword(accountId.value);
    if (currentPassword == null || currentPassword.isEmpty) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.credentialMissing,
      );
    }
    if (currentPassword != appPassword) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.contextChanged,
      );
    }
    await _verifyIdentity(current.account, accountId);

    final storedCapabilities = await _chat.recordCapabilities(
      accountId: accountId.value,
      talkFeatures: capabilities.talkFeatures,
      observedAt: _clock().toUtc(),
    );
    await _accounts.updateTalkFeatures(
      accountId.value,
      capabilities.talkFeatures,
    );

    final AttachmentCapabilityProfile profile;
    try {
      profile = AttachmentCapabilityProfile.fromSnapshot(
        capabilities,
        federated: current.room.isFederated,
      );
    } on TalkProtocolException {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.invalidCapabilities,
      );
    }

    final DavUserId davUserId;
    try {
      davUserId = DavUserId.parse(current.account.loginName);
    } on TalkProtocolException {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.identityUnverified,
      );
    }

    return _ResolvedAttachmentAuthority(
      server: server,
      davUserId: davUserId,
      profile: profile,
      credentialGeneration: storedCapabilities.credentialGeneration,
      capabilityGeneration: storedCapabilities.generation,
    );
  }

  Future<_LocalAttachmentContext> _loadLocalContext({
    required AccountId accountId,
    required ConversationToken roomToken,
    required bool missingIsContextChange,
  }) async {
    final account = await _accounts.getAccount(accountId.value);
    if (account == null) {
      throw ChatAttachmentContextException(
        missingIsContextChange
            ? ChatAttachmentContextError.contextChanged
            : ChatAttachmentContextError.accountMissing,
      );
    }
    final conversation = await _chat.getConversation(
      accountId: accountId.value,
      roomToken: roomToken.value,
    );
    if (conversation == null) {
      throw ChatAttachmentContextException(
        missingIsContextChange
            ? ChatAttachmentContextError.contextChanged
            : ChatAttachmentContextError.conversationMissing,
      );
    }
    if (conversation.accountId != account.id ||
        conversation.token != roomToken.value) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.contextChanged,
      );
    }

    final ConversationRoom room;
    try {
      room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    } on FormatException {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.invalidConversation,
      );
    } on TalkProtocolException {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.invalidConversation,
      );
    }
    if (room.token != roomToken) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.invalidConversation,
      );
    }
    if (room.readOnly != 0) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.readOnly,
      );
    }
    if (room.isFederated) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.federatedUnsupported,
      );
    }
    return _LocalAttachmentContext(account: account, room: room);
  }

  Future<void> _verifyIdentity(
    StoredAccount account,
    AccountId accountId,
  ) async {
    final identity = await _accounts.findByIdentity(
      serverUrl: account.serverUrl,
      loginName: account.loginName,
    );
    if (identity == null || identity.id != accountId.value) {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.identityUnverified,
      );
    }
  }

  ServerBase _parseServer(String serverUrl) {
    try {
      return ServerBase.parse(serverUrl);
    } on TalkProtocolException {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.identityUnverified,
      );
    }
  }
}

final class _LocalAttachmentContext {
  const _LocalAttachmentContext({required this.account, required this.room});

  final StoredAccount account;
  final ConversationRoom room;
}

final class _ResolvedAttachmentAuthority {
  const _ResolvedAttachmentAuthority({
    required this.server,
    required this.davUserId,
    required this.profile,
    required this.credentialGeneration,
    required this.capabilityGeneration,
  });

  final ServerBase server;
  final DavUserId davUserId;
  final AttachmentCapabilityProfile profile;
  final int credentialGeneration;
  final int capabilityGeneration;
}
