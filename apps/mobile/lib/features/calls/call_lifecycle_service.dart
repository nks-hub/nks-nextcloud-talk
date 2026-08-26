import 'dart:async';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/call_session_repository.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

typedef CallConversationSessionRefresh =
    Future<ConversationSessionId?> Function(String accountId, String roomToken);

typedef CallLifecycleKey = ({String accountId, String roomToken});

enum CallLifecycleError {
  accountMissing,
  credentialMissing,
  roomMissing,
  unsupported,
  consentRequired,
  forbidden,
  rejected,
  conflict,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
  network,
  invalidResponse,
  notJoined,
  uncertain,
}

final class CallLifecycleException implements Exception {
  const CallLifecycleException(this.code);

  final CallLifecycleError code;

  @override
  String toString() => 'CallLifecycleException(${code.name})';
}

final class CallLifecycleStatus {
  CallLifecycleStatus({
    required this.ownSessionPresent,
    required Iterable<CallPeer> peers,
    required this.state,
  }) : peers = List.unmodifiable(peers);

  final bool ownSessionPresent;
  final List<CallPeer> peers;
  final CallLifecycleState? state;

  @override
  String toString() =>
      'CallLifecycleStatus(ownSessionPresent: $ownSessionPresent, '
      'peers: ${peers.length}, phase: ${state?.phase.name}, '
      'sensitive: <redacted>)';
}

/// Serializes Talk's v4 call REST lifecycle per account and room.
///
/// Every mutation writes its intent before network dispatch. A transport
/// failure, invalid 2xx body or 5xx response is therefore retained as an
/// uncertain durable state instead of being retried blindly.
final class CallLifecycleService {
  factory CallLifecycleService({
    required AccountRepository accounts,
    required ChatRepository chat,
    required CallLifecycleSessionRepository sessions,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    required CallConversationSessionRefresh refreshConversationSession,
    DateTime Function()? now,
  }) => CallLifecycleService._(
    accounts: accounts,
    chat: chat,
    sessions: sessions,
    credentials: credentials,
    api: api,
    refreshConversationSession: refreshConversationSession,
    now: now,
  );

