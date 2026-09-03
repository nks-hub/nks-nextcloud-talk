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
  notFound,
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
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    return context.profile;
  }

  Future<void> editMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
    required String message,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    _requireWritable(context);
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
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    _requireWritable(context);
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

  /// Pins [messageId] for the whole conversation, without an expiry.
  ///
  /// `pinUntil: 0` is the wire value for "until someone unpins it"; a timed
  /// pin would need a future timestamp instead. Talk keeps at most one pin
  /// per conversation, so pinning replaces whatever was pinned before.
  Future<void> pinMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) => _mutateMessage(
    accountId: accountId,
    roomToken: roomToken,
    build: (context) => RichChatRequest.pinMessage(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      profile: context.profile,
      messageId: messageId,
      pinUntil: 0,
      now: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    ),
  );

  Future<void> unpinMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) => _mutateMessage(
    accountId: accountId,
    roomToken: roomToken,
    build: (context) => RichChatRequest.unpinMessage(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      profile: context.profile,
      messageId: messageId,
    ),
  );

  /// Hides the conversation's pin for this account only. The pin stays in
  /// place for everyone else, which is why this needs no moderator role.
  Future<void> hidePinnedMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(
      () => RichChatRequest.hidePinnedMessage(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        messageId: messageId,
      ),
    );
    await _send(accountId: accountId, context: context, request: request);
  }

  /// Returns the reminder this account set on [messageId], or `null` when
  /// there is none. Talk answers a missing reminder with `404`, which is a
  /// state here rather than a failure.
  Future<RichChatReminder?> getReminder({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(
      () => RichChatRequest.getReminder(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        messageId: messageId,
      ),
    );
    final RichChatResponse response;
    try {
      response = await _send(
        accountId: accountId,
        context: context,
        request: request,
      );
    } on ChatMessageActionException catch (error) {
      if (error.code == ChatMessageActionError.notFound) {
        return null;
      }
      rethrow;
    }
    return response.reminder;
  }

  /// Sets this account's reminder on [messageId] at [timestamp], a Unix
  /// timestamp in seconds. Setting one where a reminder already exists
  /// replaces it.
  Future<void> setReminder({
    required String accountId,
    required String roomToken,
    required int messageId,
    required int timestamp,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(
      () => RichChatRequest.setReminder(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        messageId: messageId,
        timestamp: timestamp,
      ),
    );
    await _send(accountId: accountId, context: context, request: request);
  }

  Future<void> deleteReminder({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(
      () => RichChatRequest.deleteReminder(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        messageId: messageId,
      ),
    );
    await _send(accountId: accountId, context: context, request: request);
  }

  /// Hands [message] to the server to deliver at [sendAt], a Unix timestamp
  /// in seconds.
  ///
  /// The schedule is held by the server, not by this client, and creating it
  /// deliberately does not touch the durable text-send outbox. That outbox
  /// exists to settle one question - did this exact POST reach the chat - and
  /// answers it by scanning fresh history for the operation's `referenceId`.
  /// A scheduled message produces no history entry until [sendAt], so an
  /// outbox entry for it would sit unmatched for hours and either stay
  /// ambiguous forever or invite a manual resend that duplicates the message
  /// once the server fires it. Creating the schedule is therefore a one-shot
  /// mutation exactly like edit or pin: `201` means the server owns it from
  /// here, and an ambiguous result is resolved by reading the scheduled list
  /// back with [listScheduledMessages], never by replaying.
  Future<void> scheduleMessage({
    required String accountId,
    required String roomToken,
    required String message,
    required int sendAt,
    bool silent = false,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(
      () => RichChatRequest.createScheduled(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        message: message,
        sendAt: sendAt,
        silent: silent,
        threadId: 0,
        threadTitle: '',
        now: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    await _send(accountId: accountId, context: context, request: request);
  }

  /// Reads back everything this account has scheduled in [roomToken]. This is
  /// also how an ambiguous [scheduleMessage] result is resolved.
  Future<List<RichChatScheduledMessage>> listScheduledMessages({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(
      () => RichChatRequest.getScheduled(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
      ),
    );
    final response = await _send(
      accountId: accountId,
      context: context,
      request: request,
    );
    return response.scheduledMessages;
  }

  Future<void> deleteScheduledMessage({
    required String accountId,
    required String roomToken,
    required String scheduleId,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(
      () => RichChatRequest.deleteScheduled(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: context.profile,
        scheduleId: RichChatScheduleId.parse(
          scheduleId,
          path: r'$.scheduleId',
          code: TalkProtocolErrorCode.invalidRichChatRequest,
        ),
      ),
    );
    await _send(accountId: accountId, context: context, request: request);
  }

  /// Runs a mutation whose success response carries the authoritative message
  /// as its `parent`, and writes that message back into the cache.
  Future<void> _mutateMessage({
    required String accountId,
    required String roomToken,
    required RichChatRequest Function(_MessageActionContext context) build,
  }) async {
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
    final request = _buildRequest(() => build(context));
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
    final context = await _resolve(accountId: accountId, roomToken: roomToken);
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
        // `404` is how Talk reports "there is nothing here" - no reminder on
        // this message, no such schedule - which callers resolve themselves.
        throw ChatMessageActionException(
          response.statusCode == 404
              ? ChatMessageActionError.notFound
              : ChatMessageActionError.serviceUnavailable,
        );
      case RichChatResponseClassification.ambiguous:
      case RichChatResponseClassification.serverError:
        throw const ChatMessageActionException(
          ChatMessageActionError.serviceUnavailable,
        );
    }
  }

  /// Refuses a write that a read-only room would answer with `403`.
  ///
  /// Verified live against Nextcloud 34.0.1 on 2026-08-26: with `readOnly`
  /// set, edit, delete, react and send all come back `403`. Reactions and the
  /// composer are already hidden for a read-only room, so this only has to
  /// cover edit and delete, whose action-sheet entries are not.
  void _requireWritable(_MessageActionContext context) {
    if (context.readOnly) {
      throw const ChatMessageActionException(
        ChatMessageActionError.actionUnsupported,
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
    List<String> talkFeatures = const <String>[];
    Object? talkLocalFeatures = const <Object?>[];
    var translationAvailable = false;
    CapabilitySnapshot? capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId);
        throw ChatMessageActionException(_mapApiError(error));
      }
      // Offline, the actions a message offers must not vanish: the profile
      // is a read of what this server supports, and that is already stored
      // with the account. Without the fallback an app started without a
      // network showed no Reply, Edit or Delete at all, and kept showing
      // none after the network came back (Android 14, build 51). Local
      // features and translation are only known from the live read, so
      // scheduling and translation stay off until the next online resolve —
      // both need the server anyway.
      final stored = _storedTalkFeatures(account);
      if (stored == null) {
        throw ChatMessageActionException(_mapApiError(error));
      }
      talkFeatures = stored;
      talkLocalFeatures = const <Object?>[];
      translationAvailable = false;
    }
    if (capabilities != null) {
      if (!capabilities.hasTalk) {
        throw const ChatMessageActionException(
          ChatMessageActionError.talkUnavailable,
        );
      }
      await _accounts.updateCapabilities(
        accountId,
        capabilities.talkFeatures,
        serverThemeColor: capabilities.serverThemeColor,
      );
      await _chat.recordCapabilities(
        accountId: accountId,
        talkFeatures: capabilities.talkFeatures,
        observedAt: DateTime.now().toUtc(),
      );
      // `scheduled-messages` is only ever announced under `features-local`,
      // so passing an empty local set here would gate scheduling away on
      // every server that supports it.
      final rawSpreed = capabilities.capabilities['spreed'];
      final spreed = rawSpreed is Map<String, Object?>
          ? rawSpreed
          : const <String, Object?>{};
      talkFeatures = capabilities.talkFeatures.toList();
      talkLocalFeatures = spreed['features-local'] ?? const <Object?>[];
      translationAvailable = capabilities.chatTranslationAvailable;
    }
    final role = participantRoleFor(room.participantType);
    final RichChatCapabilityProfile profile;
    try {
      profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: talkFeatures,
        talkLocalFeatures: talkLocalFeatures,
        federated: room.isFederated,
        moderator:
            role == ParticipantRole.owner ||
            role == ParticipantRole.moderator ||
            role == ParticipantRole.guestModerator,
        // The effective permission for this user, not the per-attendee
        // override: `attendeePermissions` is 0 whenever no override is
        // set, which is the normal case and would gate away every
        // permission-guarded action, reactions included.
        participantPermissions: room.permissions,
        translationAvailable: translationAvailable,
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
      readOnly: room.readOnly != 0,
    );
  }
}

/// The Talk features stored with the account by the last successful read,
/// or null when the row has never seen one or holds something unreadable.
List<String>? _storedTalkFeatures(StoredAccount account) {
  try {
    final decoded = jsonDecode(account.talkFeaturesJson);
    if (decoded is! List<Object?>) {
      return null;
    }
    final features = decoded.whereType<String>().toList();
    return features.isEmpty ? null : features;
  } on FormatException {
    return null;
  }
}

final class _MessageActionContext {
  const _MessageActionContext({
    required this.account,
    required this.server,
    required this.appPassword,
    required this.profile,
    required this.readOnly,
  });

  final StoredAccount account;
  final ServerBase server;
  final String appPassword;
  final RichChatCapabilityProfile profile;

  /// Whether the room currently refuses every write. Talk answers `403` for
  /// edit, delete, react and send alike once `readOnly` is set.
  final bool readOnly;
}

ChatMessageActionError _mapApiError(NextcloudApiException error) {
  return switch (error.statusCode) {
    401 => ChatMessageActionError.reauthenticationRequired,
    404 => ChatMessageActionError.notFound,
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
