import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

part 'poll_service_management.dart';
part 'poll_service_authority.dart';

const int _chatPermission = 128;
const int _ignoreLobbyPermission = 8;
const int _roomTypeGroup = 2;
const int _roomTypePublic = 3;

typedef PollRoomKey = ({String accountId, String roomToken, int? threadId});

enum PollServiceError {
  contextMissing,
  credentialMissing,
  unsupported,
  permissionDenied,
  reauthenticationRequired,
  rateLimited,
  unavailable,
  ambiguous,
  invalidResponse,
  invalidInput,
  notFound,
}

final class PollManagementAccess {
  const PollManagementAccess({
    this.canListDrafts = false,
    this.canCreateDraft = false,
    this.canEditDraft = false,
    this.canDeleteDraft = false,
    this.canPublish = false,
    this.canClose = false,
    this.canExport = false,
  });

  final bool canListDrafts;
  final bool canCreateDraft;
  final bool canEditDraft;
  final bool canDeleteDraft;
  final bool canPublish;
  final bool canClose;
  final bool canExport;
}

final class PollExportFile {
  const PollExportFile({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });
  final Uint8List bytes;
  final String fileName;
  final String mimeType;
}

final class PollServiceException implements Exception {
  const PollServiceException(this.code);
  final PollServiceError code;
}

abstract interface class PollSender {
  Future<bool> isAvailable(PollRoomKey key);

  Future<TalkPoll> create({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  });

  Future<TalkPoll> load({required PollRoomKey key, required int pollId});

  Future<TalkPoll> vote({
    required PollRoomKey key,
    required TalkPoll poll,
    required List<int> optionIds,
  });

  Future<PollManagementAccess> managementAccess({
    required PollRoomKey key,
    TalkPoll? poll,
  });
  Future<TalkPoll> close({required PollRoomKey key, required TalkPoll poll});
  Future<List<TalkPoll>> listDrafts({required PollRoomKey key});
  Future<TalkPoll> createDraft({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  });
  Future<TalkPoll> editDraft({
    required PollRoomKey key,
    required TalkPoll draft,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  });
  Future<void> deleteDraft({required PollRoomKey key, required TalkPoll draft});
  Future<TalkPoll> publishDraft({
    required PollRoomKey key,
    required TalkPoll draft,
  });
  Future<PollExportFile> export({
    required PollRoomKey key,
    required TalkPoll poll,
    required PollExportFormat format,
  });
}

final class PollService implements PollSender {
  factory PollService({
    required AccountRepository accounts,
    required ChatRepository chat,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid uuid = const Uuid(),
  }) => PollService._(accounts, chat, credentials, api, uuid);

  PollService._(
    this._accounts,
    this._chat,
    this._credentials,
    this._api,
    this._uuid,
  );

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;
  final Expando<_PreparedPoll> _pollOrigins = Expando<_PreparedPoll>();

