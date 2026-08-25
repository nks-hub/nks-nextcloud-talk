// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum ChatMessageActionError {
  accountMissing,
  conversationMissing,
  credentialMissing,
  talkUnavailable,
  actionUnsupported,
  messageMissing,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class ChatMessageActionException implements Exception {
  const ChatMessageActionException(this.code);

  final ChatMessageActionError code;

  @override
  String toString() => 'ChatMessageActionException(${code.name})';
}

/// Edits, deletes, and reacts to a single already-cached chat message.
///
/// This is deliberately separate from `ChatService`: it never touches the
/// text outbox or sync scopes, and every call is a one-shot mutation of a
/// message the room already rendered.
final class ChatMessageActionsService {
  ChatMessageActionsService({
    required AccountRepository accounts,
    required ChatRepository chat,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid? uuid,
  }) : _accounts = accounts,
       _chat = chat,
       _credentials = credentials,
       _api = api,
       _uuid = uuid ?? const Uuid();

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;

  /// Resolves the capability profile that gates edit/delete/react actions
  /// for the given room, without performing any mutation.
  Future<RichChatCapabilityProfile> resolveProfile({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _resolve(
      accountId: accountId,
      roomToken: roomToken,
    );
    return context.profile;
  }

  Future<void> editMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
    required String message,
  }) async {
    final context = await _resolve(
      accountId: accountId,
      roomToken: roomToken,
    );
    final request = _buildRequest(
      () => RichChatRequest.editMessage(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        messageId: messageId,
        message: message,
      ),
    );
    final response = await _send(
      accountId: accountId,
      context: context,
      request: request,
    );
    await _applyParentMutation(
      accountId: accountId,
      context: context,
      response: response,
    );
  }

  Future<void> deleteMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) async {
    final context = await _resolve(
      accountId: accountId,
      roomToken: roomToken,
    );
    final request = _buildRequest(
      () => RichChatRequest.deleteMessage(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        messageId: messageId,
      ),
    );
    final response = await _send(
      accountId: accountId,
      context: context,
      request: request,
    );
    await _applyParentMutation(
      accountId: accountId,
      context: context,
      response: response,
    );
  }

  /// Adds [reaction] on behalf of the current account. Adding a reaction the
  /// account already placed is a no-op server-side; toggling it off is
  /// [deleteReaction].
  Future<void> addReaction({
    required String accountId,
    required String roomToken,
    required int messageId,
    required String reaction,
  }) => _mutateReaction(
    accountId: accountId,
    roomToken: roomToken,
    messageId: messageId,
    build: (context, actor) => RichChatRequest.addReaction(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      profile: context.profile,
      messageId: messageId,
      reaction: reaction,
      actor: actor,
    ),
  );

  Future<void> deleteReaction({
    required String accountId,
    required String roomToken,
    required int messageId,
    required String reaction,
  }) => _mutateReaction(
    accountId: accountId,
    roomToken: roomToken,
    messageId: messageId,
    build: (context, actor) => RichChatRequest.deleteReaction(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      profile: context.profile,
      messageId: messageId,
      reaction: reaction,
      actor: actor,
    ),
  );

  Future<void> _mutateReaction({
    required String accountId,
    required String roomToken,
    required int messageId,
    required RichChatRequest Function(
      _MessageActionContext context,
      RichChatActorIdentity actor,
    )
    build,
  }) async {
    final context = await _resolve(
      accountId: accountId,
      roomToken: roomToken,
    );
    // Nextcloud Talk actor identities for a logged-in account are always
    // `users`/loginName, matching the convention already used to detect the
    // account's own messages elsewhere in the chat pane.
    final actor = RichChatActorIdentity(
      actorType: 'users',
      actorId: context.account.loginName,
    );
    final request = _buildRequest(() => build(context, actor));
    final response = await _send(
      accountId: accountId,
      context: context,
      request: request,
    );
    final aggregate = response.reactionAggregate;
    if (aggregate == null) {
      throw const ChatMessageActionException(
        ChatMessageActionError.invalidResponse,
      );
    }
    final cached = await _chat.getMessage(
      accountId: accountId,
      roomToken: roomToken,
      messageId: messageId,
    );
    if (cached == null) {
      throw const ChatMessageActionException(
        ChatMessageActionError.messageMissing,
      );
    }
    final ChatMessage current;
    try {
      current = ChatMessage.fromJson(jsonDecode(cached.rawJson));
    } on Object {
      throw const ChatMessageActionException(
        ChatMessageActionError.invalidResponse,
      );
    }
    final updated = current.withReactionAggregate(
      reactions: aggregate.counts,
      reactionsSelf: aggregate.reactionsSelf,
    );
    await _chat.applyMessageMutation(
      accountId: accountId,
      server: context.server,
      message: updated,
    );
  }

  Future<void> _applyParentMutation({
    required String accountId,
    required _MessageActionContext context,
    required RichChatResponse response,
  }) async {
    final parent = response.messageMutation?.parent;
    if (parent is! ChatFullParent) {
      throw const ChatMessageActionException(
        ChatMessageActionError.invalidResponse,
      );
    }
    await _chat.applyMessageMutation(
      accountId: accountId,
      server: context.server,
      message: parent.message,
    );
  }

  RichChatRequest _buildRequest(RichChatRequest Function() build) {
    try {
      return build();
    } on TalkProtocolException {
      throw const ChatMessageActionException(
        ChatMessageActionError.actionUnsupported,
      );
    }
  }

  Future<RichChatResponse> _send({
    required String accountId,
    required _MessageActionContext context,
    required RichChatRequest request,
  }) async {
    final RichChatResponse response;
    try {
      response = await _api.sendRichChat(
        richChatRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId);
      }
      throw ChatMessageActionException(_mapApiError(error));
    } on TalkProtocolException {
      throw const ChatMessageActionException(
        ChatMessageActionError.invalidResponse,
      );
    }
    switch (response.classification) {
      case RichChatResponseClassification.success:
        return response;
      case RichChatResponseClassification.reauthenticationRequired:
        await _chat.markReauthenticationRequired(accountId);
        throw const ChatMessageActionException(
          ChatMessageActionError.reauthenticationRequired,
        );
      case RichChatResponseClassification.deterministicFailure:
      case RichChatResponseClassification.ambiguous:
      case RichChatResponseClassification.serverError:
        throw const ChatMessageActionException(
          ChatMessageActionError.serviceUnavailable,
        );
    }
  }

  Future<_MessageActionContext> _resolve({
    required String accountId,
    required String roomToken,
  }) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const ChatMessageActionException(
        ChatMessageActionError.accountMissing,
      );
    }
    final conversation = await _chat.getConversation(
      accountId: accountId,
      roomToken: roomToken,
    );
    if (conversation == null) {
      throw const ChatMessageActionException(
        ChatMessageActionError.conversationMissing,
      );
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null || appPassword.isEmpty) {
      throw const ChatMessageActionException(
        ChatMessageActionError.credentialMissing,
      );
    }
    final ServerBase server;
    final ConversationRoom room;
    try {
      server = ServerBase.parse(account.serverUrl);
      room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    } on TalkProtocolException {
      throw const ChatMessageActionException(
        ChatMessageActionError.invalidResponse,
      );
    } on FormatException {
      throw const ChatMessageActionException(
        ChatMessageActionError.invalidResponse,
      );
    }
    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId);
      }
      throw ChatMessageActionException(_mapApiError(error));
    }
    if (!capabilities.hasTalk) {
      throw const ChatMessageActionException(
        ChatMessageActionError.talkUnavailable,
      );
    }
    await _accounts.updateTalkFeatures(accountId, capabilities.talkFeatures);
    await _chat.recordCapabilities(
      accountId: accountId,
      talkFeatures: capabilities.talkFeatures,
      observedAt: DateTime.now().toUtc(),
    );
    final role = participantRoleFor(room.participantType);
    final RichChatCapabilityProfile profile;
    try {
      profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: capabilities.talkFeatures.toList(),
        talkLocalFeatures: const <String>[],
        federated: room.isFederated,
        moderator:
            role == ParticipantRole.owner ||
            role == ParticipantRole.moderator ||
            role == ParticipantRole.guestModerator,
        participantPermissions: room.attendeePermissions,
      );
    } on TalkProtocolException {
      throw const ChatMessageActionException(
        ChatMessageActionError.invalidResponse,
      );
    }
    return _MessageActionContext(
      account: account,
      server: server,
      appPassword: appPassword,
      profile: profile,
    );
  }
}

final class _MessageActionContext {
  const _MessageActionContext({
    required this.account,
    required this.server,
    required this.appPassword,
    required this.profile,
  });

  final StoredAccount account;
  final ServerBase server;
  final String appPassword;
  final RichChatCapabilityProfile profile;
}

ChatMessageActionError _mapApiError(NextcloudApiException error) {
  return switch (error.statusCode) {
    401 => ChatMessageActionError.reauthenticationRequired,
    429 => ChatMessageActionError.rateLimited,
    500 || 502 || 503 || 504 => ChatMessageActionError.serviceUnavailable,
    _ => switch (error.code) {
      NextcloudApiError.network ||
      NextcloudApiError.timeout => ChatMessageActionError.network,
      NextcloudApiError.cancelled ||
      NextcloudApiError.responseTooLarge ||
      NextcloudApiError.invalidJson ||
      NextcloudApiError.invalidAvatarUri ||
      NextcloudApiError.invalidAvatarResponse ||
      NextcloudApiError.invalidWebPushResponse ||
      NextcloudApiError.unexpectedStatus =>
        ChatMessageActionError.invalidResponse,
    },
  };
}
