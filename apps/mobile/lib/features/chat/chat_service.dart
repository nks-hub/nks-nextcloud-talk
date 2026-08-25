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

final class _ChatSynchronizationCancelled implements Exception {
  const _ChatSynchronizationCancelled();
}

final class _ChatSynchronizationStale implements Exception {
  const _ChatSynchronizationStale();
}

final class _UnknownThreadNotFound implements Exception {
  const _UnknownThreadNotFound();
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
            final scope = await _chat.getScope(
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

  Future<void> sendText({
    required String accountId,
    required String roomToken,
    required String message,
    int? threadId,
  }) {
    final key = _roomKey(accountId, roomToken);
    return _serializeRoom<void>(key, () {
      return _withRoomErrorPersistence(accountId, roomToken, () async {
        final normalized = message.trim();
        if (normalized.isEmpty) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
        var prepared = await _prepare(accountId, roomToken, threadId: threadId);
        if (prepared.room.readOnly != 0) {
          throw const ChatServiceException(ChatServiceError.readOnly);
        }
        if (!prepared.profile.sendText) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }
        if (prepared.threadId != null && prepared.namedThread == null) {
          prepared = await _resolveAndSynchronizePrepared(prepared);
        }
        await _chat.admitTextSend(
          accountId: accountId,
          roomToken: prepared.room.token,
          authority: prepared.authority,
          operationId: ChatOperationId.parse(_uuid.v4()),
          referenceId: ChatReferenceId.parse(_uuid.v4()),
          message: normalized,
          replyTo: prepared.namedThread == true ? null : prepared.threadId,
          threadId: prepared.namedThread == true ? prepared.threadId : null,
          parentRoomToken:
              prepared.threadId == null || prepared.namedThread == true
              ? null
              : prepared.room.token,
        );
        await _processPending(prepared);
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

  Future<_PreparedChat> _prepare(
    String accountId,
    String roomToken, {
    int? threadId,
    Future<void>? abortTrigger,
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
    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
        abortTrigger: abortTrigger,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId);
      }
      throw ChatServiceException(_mapApiError(error));
    }
    if (!capabilities.hasTalk) {
      throw const ChatServiceException(ChatServiceError.talkUnavailable);
    }
    final sortedTalkFeatures = capabilities.talkFeatures.toList()..sort();
    final capabilityFingerprint = jsonEncode(sortedTalkFeatures);
    await _accounts.updateTalkFeatures(accountId, capabilities.talkFeatures);
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    final profile = ChatCapabilityProfile.fromSnapshot(
      capabilities,
      federated: room.isFederated,
    );
    if (!profile.read) {
      throw const ChatServiceException(ChatServiceError.chatUnsupported);
    }
    final namedThread = threadId == null
        ? null
        : await _chat.cachedRootIsNamedThread(
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
    final storedCapability = await _chat.recordCapabilities(
      accountId: accountId,
      talkFeatures: capabilities.talkFeatures,
      observedAt: DateTime.now().toUtc(),
    );
    if (threadId == null || networkThreadId == null) {
      await _chat.ensureRootScope(account: account, conversation: conversation);
    }
    if (threadId != null) {
      await _chat.ensureThreadScope(
        account: account,
        conversation: conversation,
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
      capabilityFingerprint: capabilityFingerprint,
      authority: ChatTextSendAuthority(
        accountId: AccountId.parse(accountId),
        server: server,
        capabilityGeneration: storedCapability.generation,
        profile: profile,
        replayContractRevision: textSendReplayContractRevision,
      ),
    );
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
      final classification = await _chat.cachedRootIsNamedThread(
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
    final classification = await _chat.cachedRootIsNamedThread(
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
    var scope = (await _chat.getScope(
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
    scope = (await _chat.getScope(
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
    final scope = (await _chat.getScope(
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
      final scope = (await _chat.getScope(
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

  Future<void> _synchronizeLiveBinding(
    ChatLiveRoomBinding binding,
    _LiveSynchronizationCancellation cancellation,
  ) async {
    final probe = _ChatSynchronizationProbe(
      binding: binding,
      generation: binding._generation,
      cancellation: cancellation,
    );
    try {
      final prepared = binding._prepared;
      if (prepared == null) {
        await _initializeLiveBinding(binding, probe);
      } else {
        await _pollLiveBinding(binding, prepared, probe);
      }
    } on _ChatSynchronizationCancelled {
      // Lifecycle cancellation is an expected control-flow event.
    } on _ChatSynchronizationStale {
      binding._prepared = null;
    }
  }

  Future<void> _initializeLiveBinding(
    ChatLiveRoomBinding binding,
    _ChatSynchronizationProbe probe,
  ) async {
    late _PreparedChat prepared;
    await _withRoomErrorPersistence(
      binding.accountId,
      binding.roomToken,
      () async {
        prepared = await _prepare(
          binding.accountId,
          binding.roomToken,
          threadId: binding.threadId,
          abortTrigger: probe.abortTrigger,
        );
        probe.ensureActive();
        prepared = await _initializePreparedLiveBinding(
          binding,
          prepared,
          probe,
        );
      },
      threadId: binding.threadId,
    );
    probe.ensureActive();
    binding._prepared = prepared;
  }

  Future<_PreparedChat> _initializePreparedLiveBinding(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
    _ChatSynchronizationProbe probe,
  ) {
    return _serializeRoom<_PreparedChat>(
      _roomKey(binding.accountId, binding.roomToken),
      () async {
        probe.ensureActive();
        final resolved = await _resolveAndSynchronizePrepared(
          prepared,
          abortTrigger: probe.abortTrigger,
        );
        probe.ensureActive();
        return resolved;
      },
    );
  }

  Future<void> _pollLiveBinding(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
    _ChatSynchronizationProbe probe,
  ) async {
    _SharedLivePoll? poll;
    try {
      await _withRoomErrorPersistence(
        binding.accountId,
        binding.roomToken,
        () async {
          await _ensureLiveContextCurrent(binding, prepared, probe);
          poll = _joinLiveNetworkPoll(binding, prepared);
          final completed = await Future.any<bool>([
            poll!.operation.then((_) => true),
            probe.cancellation.then((_) => false),
          ]);
          if (!completed) {
            throw const _ChatSynchronizationCancelled();
          }
          probe.ensureActive();
          await _ensureLiveContextCurrent(binding, prepared, probe);
          await _projectPreparedViewState(prepared);
        },
        threadId: binding.threadId,
      );
    } finally {
      final joinedPoll = poll;
      if (joinedPoll != null) {
        _leaveLiveNetworkPoll(binding, joinedPoll);
      }
    }
  }

  _SharedLivePoll _joinLiveNetworkPoll(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
  ) {
    final key = _networkScopeKey(
      prepared.account.id,
      prepared.conversation.token,
      prepared.networkThreadId,
    );
    var poll = _liveNetworkPolls[key];
    if (poll != null &&
        (poll.cancelled || poll.completed || poll.abort.isCompleted)) {
      if (identical(_liveNetworkPolls[key], poll)) {
        _liveNetworkPolls.remove(key);
      }
      poll = null;
    }
    if (poll == null) {
      final abort = Completer<void>();
      final created = _SharedLivePoll(key: key, abort: abort);
      final operation = _runLiveNetworkPoll(prepared, created);
      created.operation = operation;
      _liveNetworkPolls[key] = created;
      operation.whenComplete(() {
        created.completed = true;
        if (identical(_liveNetworkPolls[key], created)) {
          _liveNetworkPolls.remove(key);
        }
      }).ignore();
      poll = created;
    }
    poll.bindings.add(binding);
    return poll;
  }

  void _leaveLiveNetworkPoll(
    ChatLiveRoomBinding binding,
    _SharedLivePoll poll,
  ) {
    poll.bindings.remove(binding);
    if (poll.bindings.isEmpty && !poll.completed && !poll.abort.isCompleted) {
      poll.cancelled = true;
      if (identical(_liveNetworkPolls[poll.key], poll)) {
        _liveNetworkPolls.remove(poll.key);
      }
      poll.abort.complete();
    }
  }

  Future<void> _runLiveNetworkPoll(
    _PreparedChat prepared,
    _SharedLivePoll poll,
  ) async {
    final scope = (await _chat.getScope(
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
      timeoutSeconds: scope.futureConverged ? 30 : 0,
      interactive: !prepared.profile.backgroundCatchUp,
      threadId: prepared.networkThreadId,
      futureConverged: scope.futureConverged,
    );

    // The network wait deliberately stays outside the room mutation tail.
    final response = await _api.getChat(
      chatRequest: request,
      loginName: prepared.account.loginName,
      appPassword: prepared.appPassword,
      abortTrigger: poll.abort.future,
    );
    await _serializeRoom<void>(
      _roomKey(prepared.account.id, prepared.conversation.token),
      () async {
        if (poll.cancelled || !identical(_liveNetworkPolls[poll.key], poll)) {
          throw const _ChatSynchronizationCancelled();
        }
        if (!await _preparedContextIsCurrent(prepared)) {
          throw const _ChatSynchronizationStale();
        }
        await _applyGetResponse(prepared, response);
      },
    );
  }

  Future<void> _ensureLiveContextCurrent(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
    _ChatSynchronizationProbe probe,
  ) async {
    probe.ensureActive();
    final current =
        binding.accountId == prepared.account.id &&
        binding.roomToken == prepared.conversation.token &&
        binding.threadId == prepared.threadId &&
        await _preparedContextIsCurrent(prepared);
    probe.ensureActive();
    if (!current) {
      throw const _ChatSynchronizationStale();
    }
  }

  Future<void> _ensurePreparedContextCurrent(_PreparedChat prepared) async {
    if (!await _preparedContextIsCurrent(prepared)) {
      throw const _ChatSynchronizationStale();
    }
  }

  Future<bool> _preparedContextIsCurrent(_PreparedChat prepared) async {
    final account = await _accounts.getAccount(prepared.account.id);
    final conversation = await _chat.getConversation(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
    );
    final capabilityCurrent = await _chat.isCapabilityGenerationCurrent(
      accountId: prepared.account.id,
      generation: prepared.authority.capabilityGeneration,
    );
    final conversationProfileCurrent = conversation == null
        ? false
        : _conversationIsFederated(conversation) == prepared.room.isFederated;
    final namedThread = prepared.threadId == null
        ? null
        : await _chat.cachedRootIsNamedThread(
            accountId: prepared.account.id,
            roomToken: prepared.conversation.token,
            threadId: prepared.threadId!,
          );
    final threadClassificationCurrent = switch (prepared.namedThread) {
      null when prepared.networkThreadId == null => namedThread != true,
      null => namedThread != false,
      false => namedThread != true,
      true => namedThread != false,
    };
    if (account == null || conversation == null) {
      return false;
    }
    return account.id == prepared.account.id &&
        account.serverUrl == prepared.account.serverUrl &&
        account.loginName == prepared.account.loginName &&
        account.talkFeaturesJson == prepared.capabilityFingerprint &&
        conversation.accountId == prepared.conversation.accountId &&
        conversation.token == prepared.conversation.token &&
        conversationProfileCurrent &&
        threadClassificationCurrent &&
        capabilityCurrent;
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
    await _projectPreparedViewState(prepared);
  }

  Future<void> _projectPreparedViewState(_PreparedChat prepared) async {
    final viewThreadId = prepared.threadId;
    if (viewThreadId != null && viewThreadId != prepared.networkThreadId) {
      await _chat.projectNetworkScopeState(
        accountId: prepared.account.id,
        roomToken: prepared.conversation.token,
        networkThreadId: prepared.networkThreadId,
        viewThreadId: viewThreadId,
      );
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

final class ChatLiveRoomBinding {
  ChatLiveRoomBinding._({
    required ChatService service,
    required this.accountId,
    required this.roomToken,
    required this.threadId,
  }) : _service = service;

  final ChatService _service;
  final String accountId;
  final String roomToken;
  final int? threadId;

  _PreparedChat? _prepared;
  Future<void>? _inFlight;
  _LiveSynchronizationCancellation? _activeCancellationCycle;
  Future<void>? _externalCancellation;
  bool _closed = false;
  int _generation = 0;

  Future<void> synchronize({Future<void>? abortTrigger}) {
    if (_closed) {
      return Future<void>.value();
    }
    _bindExternalCancellation(abortTrigger);
    final existing = _inFlight;
    if (existing != null) {
      return existing;
    }
    final cancellation = _LiveSynchronizationCancellation();
    _activeCancellationCycle = cancellation;
    late final Future<void> operation;
    operation = _service
        ._synchronizeLiveBinding(this, cancellation)
        .whenComplete(() {
          cancellation.release();
          if (identical(_activeCancellationCycle, cancellation)) {
            _activeCancellationCycle = null;
          }
          if (identical(_inFlight, operation)) {
            _inFlight = null;
          }
        });
    _inFlight = operation;
    return operation;
  }

  void close() {
    _cancelLifecycle();
  }

  @visibleForTesting
  int get debugActiveCancellationCycleCount =>
      _activeCancellationCycle == null ? 0 : 1;

  void _bindExternalCancellation(Future<void>? cancellation) {
    if (cancellation == null) {
      return;
    }
    final existing = _externalCancellation;
    if (existing != null) {
      if (!identical(existing, cancellation)) {
        throw StateError(
          'A live binding cannot change its cancellation signal',
        );
      }
      return;
    }
    _externalCancellation = cancellation;
    cancellation
        .then<void>(
          (_) => _cancelLifecycle(),
          onError: (Object _, StackTrace _) => _cancelLifecycle(),
        )
        .ignore();
  }

  void _cancelLifecycle() {
    if (_closed) {
      return;
    }
    _closed = true;
    _generation++;
    _activeCancellationCycle?.cancel();
  }
}

final class _LiveSynchronizationCancellation {
  final Completer<void> _completion = Completer<void>();
  bool _cancelled = false;

  Future<void> get future => _completion.future;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _complete();
  }

  void release() {
    _complete();
  }

  void _complete() {
    if (!_completion.isCompleted) {
      _completion.complete();
    }
  }
}

final class _SharedLivePoll {
  _SharedLivePoll({required this.key, required this.abort});

  final String key;
  final Completer<void> abort;
  late final Future<void> operation;
  final Set<ChatLiveRoomBinding> bindings = {};
  bool cancelled = false;
  bool completed = false;
}

final class _ChatSynchronizationProbe {
  _ChatSynchronizationProbe({
    required this.binding,
    required this.generation,
    required _LiveSynchronizationCancellation cancellation,
  }) : _cancellation = cancellation;

  final ChatLiveRoomBinding binding;
  final int generation;
  final _LiveSynchronizationCancellation _cancellation;

  Future<void> get cancellation => _cancellation.future;

  Future<void> get abortTrigger => _cancellation.future;

  void ensureActive() {
    if (_cancellation.cancelled ||
        binding._closed ||
        binding._generation != generation) {
      throw const _ChatSynchronizationCancelled();
    }
  }
}

final class _PreparedChat {
  const _PreparedChat({
    required this.account,
    required this.conversation,
    required this.room,
    required this.threadId,
    required this.networkThreadId,
    required this.namedThread,
    required this.appPassword,
    required this.profile,
    required this.capabilityFingerprint,
    required this.authority,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final ConversationRoom room;
  final int? threadId;
  final int? networkThreadId;
  final bool? namedThread;
  final String appPassword;
  final ChatCapabilityProfile profile;
  final String capabilityFingerprint;
  final ChatTextSendAuthority authority;

  _PreparedChat asRootBackedView() => _PreparedChat(
    account: account,
    conversation: conversation,
    room: room,
    threadId: threadId,
    networkThreadId: null,
    namedThread: false,
    appPassword: appPassword,
    profile: profile,
    capabilityFingerprint: capabilityFingerprint,
    authority: authority,
  );

  _PreparedChat asNamedThread() => _PreparedChat(
    account: account,
    conversation: conversation,
    room: room,
    threadId: threadId,
    networkThreadId: threadId,
    namedThread: true,
    appPassword: appPassword,
    profile: profile,
    capabilityFingerprint: capabilityFingerprint,
    authority: authority,
  );
}

bool _conversationIsFederated(CachedConversation conversation) {
  try {
    return ConversationRoom.fromJson(
      jsonDecode(conversation.rawJson),
    ).isFederated;
  } on FormatException {
    throw const ChatServiceException(ChatServiceError.invalidResponse);
  }
}

ChatServiceError _mapApiError(NextcloudApiException error) {
  return switch (error.statusCode) {
    401 => ChatServiceError.reauthenticationRequired,
    429 => ChatServiceError.rateLimited,
    500 || 502 || 503 || 504 => ChatServiceError.serviceUnavailable,
    _ => switch (error.code) {
      NextcloudApiError.network ||
      NextcloudApiError.timeout => ChatServiceError.network,
      NextcloudApiError.cancelled =>
        throw const _ChatSynchronizationCancelled(),
      NextcloudApiError.responseTooLarge ||
      NextcloudApiError.invalidJson ||
      NextcloudApiError.invalidAvatarUri ||
      NextcloudApiError.invalidAvatarResponse ||
      NextcloudApiError.invalidWebPushResponse ||
      NextcloudApiError.unexpectedStatus => ChatServiceError.invalidResponse,
    },
  };
}

int _nowSeconds() =>
    DateTime.now().toUtc().millisecondsSinceEpoch ~/
    Duration.millisecondsPerSecond;

String _roomKey(String accountId, String roomToken) =>
    '$accountId\u0000$roomToken';

String _scopeSyncKey(String accountId, String roomToken, int? threadId) =>
    '${_roomKey(accountId, roomToken)}\u0000${threadId ?? 'root'}';

String _networkScopeKey(String accountId, String roomToken, int? threadId) =>
    '${_scopeSyncKey(accountId, roomToken, threadId)}\u0000network';
