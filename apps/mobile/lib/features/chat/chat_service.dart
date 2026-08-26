// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import 'outgoing_message_status.dart';

part 'chat_service_models.dart';
part 'chat_service_private_reply.dart';
part 'chat_service_runtime.dart';

enum ChatServiceError {
  accountMissing,
  conversationMissing,
  credentialMissing,
  talkUnavailable,
  chatUnsupported,
  sendUnsupported,
  readOnly,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class ChatServiceException implements Exception {
  const ChatServiceException(this.code);

  final ChatServiceError code;

  @override
  String toString() => 'ChatServiceException(${code.name})';
}

final class ChatService {
  ChatService({
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

  static const int _pageSize = 100;
  static const int _maximumCatchUpPages = 12;

  /// Upper bound for [catchUpRoom] joining a live poll. A long poll normally
  /// answers the moment the room changes, so this only stops a background
  /// reconciler from waiting out an idle 30 s poll.
  static const Duration _livePollJoinTimeout = Duration(seconds: 3);

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;
  final Map<String, Future<void>> _roomTails = {};
  final Map<String, Future<void>> _syncInFlight = {};
  final Map<String, _SharedLivePoll> _liveNetworkPolls = {};

  Stream<List<OutgoingMessageStatus>> watchOutgoingMessageStatuses({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    return _chat
        .watchOutgoingTextMessages(
          accountId: accountId,
          roomToken: roomToken,
          threadId: threadId,
        )
        .map(
          (projections) => projections
              .expand(resolveOutgoingMessageStatuses)
              .toList(growable: false),
        );
  }

  ChatLiveRoomBinding bindLiveRoom({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    return ChatLiveRoomBinding._(
      service: this,
      accountId: accountId,
      roomToken: roomToken,
      threadId: threadId,
    );
  }

  Future<void> syncRoom({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    final key = _scopeSyncKey(accountId, roomToken, threadId);
    final existing = _syncInFlight[key];
    if (existing != null) {
      return existing;
    }
    late final Future<void> operation;
    operation = _serializeRoom<void>(_roomKey(accountId, roomToken), () async {
      await _withRoomErrorPersistence(accountId, roomToken, () async {
        try {
          final prepared = await _prepare(
            accountId,
            roomToken,
            threadId: threadId,
          );
          await _resolveAndSynchronizePrepared(prepared);
        } on _ChatSynchronizationStale {
          return;
        }
      }, threadId: threadId);
    });
    _syncInFlight[key] = operation;
    operation.whenComplete(() {
      if (identical(_syncInFlight[key], operation)) {
        _syncInFlight.remove(key);
      }
    }).ignore();
    return operation;
  }

  /// Brings a room up to date for a background reconciler, such as the
  /// attachment confirmation loop waiting for its own `file_shared` message.
  ///
  /// An open room already polls the same scope, and that poll reads the same
  /// server state a fresh request would. Racing it costs a second request and
  /// makes the poll's own answer arrive against a moved cursor, where it is
  /// discarded as stale and repeated. Joining it costs nothing and observes
  /// exactly the same messages. Interactive callers keep using [syncRoom],
  /// which never waits on somebody else's poll.
  Future<void> catchUpRoom({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) async {
    if (await _awaitLiveNetworkPoll(accountId, roomToken, threadId)) {
      return;
    }
    return syncRoom(
      accountId: accountId,
      roomToken: roomToken,
      threadId: threadId,
    );
  }

  Future<void> loadOlder({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    final key = _roomKey(accountId, roomToken);
    return _serializeRoom<void>(key, () {
      return _withRoomErrorPersistence(accountId, roomToken, () async {
        try {
          var prepared = await _prepare(
            accountId,
            roomToken,
            threadId: threadId,
          );
          if (prepared.threadId != null &&
              prepared.namedThread == null &&
              prepared.networkThreadId == null) {
            prepared = await _hydrateUnknownThreadFromRoot(prepared);
          }
          try {
            final scope = await _chat.getNetworkScope(
              accountId: accountId,
              roomToken: roomToken,
              threadId: prepared.networkThreadId,
            );
            if (scope?.hasHistory ?? false) {
              await _fetchHistoryPage(prepared, includeLastKnown: false);
            }
          } on _UnknownThreadNotFound {
            await _hydrateUnknownThreadFromRoot(prepared);
          }
        } on _ChatSynchronizationStale {
          return;
        }
      }, threadId: threadId);
    });
  }

  /// [replyTo] answers a specific root message. Talk turns that into a thread,
  /// so it is mutually exclusive with sending inside an existing [threadId].
  Future<void> sendText({
    required String accountId,
    required String roomToken,
    required String message,
    int? threadId,
    int? replyTo,
    String? replyToToken,
    PrivateReplyEligibilitySnapshot? privateReplyEligibility,
  }) {
    final key = _roomKey(accountId, roomToken);
    return _serializeRoom<void>(key, () {
      return _withRoomErrorPersistence(accountId, roomToken, () async {
        final normalized = message.trim();
        if (normalized.isEmpty) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
        if (replyTo == null &&
            (replyToToken != null || privateReplyEligibility != null)) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
        if (replyTo != null && (threadId != null || replyTo < 1)) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
        var prepared = await _prepare(
          accountId,
          roomToken,
          threadId: threadId,
          allowPersistedCapabilitiesForSend: true,
        );
        if (replyTo != null && !prepared.profile.reply) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }
        if (prepared.room.readOnly != 0) {
          throw const ChatServiceException(ChatServiceError.readOnly);
        }
        if (!prepared.profile.sendText) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }
        if (prepared.threadId != null && prepared.namedThread == null) {
          if (!prepared.capabilitiesVerifiedOnline) {
            throw const ChatServiceException(ChatServiceError.network);
          }
          prepared = await _resolveAndSynchronizePrepared(prepared);
        }
        final effectiveReplyTo =
            replyTo ??
            (prepared.namedThread == true ? null : prepared.threadId);
        final parentRoomToken = effectiveReplyTo == null
            ? null
            : replyToToken == null
            ? prepared.room.token
            : ConversationToken.parse(replyToToken, path: r'$.replyToToken');
        final crossRoomReply =
            parentRoomToken != null && parentRoomToken != prepared.room.token;
        if (crossRoomReply) {
          final eligibility = privateReplyEligibility;
          if (!prepared.profile.privateReply ||
              eligibility == null ||
              !eligibility.matchesAdmission(
                accountId: prepared.authority.accountId,
                server: prepared.authority.server,
                capabilityGeneration: prepared.authority.capabilityGeneration,
                sourceRoomToken: parentRoomToken,
                targetRoomToken: prepared.room.token,
                parentMessageId: effectiveReplyTo!,
              )) {
            throw const ChatServiceException(ChatServiceError.sendUnsupported);
          }
        } else if (replyToToken != null || privateReplyEligibility != null) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
        await _chat.admitTextSend(
          accountId: accountId,
          roomToken: prepared.room.token,
          authority: prepared.authority,
          operationId: ChatOperationId.parse(_uuid.v4()),
          referenceId: ChatReferenceId.parse(_uuid.v4()),
          message: normalized,
          replyTo: effectiveReplyTo,
          threadId: prepared.namedThread == true ? prepared.threadId : null,
          replyToToken: crossRoomReply ? parentRoomToken : null,
          parentRoomToken: parentRoomToken,
          privateReplyEligibility: privateReplyEligibility,
        );
        if (prepared.capabilitiesVerifiedOnline) {
          await _processPending(prepared);
        }
      }, threadId: threadId);
    });
  }

  Future<void> resendText({
    required String accountId,
    required String roomToken,
    required String operationId,
  }) {
    final key = _roomKey(accountId, roomToken);
    return _serializeRoom<void>(key, () {
      return _withRoomErrorPersistence(accountId, roomToken, () async {
        final prepared = await _prepare(accountId, roomToken);
        final claim = await _chat.manuallyResend(
          accountId: accountId,
          operationId: ChatOperationId.parse(operationId),
          authority: prepared.authority,
          requestId: ChatRequestId.parse(_uuid.v4()),
        );
        if (claim == null) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
        await _transmitClaim(prepared, claim);
      });
    });
  }

  /// Removes a pending outbox operation. Returns `false` when the send may
  /// already have reached the server, in which case nothing was cancelled and
  /// the caller has to tell the user instead of pretending otherwise.
  ///
  /// Local only: no request is made and no room sync error is recorded, and
  /// the room lane keeps a claim from racing the gate.
  Future<bool> cancelText({
    required String accountId,
    required String roomToken,
    required String operationId,
  }) {
    return _serializeRoom<bool>(_roomKey(accountId, roomToken), () {
      return _chat.cancelTextSend(
        accountId: accountId,
        operationId: operationId,
      );
    });
  }

  Future<bool?> _validatedCachedRootIsNamedThread({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) async {
    try {
      return await _chat.validatedCachedRootIsNamedThread(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
      );
    } on InvalidCachedThreadRootException {
      throw const ChatServiceException(ChatServiceError.invalidResponse);
    }
  }

  Future<_PreparedChat> _prepare(
    String accountId,
    String roomToken, {
    int? threadId,
    Future<void>? abortTrigger,
    bool allowPersistedCapabilitiesForSend = false,
    bool forceCapabilityNetworkRead = false,
  }) async {
    if (threadId != null && threadId < 1) {
      throw const ChatServiceException(ChatServiceError.invalidResponse);
    }
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const ChatServiceException(ChatServiceError.accountMissing);
    }
    final conversation = await _chat.getConversation(
      accountId: accountId,
      roomToken: roomToken,
    );
    if (conversation == null) {
      throw const ChatServiceException(ChatServiceError.conversationMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const ChatServiceException(ChatServiceError.credentialMissing);
    }
    final server = ServerBase.parse(account.serverUrl);
    final preparedCapabilities = await _prepareCapabilities(
      account: account,
      server: server,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
      allowPersistedCapabilitiesForSend: allowPersistedCapabilitiesForSend,
      forceNetworkRead: forceCapabilityNetworkRead,
    );
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    final profile = ChatCapabilityProfile.fromTalkFeatures(
      preparedCapabilities.talkFeatures.toList(growable: false),
      federated: room.isFederated,
    );
    if (!profile.read) {
      throw const ChatServiceException(ChatServiceError.chatUnsupported);
    }
    final namedThread = threadId == null
        ? null
        : await _validatedCachedRootIsNamedThread(
            accountId: accountId,
            roomToken: conversation.token,
            threadId: threadId,
          );
    final networkThreadId = switch (namedThread) {
      false => null,
      true => threadId,
      null => profile.threadFetch ? threadId : null,
    };
    if (namedThread == true && !profile.threadFetch) {
      throw const ChatServiceException(ChatServiceError.chatUnsupported);
    }
    await _chat.ensureRootScope(account: account, conversation: conversation);
    if (threadId != null) {
      await _chat.ensureThreadScope(
        account: account,
        conversation: conversation,
        threadId: threadId,
      );
    }
    if (networkThreadId != null) {
      await _chat.ensureNamedThreadNetworkScope(
        account: account,
        conversation: conversation,
        threadId: networkThreadId,
      );
    } else if (threadId != null && namedThread == false) {
      await _chat.retireNamedThreadNetworkScope(
        accountId: account.id,
        roomToken: conversation.token,
        threadId: threadId,
      );
    }
    return _PreparedChat(
      account: account,
      conversation: conversation,
      room: room,
      threadId: threadId,
      networkThreadId: networkThreadId,
      namedThread: namedThread,
      appPassword: appPassword,
      profile: profile,
      capabilityFingerprint: preparedCapabilities.fingerprint,
      capabilitiesVerifiedOnline: preparedCapabilities.verifiedOnline,
      authority: ChatTextSendAuthority(
        accountId: AccountId.parse(accountId),
        server: server,
        capabilityGeneration: preparedCapabilities.generation,
        profile: profile,
        replayContractRevision: textSendReplayContractRevision,
      ),
    );
  }

  Future<_PreparedCapabilities> _prepareCapabilities({
    required StoredAccount account,
    required ServerBase server,
    required String appPassword,
    required Future<void>? abortTrigger,
    required bool allowPersistedCapabilitiesForSend,
    required bool forceNetworkRead,
  }) async {
    try {
      final capabilityRead = await _api.getAuthenticatedCapabilitiesWithSource(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
        abortTrigger: abortTrigger,
        forceRefresh: allowPersistedCapabilitiesForSend || forceNetworkRead,
      );
      final capabilities = capabilityRead.snapshot;
      if (!capabilities.hasTalk) {
        throw const ChatServiceException(ChatServiceError.talkUnavailable);
      }
      final sortedTalkFeatures = capabilities.talkFeatures.toList()..sort();
      final fingerprint = jsonEncode(sortedTalkFeatures);
      await _accounts.updateTalkFeatures(account.id, capabilities.talkFeatures);
      final storedCapability = await _chat.recordCapabilities(
        accountId: account.id,
        talkFeatures: capabilities.talkFeatures,
        observedAt: DateTime.now().toUtc(),
      );
      return _PreparedCapabilities(
        talkFeatures: capabilities.talkFeatures,
        fingerprint: fingerprint,
        generation: storedCapability.generation,
        verifiedOnline:
            capabilityRead.source == CapabilitySnapshotSource.network,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(account.id);
      }
      if (allowPersistedCapabilitiesForSend &&
          _isTransientCapabilityFailure(error)) {
        final persisted = await _loadPersistedCapabilities(account);
        if (persisted != null) {
          return persisted;
        }
      }
      throw ChatServiceException(_mapApiError(error));
    }
  }

  Future<_PreparedCapabilities?> _loadPersistedCapabilities(
    StoredAccount account,
  ) async {
    final stored = await _chat.getReadyCapabilitySnapshot(account.id);
    if (stored == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(account.talkFeaturesJson);
      if (decoded is! List<Object?> ||
          !decoded.every((feature) => feature is String)) {
        return null;
      }
      final talkFeatures = decoded.cast<String>().toList(growable: false);
      final profile = ChatCapabilityProfile.fromTalkFeatures(
        talkFeatures,
        federated: false,
      );
      if (!profile.sendText) {
        return null;
      }
      final sortedTalkFeatures = talkFeatures.toList()..sort();
      final fingerprint = jsonEncode(sortedTalkFeatures);
      if (account.talkFeaturesJson != fingerprint ||
          stored.fingerprint != fingerprint ||
          stored.generation < 1) {
        return null;
      }
      return _PreparedCapabilities(
        talkFeatures: sortedTalkFeatures.toSet(),
        fingerprint: fingerprint,
        generation: stored.generation,
        verifiedOnline: false,
      );
    } on FormatException {
      return null;
    } on TalkProtocolException {
      return null;
    }
  }

  Future<_PreparedChat> _resolveAndSynchronizePrepared(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
  }) async {
    var resolved = prepared;
    if (resolved.threadId != null &&
        resolved.namedThread == null &&
        resolved.networkThreadId == null) {
      resolved = await _hydrateUnknownThreadFromRoot(
        resolved,
        abortTrigger: abortTrigger,
      );
    }
    try {
      await _synchronizePrepared(resolved, abortTrigger: abortTrigger);
    } on _UnknownThreadNotFound {
      resolved = await _hydrateUnknownThreadFromRoot(
        resolved,
        abortTrigger: abortTrigger,
      );
      await _synchronizePrepared(resolved, abortTrigger: abortTrigger);
    }
    if (resolved.threadId != null && resolved.namedThread == null) {
      resolved = resolved.asNamedThread();
    }
    return resolved;
  }

  Future<_PreparedChat> _hydrateUnknownThreadFromRoot(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
  }) async {
    final threadId = prepared.threadId;
    if (threadId == null) {
      return prepared;
    }
    await _chat.ensureRootScope(
      account: prepared.account,
      conversation: prepared.conversation,
    );
    final rootPrepared = prepared.asRootBackedView();
    for (var page = 0; page < _maximumCatchUpPages; page++) {
      final classification = await _validatedCachedRootIsNamedThread(
        accountId: prepared.account.id,
        roomToken: prepared.conversation.token,
        threadId: threadId,
      );
      if (classification != null) {
        break;
      }
      final scope = (await _chat.getRootScope(
        accountId: prepared.account.id,
        roomToken: prepared.conversation.token,
      ))!;
      if (!scope.hasHistory) {
        break;
      }
      await _fetchHistoryPage(
        rootPrepared,
        includeLastKnown: scope.lastSyncedAtMillis == null,
        abortTrigger: abortTrigger,
      );
    }
    final classification = await _validatedCachedRootIsNamedThread(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: threadId,
    );
    if (classification == false) {
      return rootPrepared;
    }
    if (classification == true && !prepared.profile.threadFetch) {
      throw const ChatServiceException(ChatServiceError.chatUnsupported);
    }
    throw const ChatServiceException(ChatServiceError.invalidResponse);
  }

  Future<void> _synchronizePrepared(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
  }) async {
    await _chat.recoverInterruptedTextSends(prepared.account.id);
    var scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    if (scope.lastSyncedAtMillis == null) {
      await _fetchHistoryPage(
        prepared,
        includeLastKnown: true,
        abortTrigger: abortTrigger,
      );
    }
    await _catchUpFuture(prepared, abortTrigger: abortTrigger);
    await _processPending(prepared);
    scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    if (!scope.futureConverged) {
      await _catchUpFuture(prepared, abortTrigger: abortTrigger);
    }
  }

  Future<void> _fetchHistoryPage(
    _PreparedChat prepared, {
    required bool includeLastKnown,
    Future<void>? abortTrigger,
  }) async {
    await _ensurePreparedContextCurrent(prepared);
    final scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    if (!scope.hasHistory) {
      return;
    }
    final request = ChatFetchRequest(
      accountId: AccountId.parse(prepared.account.id),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: prepared.authority.server,
      roomToken: prepared.room.token,
      profile: prepared.profile,
      direction: ChatFetchDirection.history,
      cursor: ChatCursor.parse(scope.historyCursor),
      lastCommonRead: ChatCursor.parse(scope.lastCommonRead),
      limit: _pageSize,
      includeLastKnown: includeLastKnown,
      timeoutSeconds: 0,
      interactive: true,
      threadId: prepared.networkThreadId,
      futureConverged: scope.futureConverged,
    );
    final response = await _api.getChat(
      chatRequest: request,
      loginName: prepared.account.loginName,
      appPassword: prepared.appPassword,
      abortTrigger: abortTrigger,
    );
    await _ensurePreparedContextCurrent(prepared);
    await _applyGetResponse(prepared, response);
  }

  Future<void> _catchUpFuture(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
  }) async {
    for (var page = 0; page < _maximumCatchUpPages; page++) {
      await _ensurePreparedContextCurrent(prepared);
      final scope = (await _chat.getNetworkScope(
        accountId: prepared.account.id,
        roomToken: prepared.conversation.token,
        threadId: prepared.networkThreadId,
      ))!;
      final request = ChatFetchRequest(
        accountId: AccountId.parse(prepared.account.id),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: prepared.authority.server,
        roomToken: prepared.room.token,
        profile: prepared.profile,
        direction: ChatFetchDirection.future,
        cursor: ChatCursor.parse(scope.futureCursor),
        lastCommonRead: ChatCursor.parse(scope.lastCommonRead),
        limit: _pageSize,
        includeLastKnown: false,
        timeoutSeconds: 0,
        interactive: true,
        threadId: prepared.networkThreadId,
        futureConverged: scope.futureConverged,
      );
      final response = await _api.getChat(
        chatRequest: request,
        loginName: prepared.account.loginName,
        appPassword: prepared.appPassword,
        abortTrigger: abortTrigger,
      );
      await _ensurePreparedContextCurrent(prepared);
      await _applyGetResponse(prepared, response);
      if (response.classification == ChatGetClassification.notModified ||
          response.classification == ChatGetClassification.commonReadOnly) {
        return;
      }
    }
  }

  Future<void> _applyGetResponse(
    _PreparedChat prepared,
    ChatGetResponse response,
  ) async {
    if (response.classification == ChatGetClassification.threadNotFound &&
        prepared.threadId != null &&
        prepared.networkThreadId != null &&
        prepared.namedThread == null) {
      throw const _UnknownThreadNotFound();
    }
    final outcome = await _chat.applyChatGetResponse(response);
    switch (response.classification) {
      case ChatGetClassification.reauthenticationRequired:
        throw const ChatServiceException(
          ChatServiceError.reauthenticationRequired,
        );
      case ChatGetClassification.transientError:
        throw const ChatServiceException(ChatServiceError.serviceUnavailable);
      case ChatGetClassification.threadNotFound:
      case ChatGetClassification.ocsError:
        throw const ChatServiceException(ChatServiceError.invalidResponse);
      case ChatGetClassification.messages:
      case ChatGetClassification.invisibleCursorAdvance:
      case ChatGetClassification.commonReadOnly:
      case ChatGetClassification.notModified:
        if (outcome == ChatMergeOutcome.rejected) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
    }
  }

  Future<void> _processPending(_PreparedChat prepared) async {
    while (true) {
      final claim = await _chat.claimNextTextSend(
        accountId: prepared.account.id,
        roomToken: prepared.room.token,
        authority: prepared.authority,
        requestId: ChatRequestId.parse(_uuid.v4()),
        now: _nowSeconds(),
      );
      if (claim == null) {
        return;
      }
      await _transmitClaim(prepared, claim);
    }
  }

  Future<void> _transmitClaim(
    _PreparedChat prepared,
    ClaimedTextSend claim,
  ) async {
    final ChatSendResponse response;
    try {
      response = await _api.sendChat(
        chatRequest: claim.request,
        loginName: prepared.account.loginName,
        appPassword: prepared.appPassword,
      );
    } on NextcloudApiException {
      await _chat.recordTextSendFailure(
        accountId: prepared.account.id,
        operationId: claim.operation.operationId,
        bodyState: ChatTransportBodyState.possiblySent,
      );
      return;
    } on TalkProtocolException {
      await _chat.recordTextSendFailure(
        accountId: prepared.account.id,
        operationId: claim.operation.operationId,
        bodyState: ChatTransportBodyState.possiblySent,
      );
      return;
    }
    final outcome = await _chat.applyTextSendResponse(
      accountId: prepared.account.id,
      operationId: claim.operation.operationId,
      response: response,
      now: _nowSeconds(),
    );
    if (outcome == ChatOutboxOutcome.reauthenticationRequired) {
      await _chat.recordRoomError(
        accountId: prepared.account.id,
        roomToken: prepared.room.token.value,
        threadId: claim.operation.threadId ?? claim.operation.replyTo,
        errorCode: ChatServiceError.reauthenticationRequired.name,
      );
    }
  }

  Future<T> _withRoomErrorPersistence<T>(
    String accountId,
    String roomToken,
    Future<T> Function() action, {
    int? threadId,
  }) async {
    try {
      final result = await action();
      await _chat.clearRoomError(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
      );
      return result;
    } on ChatServiceException catch (error) {
      await _chat.recordRoomError(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
        errorCode: error.code.name,
      );
      rethrow;
    } on NextcloudApiException catch (error) {
      final mapped = ChatServiceException(_mapApiError(error));
      await _chat.recordRoomError(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
        errorCode: mapped.code.name,
      );
      throw mapped;
    } on TalkProtocolException {
      await _chat.recordRoomError(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
        errorCode: ChatServiceError.invalidResponse.name,
      );
      throw const ChatServiceException(ChatServiceError.invalidResponse);
    }
  }

  Future<T> _serializeRoom<T>(String key, Future<T> Function() action) async {
    final previous = _roomTails[key];
    final gate = Completer<void>();
    final tail = gate.future;
    _roomTails[key] = tail;
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // A failed earlier operation must not permanently block this room.
      }
    }
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_roomTails[key], tail)) {
        _roomTails.remove(key);
      }
    }
  }
}