  CallLifecycleService._({
    required this._accounts,
    required this._chat,
    required this._sessions,
    required this._credentials,
    required this._api,
    required this._refreshConversationSession,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final CallLifecycleSessionRepository _sessions;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final CallConversationSessionRefresh _refreshConversationSession;
  final DateTime Function() _now;

  final Map<CallLifecycleKey, Future<void>> _tails = {};

  Future<CallLifecycleState> join({
    required String accountId,
    required String roomToken,
    CallInCallFlags? flags,
    bool silent = false,
    bool recordingConsent = false,
    Iterable<ConversationSessionId> silentFor = const [],
  }) => _serialize(
    accountId: accountId,
    roomToken: roomToken,
    operation: () => _join(
      accountId: accountId,
      roomToken: roomToken,
      flags: flags ?? CallInCallFlags.audioVideo(),
      silent: silent,
      recordingConsent: recordingConsent,
      silentFor: silentFor,
    ),
  );

  Future<CallLifecycleState> updateFlags({
    required String accountId,
    required String roomToken,
    required CallInCallFlags flags,
  }) => _serialize(
    accountId: accountId,
    roomToken: roomToken,
    operation: () =>
        _updateFlags(accountId: accountId, roomToken: roomToken, flags: flags),
  );

  Future<void> leave({
    required String accountId,
    required String roomToken,
    bool endForEveryone = false,
  }) => _serialize(
    accountId: accountId,
    roomToken: roomToken,
    operation: () => _leave(
      accountId: accountId,
      roomToken: roomToken,
      endForEveryone: endForEveryone,
    ),
  );

  Future<CallLifecycleStatus> status({
    required String accountId,
    required String roomToken,
  }) => _serialize(
    accountId: accountId,
    roomToken: roomToken,
    operation: () => _status(accountId: accountId, roomToken: roomToken),
  );

  Future<CallLifecycleState?> recover({
    required String accountId,
    required String roomToken,
  }) => _serialize(
    accountId: accountId,
    roomToken: roomToken,
    operation: () => _recover(accountId: accountId, roomToken: roomToken),
  );

  Future<CallLifecycleState> _join({
    required String accountId,
    required String roomToken,
    required CallInCallFlags flags,
    required bool silent,
    required bool recordingConsent,
    required Iterable<ConversationSessionId> silentFor,
  }) async {
    final context = await _prepare(accountId, roomToken);
    if (!context.policy.canJoinWith(flags)) {
      throw const CallLifecycleException(CallLifecycleError.forbidden);
    }
    if (silent && !context.profile.silent) {
      throw const CallLifecycleException(CallLifecycleError.unsupported);
    }
    final consentRequired =
        context.profile.recordingConsentMode == 1 ||
        (context.profile.recordingConsentMode == 2 &&
            context.policy.recordingConsent == 1);
    if (consentRequired && !recordingConsent) {
      throw const CallLifecycleException(CallLifecycleError.consentRequired);
    }

    var existing = await _sessions.load(authority: context.authority);
    if (existing != null && existing.phase != CallLifecyclePhase.joined) {
      existing = await _recoverPrepared(context, existing);
    }
    if (existing != null) {
      if (existing.phase != CallLifecyclePhase.joined) {
        throw const CallLifecycleException(CallLifecycleError.uncertain);
      }
      return existing;
    }

    var state = CallLifecycleState.beginJoin(
      authority: context.authority,
      flags: flags,
      updatedAt: _utcNow(),
    );
    await _sessions.persist(state);
    final request = JoinCallRequest(
      context: CallRequestContext(
        authority: state.authority,
        mutationSequence: state.mutationSequence,
      ),
      flags: flags,
      silent: silent,
      recordingConsent: recordingConsent,
      silentFor: silentFor,
    );
    final response = await _mutate(
      state: state,
      send: () => _api.joinCall(
        joinRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    switch (response.classification) {
      case CallResponseClassification.confirmed:
        state = state.confirm(updatedAt: _utcNow());
        await _sessions.persist(state);
        return state;
      case CallResponseClassification.serverFailure:
        await _markUncertain(state);
      case CallResponseClassification.reauthenticationRequired:
        await _dropForReauthentication(accountId, roomToken);
      case CallResponseClassification.rejected:
        await _sessions.delete(accountId: accountId, roomToken: roomToken);
        throw CallLifecycleException(
          response.errorCode == 'consent'
              ? CallLifecycleError.consentRequired
              : CallLifecycleError.rejected,
        );
      case CallResponseClassification.forbidden:
        await _sessions.delete(accountId: accountId, roomToken: roomToken);
        throw const CallLifecycleException(CallLifecycleError.forbidden);
      case CallResponseClassification.sessionMissing:
        await _sessions.delete(accountId: accountId, roomToken: roomToken);
        throw const CallLifecycleException(CallLifecycleError.roomMissing);
      case CallResponseClassification.conflict:
        await _sessions.delete(accountId: accountId, roomToken: roomToken);
        throw const CallLifecycleException(CallLifecycleError.conflict);
      case CallResponseClassification.rateLimited:
        await _sessions.delete(accountId: accountId, roomToken: roomToken);
        throw const CallLifecycleException(CallLifecycleError.rateLimited);
    }
  }

  Future<CallLifecycleState> _updateFlags({
    required String accountId,
    required String roomToken,
    required CallInCallFlags flags,
  }) async {
    final context = await _prepare(accountId, roomToken);
    if (!context.policy.canJoinWith(flags)) {
      throw const CallLifecycleException(CallLifecycleError.forbidden);
    }
    var stable = await _sessions.load(authority: context.authority);
    if (stable == null) {
      throw const CallLifecycleException(CallLifecycleError.notJoined);
    }
    if (stable.phase != CallLifecyclePhase.joined) {
      stable = await _recoverPrepared(context, stable);
    }
    if (stable == null) {
      throw const CallLifecycleException(CallLifecycleError.notJoined);
    }
    if (stable.phase != CallLifecyclePhase.joined) {
      throw const CallLifecycleException(CallLifecycleError.uncertain);
    }

    var state = stable.beginUpdate(flags: flags, updatedAt: _utcNow());
    await _sessions.persist(state);
    final request = UpdateCallFlagsRequest(
      context: CallRequestContext(
        authority: state.authority,
        mutationSequence: state.mutationSequence,
      ),
      flags: flags,
    );
    final response = await _mutate(
      state: state,
      send: () => _api.updateCallFlags(
        updateRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    switch (response.classification) {
      case CallResponseClassification.confirmed:
        state = state.confirm(updatedAt: _utcNow());
        await _sessions.persist(state);
        return state;
      case CallResponseClassification.serverFailure:
        await _markUncertain(state);
      case CallResponseClassification.reauthenticationRequired:
        await _dropForReauthentication(accountId, roomToken);
      case CallResponseClassification.sessionMissing:
        await _sessions.delete(accountId: accountId, roomToken: roomToken);
        throw const CallLifecycleException(CallLifecycleError.notJoined);
      case CallResponseClassification.rejected:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.rejected);
      case CallResponseClassification.forbidden:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.forbidden);
      case CallResponseClassification.conflict:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.conflict);
      case CallResponseClassification.rateLimited:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.rateLimited);
    }
  }

  Future<void> _leave({
    required String accountId,
    required String roomToken,
    required bool endForEveryone,
  }) async {
    final context = await _prepare(accountId, roomToken);
    if (endForEveryone && !context.policy.canEndForEveryone) {
      throw const CallLifecycleException(CallLifecycleError.forbidden);
    }
    var stable = await _sessions.load(authority: context.authority);
    if (stable == null) {
      return;
    }
    if (stable.phase != CallLifecyclePhase.joined &&
        stable.phase != CallLifecyclePhase.uncertainUpdate) {
      stable = await _recoverPrepared(context, stable);
    }
    if (stable == null) {
      return;
    }
    if (stable.phase != CallLifecyclePhase.joined &&
        stable.phase != CallLifecyclePhase.uncertainUpdate) {
      throw const CallLifecycleException(CallLifecycleError.uncertain);
    }

    final state = stable.beginLeave(
      endForEveryone: endForEveryone,
      updatedAt: _utcNow(),
    );
    await _sessions.persist(state);
    await _sendLeave(context, state, rollback: stable);
  }

  Future<CallLifecycleStatus> _status({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _prepare(accountId, roomToken);
    final state = await _sessions.load(authority: context.authority);
    final response = await _readPeers(context, state?.mutationSequence ?? 0);
    return CallLifecycleStatus(
      ownSessionPresent: response.ownSessionPresent,
      peers: response.peers,
      state: state,
    );
  }

  Future<CallLifecycleState?> _recover({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _prepare(accountId, roomToken);
    final state = await _sessions.load(
      authority: context.authority,
      afterRestart: true,
      now: _utcNow(),
    );
    return state == null ? null : _recoverPrepared(context, state);
  }

  Future<CallLifecycleState?> _recoverPrepared(
    _CallContext context,
    CallLifecycleState state,
  ) async {
    final response = await _readPeers(context, state.mutationSequence);
    final decision = reconcileCallLifecycle(
      state: state,
      peersResponse: response,
      observedAt: _utcNow(),
    );
    switch (decision.action) {
      case CallRecoveryAction.deleteLocalState:
        await _sessions.delete(
          accountId: context.authority.accountId.value,
          roomToken: context.authority.roomToken.value,
        );
        return null;
      case CallRecoveryAction.joinedConfirmed:
      case CallRecoveryAction.stillUncertain:
        await _sessions.persist(decision.state!);
        return decision.state;
      case CallRecoveryAction.retryLeave:
        await _sessions.persist(decision.state!);
        await _retryLeave(context, decision.state!);
        return null;
    }
  }

  Future<void> _retryLeave(_CallContext context, CallLifecycleState state) =>
      _sendLeave(context, state, rollback: state);

  Future<void> _sendLeave(
    _CallContext context,
    CallLifecycleState state, {
    required CallLifecycleState rollback,
  }) async {
    final request = LeaveCallRequest(
      context: CallRequestContext(
        authority: state.authority,
        mutationSequence: state.mutationSequence,
      ),
      endForEveryone: state.endForEveryone!,
    );
    final response = await _mutate(
      state: state,
      send: () => _api.leaveCall(
        leaveRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    final accountId = state.authority.accountId.value;
    final roomToken = state.authority.roomToken.value;
    switch (response.classification) {
      case CallResponseClassification.confirmed:
      case CallResponseClassification.sessionMissing:
        await _sessions.delete(accountId: accountId, roomToken: roomToken);
      case CallResponseClassification.serverFailure:
        await _markUncertain(state);
      case CallResponseClassification.reauthenticationRequired:
        await _dropForReauthentication(accountId, roomToken);
      case CallResponseClassification.rejected:
        await _sessions.persist(rollback);
        throw const CallLifecycleException(CallLifecycleError.rejected);
      case CallResponseClassification.forbidden:
        await _sessions.persist(rollback);
        throw const CallLifecycleException(CallLifecycleError.forbidden);
      case CallResponseClassification.conflict:
        await _sessions.persist(rollback);
        throw const CallLifecycleException(CallLifecycleError.conflict);
      case CallResponseClassification.rateLimited:
        await _sessions.persist(rollback);
        throw const CallLifecycleException(CallLifecycleError.rateLimited);
    }
  }

  Future<CallRestResponse> _mutate({
    required CallLifecycleState state,
    required Future<CallRestResponse> Function() send,
  }) async {
    try {
      return await send();
    } on Object {
      await _markUncertain(state);
    }
  }

  Future<Never> _markUncertain(CallLifecycleState state) async {
    await _sessions.persist(state.markUncertain(updatedAt: _utcNow()));
    throw const CallLifecycleException(CallLifecycleError.uncertain);
  }

  Future<CallRestResponse> _readPeers(
    _CallContext context,
    int mutationSequence,
  ) async {
    try {
      final response = await _api.getCallPeers(
        peersRequest: CallPeersRequest(
          context: CallRequestContext(
            authority: context.authority,
            mutationSequence: mutationSequence,
          ),
        ),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
      return switch (response.classification) {
        CallResponseClassification.confirmed => response,
        CallResponseClassification.reauthenticationRequired =>
          await _dropForReauthentication(
            context.authority.accountId.value,
            context.authority.roomToken.value,
          ),
        CallResponseClassification.sessionMissing =>
          throw const CallLifecycleException(CallLifecycleError.roomMissing),
        CallResponseClassification.forbidden =>
          throw const CallLifecycleException(CallLifecycleError.forbidden),
        CallResponseClassification.rateLimited =>
          throw const CallLifecycleException(CallLifecycleError.rateLimited),
        CallResponseClassification.serverFailure =>
          throw const CallLifecycleException(
            CallLifecycleError.serviceUnavailable,
          ),
        CallResponseClassification.rejected ||
        CallResponseClassification.conflict =>
          throw const CallLifecycleException(
            CallLifecycleError.invalidResponse,
          ),
      };
    } on CallLifecycleException {
      rethrow;
    } on NextcloudApiException catch (error) {
      throw CallLifecycleException(_mapApiError(error));
    } on TalkProtocolException {
      throw const CallLifecycleException(CallLifecycleError.invalidResponse);
    }
  }

  Future<_CallContext> _prepare(String accountId, String roomToken) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const CallLifecycleException(CallLifecycleError.accountMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const CallLifecycleException(CallLifecycleError.credentialMissing);
    }
    final ServerBase server;
    final AccountId typedAccountId;
    final ConversationToken typedRoomToken;
    try {
      server = ServerBase.parse(account.serverUrl);
      typedAccountId = AccountId.parse(accountId);
      typedRoomToken = ConversationToken.parse(roomToken, path: r'$.roomToken');
    } on Object {
      throw const CallLifecycleException(CallLifecycleError.invalidResponse);
    }

    final refreshedSessionId = await _refreshConversationSession(
      accountId,
      roomToken,
    );
    if (refreshedSessionId == null) {
      throw const CallLifecycleException(CallLifecycleError.roomMissing);
    }

    final cached = await _accounts.getConversation(
      accountId: accountId,
      token: roomToken,
    );
    if (cached == null) {
      throw const CallLifecycleException(CallLifecycleError.roomMissing);
    }
    final ConversationRoom room;
    try {
      room = ConversationRoom.fromJson(jsonDecode(cached.rawJson));
      if (room.token != typedRoomToken || cached.accountId != accountId) {
        throw const FormatException('Conversation authority mismatch');
      }
    } on Object {
      throw const CallLifecycleException(CallLifecycleError.invalidResponse);
    }

    final CapabilitySnapshot capabilities;
    try {
      final read = await _api.getAuthenticatedCapabilitiesWithSource(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
        forceRefresh: true,
      );
      capabilities = read.snapshot;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _dropForReauthentication(accountId, roomToken);
      }
      throw CallLifecycleException(_mapApiError(error));
    }

    try {
      final profile = CallCapabilityProfile.fromSnapshot(capabilities);
      if (!profile.enabled) {
        throw const CallLifecycleException(CallLifecycleError.unsupported);
      }
      final storedCapabilities = await _chat.recordCapabilities(
        accountId: accountId,
        talkFeatures: capabilities.talkFeatures,
        observedAt: _utcNow(),
      );
      final policy = CallRoomPolicy.fromConversation(room);
      final authority = CallLifecycleAuthority(
        accountId: typedAccountId,
        server: server,
        roomToken: typedRoomToken,
        nextcloudSessionId: refreshedSessionId,
        credentialGeneration: storedCapabilities.credentialGeneration,
        capabilityGeneration: storedCapabilities.generation,
        capabilityRevision: profile.revision,
      );
      return _CallContext(
        account: account,
        appPassword: appPassword,
        profile: profile,
        policy: policy,
        authority: authority,
      );
    } on CallLifecycleException {
      rethrow;
    } on Object {
      throw const CallLifecycleException(CallLifecycleError.invalidResponse);
    }
  }

  Future<Never> _dropForReauthentication(
    String accountId,
    String roomToken,
  ) async {
    await _chat.markReauthenticationRequired(accountId);
    await _sessions.delete(accountId: accountId, roomToken: roomToken);
    throw const CallLifecycleException(
      CallLifecycleError.reauthenticationRequired,
    );
  }

  CallLifecycleError _mapApiError(NextcloudApiException error) =>
      switch (error.code) {
        NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
          CallLifecycleError.reauthenticationRequired,
        NextcloudApiError.network ||
        NextcloudApiError.timeout ||
        NextcloudApiError.cancelled => CallLifecycleError.network,
        _ => CallLifecycleError.invalidResponse,
      };

  DateTime _utcNow() => _now().toUtc();

  Future<T> _serialize<T>({
    required String accountId,
    required String roomToken,
    required Future<T> Function() operation,
  }) async {
    final key = (accountId: accountId, roomToken: roomToken);
    final previous = _tails[key];
    final gate = Completer<void>();
    final tail = gate.future;
    _tails[key] = tail;
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // A failed operation must not permanently block this room lane.
      }
    }
    try {
      return await operation();
    } finally {
      gate.complete();
      if (identical(_tails[key], tail)) {
        _tails.remove(key);
      }
    }
  }
}

final class _CallContext {
  const _CallContext({
    required this.account,
    required this.appPassword,
    required this.profile,
    required this.policy,
    required this.authority,
  });

  final StoredAccount account;
  final String appPassword;
  final CallCapabilityProfile profile;
  final CallRoomPolicy policy;
  final CallLifecycleAuthority authority;
}
