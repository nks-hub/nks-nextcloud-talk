import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/attachment_thread_binding.dart';
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

  /// The last live capability read, reused for [_capabilityReuse] so that an
  /// album of ten pictures asks the server once instead of ten times.
  ({String key, DateTime readAt, CapabilitySnapshot capabilities})?
  _recentCapabilities;
  static const _capabilityReuse = Duration(seconds: 10);

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
    final currentMetadata = await _canonicalThreadMetadata(
      accountId: accountId,
      roomToken: roomToken,
      metadata: metadata,
    );
    if (!authority.profile.supports(currentMetadata)) {
      // Which of the profile's flags said no is the only useful thing here,
      // and the caller can only report "unsupported" — so it is written down
      // rather than lost.
      debugPrint(
        '[attachment] rejected by the profile: ${authority.profile} '
        'for kind=${currentMetadata.kind.name} '
        'caption=${currentMetadata.caption != null} '
        'reply=${currentMetadata.replyTo != null} '
        'thread=${currentMetadata.threadId != null} '
        'silent=${currentMetadata.silent}',
      );
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.attachmentUnsupported,
      );
    }

    return AttachmentEnqueueRequest(
      accountId: accountId,
      server: authority.server,
      roomToken: roomToken,
      source: source,
      metadata: currentMetadata,
      davUserId: authority.davUserId,
      profile: authority.profile,
      credentialGeneration: authority.credentialGeneration,
      capabilityGeneration: authority.capabilityGeneration,
      roomCanWrite: true,
      policy: _uploadPolicy,
    );
  }

  Future<AttachmentMetadata> _canonicalThreadMetadata({
    required AccountId accountId,
    required ConversationToken roomToken,
    required AttachmentMetadata metadata,
  }) async {
    final rootMessageId = metadata.threadId ?? metadata.replyTo;
    if (rootMessageId == null) {
      return metadata;
    }
    final root = await _chat.getMessage(
      accountId: accountId.value,
      roomToken: roomToken.value,
      messageId: rootMessageId,
    );
    try {
      return AttachmentThreadBinding.fromCachedRoot(
        root: root,
        accountId: accountId.value,
        roomToken: roomToken.value,
        rootMessageId: rootMessageId,
      ).applyTo(metadata);
    } on StateError {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.contextChanged,
      );
    }
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
    final capabilityKey =
        '${accountId.value}\n${initial.account.serverUrl}\n'
        '${initial.account.loginName}\n$appPassword';
    final recent = _recentCapabilities;
    try {
      if (recent != null &&
          recent.key == capabilityKey &&
          _clock().toUtc().difference(recent.readAt).abs() < _capabilityReuse) {
        capabilities = recent.capabilities;
      } else {
        capabilities = await _api.getAuthenticatedCapabilities(
          server: server,
          loginName: initial.account.loginName,
          appPassword: appPassword,
        );
        _recentCapabilities = (
          key: capabilityKey,
          readAt: _clock().toUtc(),
          capabilities: capabilities,
        );
      }
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId.value);
        throw const ChatAttachmentContextException(
          ChatAttachmentContextError.reauthenticationRequired,
        );
      }
      // Without a network the attachment is queued like a text message, on
      // what the last live read stored; the upload itself retries and wakes
      // with connectivity.
      final stored = await _storedAuthority(initial, accountId, server);
      if (stored != null) {
        return stored;
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
    await _accounts.updateCapabilities(
      accountId.value,
      capabilities.talkFeatures,
      serverThemeColor: capabilities.serverThemeColor,
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

  Future<_ResolvedAttachmentAuthority?> _storedAuthority(
    _LocalAttachmentContext context,
    AccountId accountId,
    ServerBase server,
  ) async {
    final List<String> features;
    try {
      final decoded = jsonDecode(context.account.talkFeaturesJson);
      if (decoded is! List<Object?>) {
        return null;
      }
      features = decoded.whereType<String>().toList();
    } on FormatException {
      return null;
    }
    final capability = await _chat.getReadyCapabilitySnapshot(accountId.value);
    if (features.isEmpty || capability == null) {
      return null;
    }
    await _verifyIdentity(context.account, accountId);
    final DavUserId davUserId;
    try {
      davUserId = DavUserId.parse(context.account.loginName);
    } on TalkProtocolException {
      throw const ChatAttachmentContextException(
        ChatAttachmentContextError.identityUnverified,
      );
    }
    return _ResolvedAttachmentAuthority(
      server: server,
      davUserId: davUserId,
      profile: AttachmentCapabilityProfile.fromStoredFeatures(
        features,
        federated: context.room.isFederated,
      ),
      credentialGeneration: capability.credentialGeneration,
      capabilityGeneration: capability.generation,
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
