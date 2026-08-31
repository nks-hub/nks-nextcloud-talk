import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

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

  Future<TalkPoll> vote({
    required PollRoomKey key,
    required TalkPoll poll,
    required List<int> optionIds,
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

  @override
  Future<bool> isAvailable(PollRoomKey key) async {
    try {
      await _prepare(key);
      return true;
    } on PollServiceException {
      return false;
    } on Object {
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
      final context = await _prepare(key);
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
      return await _confirmed(response, key.accountId, dispatched: dispatched);
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
      final context = await _prepare(key);
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
      return await _confirmed(response, key.accountId, dispatched: dispatched);
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

  Future<_PreparedPoll> _prepare(PollRoomKey key) async {
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
      final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
      if (conversation.accountId != key.accountId ||
          room.token.value != key.roomToken ||
          room.readOnly != 0 ||
          (room.type != _roomTypeGroup && room.type != _roomTypePublic) ||
          room.permissions & _chatPermission != _chatPermission ||
          (room.lobbyState != 0 &&
              room.permissions & _ignoreLobbyPermission !=
                  _ignoreLobbyPermission)) {
        throw const PollServiceException(PollServiceError.contextMissing);
      }
      // The v1 federation proxy does not forward PollController's threadId.
      // Sending it would create a real poll in the room root while the UI
      // claims it belongs to this thread, so fail before dispatch instead.
      if (key.threadId != null && room.isFederated) {
        throw const PollServiceException(PollServiceError.unsupported);
      }
      if (key.threadId != null) {
        final rootRow = await _chat.getMessage(
          accountId: key.accountId,
          roomToken: key.roomToken,
          messageId: key.threadId!,
        );
        if (rootRow == null) {
          throw const PollServiceException(PollServiceError.contextMissing);
        }
        final root = ChatMessage.fromJson(jsonDecode(rootRow.rawJson));
        if (root.messageId != key.threadId ||
            root.roomToken != room.token ||
            root.isThread != true ||
            root.threadId != key.threadId) {
          throw const PollServiceException(PollServiceError.contextMissing);
        }
      }
      final server = ServerBase.parse(account.serverUrl);
      final capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: password,
      );
      if (!capabilities.talkFeatures.contains('talk-polls') ||
          (key.threadId != null &&
              !capabilities.talkFeatures.contains('threads'))) {
        throw const PollServiceException(PollServiceError.unsupported);
      }
      return _PreparedPoll(
        server: server,
        room: room,
        loginName: account.loginName,
        appPassword: password,
      );
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

  Future<TalkPoll> _confirmed(
    PollResponse response,
    String accountId, {
    required bool dispatched,
  }) async {
    final poll = response.poll;
    if (response.classification == PollResponseClassification.confirmed &&
        poll != null) {
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
      PollResponseClassification.invalidInput ||
      PollResponseClassification.notFound => PollServiceError.invalidResponse,
      PollResponseClassification.serviceUnavailable =>
        dispatched ? PollServiceError.ambiguous : PollServiceError.unavailable,
      PollResponseClassification.confirmed => PollServiceError.invalidResponse,
    });
  }
}

final class _PreparedPoll {
  const _PreparedPoll({
    required this.server,
    required this.room,
    required this.loginName,
    required this.appPassword,
  });
  final ServerBase server;
  final ConversationRoom room;
  final String loginName;
  final String appPassword;
}