  @override
  Future<PollManagementAccess> managementAccess({
    required PollRoomKey key,
    TalkPoll? poll,
  }) => _managementAccess(key: key, poll: poll);
  @override
  Future<TalkPoll> close({required PollRoomKey key, required TalkPoll poll}) =>
      _close(key: key, poll: poll);
  @override
  Future<List<TalkPoll>> listDrafts({required PollRoomKey key}) =>
      _listDrafts(key);
  @override
  Future<TalkPoll> createDraft({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) => _createDraft(
    key: key,
    question: question,
    options: options,
    resultMode: resultMode,
    maxVotes: maxVotes,
  );
  @override
  Future<TalkPoll> editDraft({
    required PollRoomKey key,
    required TalkPoll draft,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) => _editDraft(
    key: key,
    draft: draft,
    question: question,
    options: options,
    resultMode: resultMode,
    maxVotes: maxVotes,
  );
  @override
  Future<void> deleteDraft({
    required PollRoomKey key,
    required TalkPoll draft,
  }) => _deleteDraft(key: key, draft: draft);
  @override
  Future<TalkPoll> publishDraft({
    required PollRoomKey key,
    required TalkPoll draft,
  }) => _publishDraft(key: key, draft: draft);
  @override
  Future<PollExportFile> export({
    required PollRoomKey key,
    required TalkPoll poll,
    required PollExportFormat format,
  }) => _export(key: key, poll: poll, format: format);

  @override
  Future<bool> isAvailable(PollRoomKey key) async {
    try {
      await _prepare(key, access: _PollAccess.create);
      return true;
    } on PollServiceException {
      // The room or the server genuinely does not admit a poll. Expected, and
      // the menu row is right to stay away.
      return false;
    } on Object catch (error) {
      // Anything else took the poll off the menu for a reason nobody could
      // see: `_prepare` reads the credential vault, the cached room and the
      // capabilities, so a keychain hiccup or one damaged cached row removed
      // the feature silently. The row still goes — a poll that cannot be
      // prepared cannot be created — but the reason reaches the log now. The
      // same swallowed `on Object` cost a day twice on 6 September, on a file
      // share and on voice playback.
      debugPrint(
        '[poll] availability check for ${key.roomToken} failed: $error',
      );
      return false;
    }
  }

  @override
  Future<TalkPoll> create({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) async {
    var dispatched = false;
    try {
      final context = await _prepare(key, access: _PollAccess.create);
      final request = PollCreateRequest(
        accountId: AccountId.parse(key.accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: context.room.token,
        pollsAvailable: true,
        question: question,
        options: options,
        resultMode: resultMode,
        maxVotes: maxVotes,
        threadId: key.threadId,
      );
      dispatched = true;
      final response = await _api.createPoll(
        pollRequest: request,
        loginName: context.loginName,
        appPassword: context.appPassword,
      );
      return await _confirmed(
        response,
        key.accountId,
        context: context,
        dispatched: dispatched,
      );
    } on PollServiceException {
      rethrow;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(key.accountId);
      }
      throw PollServiceException(
        error.statusCode == 401
            ? PollServiceError.reauthenticationRequired
            : dispatched
            ? PollServiceError.ambiguous
            : PollServiceError.unavailable,
      );
    } on TalkProtocolException {
      throw PollServiceException(
        dispatched
            ? PollServiceError.ambiguous
            : PollServiceError.invalidResponse,
      );
    }
  }

  @override
  Future<TalkPoll> load({required PollRoomKey key, required int pollId}) async {
    try {
      final context = await _prepare(key, access: _PollAccess.readVote);
      final response = await _api.getPoll(
        pollRequest: PollShowRequest(
          accountId: AccountId.parse(key.accountId),
          requestId: ChatRequestId.parse(_uuid.v4()),
          server: context.server,
          roomToken: context.room.token,
          pollsAvailable: true,
          pollId: pollId,
        ),
        loginName: context.loginName,
        appPassword: context.appPassword,
      );
      return await _confirmed(
        response,
        key.accountId,
        context: context,
        dispatched: false,
      );
    } on PollServiceException {
      rethrow;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(key.accountId);
      }
      throw PollServiceException(
        error.statusCode == 401
            ? PollServiceError.reauthenticationRequired
            : PollServiceError.unavailable,
      );
    } on TalkProtocolException {
      throw const PollServiceException(PollServiceError.invalidResponse);
    }
  }

  @override
  Future<TalkPoll> vote({
    required PollRoomKey key,
    required TalkPoll poll,
    required List<int> optionIds,
  }) async {
    if (poll.status != PollStatus.open ||
        optionIds.length >
            (poll.maxVotes == 0 ? poll.options.length : poll.maxVotes) ||
        optionIds.any((id) => id >= poll.options.length)) {
      throw const PollServiceException(PollServiceError.invalidResponse);
    }
    var dispatched = false;
    try {
      final context = await _prepare(key, access: _PollAccess.readVote);
      _requireOrigin(key, poll, context);
      final request = PollVoteRequest(
        accountId: AccountId.parse(key.accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        roomToken: context.room.token,
        pollsAvailable: true,
        pollId: poll.id,
        optionIds: optionIds,
      );
      dispatched = true;
      final response = await _api.votePoll(
        pollRequest: request,
        loginName: context.loginName,
        appPassword: context.appPassword,
      );
      return await _confirmed(
        response,
        key.accountId,
        context: context,
        dispatched: dispatched,
      );
    } on PollServiceException {
      rethrow;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(key.accountId);
      }
      throw PollServiceException(
        error.statusCode == 401
            ? PollServiceError.reauthenticationRequired
            : dispatched
            ? PollServiceError.ambiguous
            : PollServiceError.unavailable,
      );
    } on TalkProtocolException {
      throw PollServiceException(
        dispatched
            ? PollServiceError.ambiguous
            : PollServiceError.invalidResponse,
      );
    }
  }

  Future<_PreparedPoll> _prepare(
    PollRoomKey key, {
    required _PollAccess access,
    bool forceCapabilities = false,
  }) async {
    final account = await _accounts.getAccount(key.accountId);
    final conversation = await _chat.getConversation(
      accountId: key.accountId,
      roomToken: key.roomToken,
    );
    if (account == null || conversation == null) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
    final password = await _credentials.readAppPassword(key.accountId);
    if (password == null || password.isEmpty) {
      throw const PollServiceException(PollServiceError.credentialMissing);
    }
    try {
      var room = await _validateCachedContext(key, access: access);
      final server = ServerBase.parse(account.serverUrl);
      final capabilities = (await _api.getAuthenticatedCapabilitiesWithSource(
        server: server,
        loginName: account.loginName,
        appPassword: password,
        forceRefresh: forceCapabilities,
      )).snapshot;
      if (!capabilities.talkFeatures.contains('talk-polls') ||
          (access == _PollAccess.create &&
              key.threadId != null &&
              !capabilities.talkFeatures.contains('threads'))) {
        throw const PollServiceException(PollServiceError.unsupported);
      }
      // Capabilities are a network boundary. The room or thread can change
      // while it is in flight, so validate the current cache again before the
      // mutation is allowed to leave the process.
      room = await _validateCachedContext(key, access: access);
      final prepared = _PreparedPoll(
        accountId: key.accountId,
        server: server,
        room: room,
        loginName: account.loginName,
        appPassword: password,
        features: capabilities.talkFeatures,
      );
      await _validateIdentity(prepared);
      return prepared;
    } on PollServiceException {
      rethrow;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(key.accountId);
        throw const PollServiceException(
          PollServiceError.reauthenticationRequired,
        );
      }
      throw const PollServiceException(PollServiceError.unavailable);
    } on FormatException {
      throw const PollServiceException(PollServiceError.invalidResponse);
    } on TalkProtocolException {
      throw const PollServiceException(PollServiceError.invalidResponse);
    }
  }

  Future<ConversationRoom> _validateCachedContext(
    PollRoomKey key, {
    required _PollAccess access,
  }) async {
    final conversation = await _chat.getConversation(
      accountId: key.accountId,
      roomToken: key.roomToken,
    );
    if (conversation == null || conversation.accountId != key.accountId) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    if (room.token.value != key.roomToken ||
        (room.lobbyState != 0 &&
            !_isPollModerator(room) &&
            room.permissions & _ignoreLobbyPermission !=
                _ignoreLobbyPermission)) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
    if (access != _PollAccess.readVote &&
        (room.readOnly != 0 ||
            (room.type != _roomTypeGroup && room.type != _roomTypePublic) ||
            // A bare 0 is the server's "use the defaults", which include chat.
            // Testing the bit over it refuses everything at once, which would
            // stop an ordinary participant creating a poll at all.
            (room.permissions != 0 &&
                room.permissions & _chatPermission != _chatPermission))) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
    if (access != _PollAccess.create || key.threadId == null) {
      return room;
    }
    if (room.isFederated) {
      throw const PollServiceException(PollServiceError.unsupported);
    }
    final rootRow = await _chat.getMessage(
      accountId: key.accountId,
      roomToken: key.roomToken,
      messageId: key.threadId!,
    );
    if (rootRow == null ||
        rootRow.deleted ||
        rootRow.accountId != key.accountId ||
        rootRow.roomToken != key.roomToken ||
        rootRow.messageId != key.threadId) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
    final root = ChatMessage.fromJson(jsonDecode(rootRow.rawJson));
    final title = root.threadTitle?.trim();
    if (root.messageId != key.threadId ||
        root.roomToken != room.token ||
        root.isThread != true ||
        root.threadId != key.threadId ||
        title == null ||
        title.isEmpty ||
        title.runes.length > 200) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
    return room;
  }

  Future<TalkPoll> _confirmed(
    PollResponse response,
    String accountId, {
    required bool dispatched,
    required _PreparedPoll context,
  }) async {
    final poll = response.poll;
    if (response.classification == PollResponseClassification.confirmed &&
        poll != null) {
      await _validateIdentity(context);
      _pollOrigins[poll] = context;
      return poll;
    }
    if (response.classification ==
        PollResponseClassification.reauthenticationRequired) {
      await _chat.markReauthenticationRequired(accountId);
    }
    throw PollServiceException(switch (response.classification) {
      PollResponseClassification.reauthenticationRequired =>
        PollServiceError.reauthenticationRequired,
      PollResponseClassification.permissionDenied =>
        PollServiceError.permissionDenied,
      PollResponseClassification.rateLimited => PollServiceError.rateLimited,
      PollResponseClassification.invalidInput => PollServiceError.invalidInput,
      PollResponseClassification.notFound => PollServiceError.notFound,
      PollResponseClassification.serviceUnavailable =>
        dispatched ? PollServiceError.ambiguous : PollServiceError.unavailable,
      PollResponseClassification.confirmed => PollServiceError.invalidResponse,
    });
  }
}

enum _PollAccess { create, writeDraft, readVote }

final class _PreparedPoll {
  const _PreparedPoll({
    required this.accountId,
    required this.server,
    required this.room,
    required this.loginName,
    required this.appPassword,
    required this.features,
    this.userId,
  });
  final String accountId;
  final ServerBase server;
  final ConversationRoom room;
  final String loginName;
  final String appPassword;
  final Set<String> features;
  final String? userId;
}
