part of 'chat_service.dart';

final class _ChatReadDeferred implements Exception {
  const _ChatReadDeferred();
}

abstract interface class _ChatReadGuard {
  void ensureActive();
  void ensureFetchAllowed(_PreparedChat prepared);
}

final class _ChatReadAdmission implements _ChatReadGuard {
  _ChatReadAdmission(
    this.service,
    this.accountId,
    this.roomToken,
    this.readerIsActive, {
    this.requiresActiveOwner = false,
  }) {
    service._readAdmissions.add(this);
  }

  final ChatService service;
  final String accountId;
  final String roomToken;
  final bool Function() readerIsActive;
  final bool requiresActiveOwner;
  final _abort = Completer<void>();
  bool? _passive;
  bool _deferred = false;

  Future<void> get abortTrigger => _abort.future;

  Future<T> run<T>(Future<T> Function() action) async {
    ensureActive();
    try {
      return await action();
    } on Object {
      ensureActive();
      rethrow;
    }
  }

  void readerChanged() {
    if ((requiresActiveOwner || _passive == false) && !readerIsActive()) {
      _deferred = true;
      if (!_abort.isCompleted) _abort.complete();
    }
  }

  @override
  void ensureActive() {
    service._ensureAccountActive(accountId);
    readerChanged();
    if (_deferred) throw const _ChatReadDeferred();
  }

  @override
  void ensureFetchAllowed(_PreparedChat prepared) {
    _passive = prepared.profile.backgroundCatchUp;
    readerChanged();
    ensureActive();
  }

  void close() {
    service._readAdmissions.remove(this);
    if (!_abort.isCompleted) _abort.complete();
  }
}

extension _ChatReadAdmissionService on ChatService {
  Future<void> _loadOlder(
    String accountId,
    String roomToken,
    int? threadId,
    bool Function()? readerIsActive,
  ) async {
    final read = _ChatReadAdmission(
      this,
      accountId,
      roomToken,
      readerIsActive ?? () => true,
      requiresActiveOwner: readerIsActive != null,
    );
    try {
      await _serializeRoom<void>(
        _roomKey(accountId, roomToken),
        () => _withRoomErrorPersistence(
          accountId,
          roomToken,
          () => read.run(() async {
            var prepared = await _prepare(
              accountId,
              roomToken,
              threadId: threadId,
              abortTrigger: read.abortTrigger,
            );
            if (prepared.threadId != null &&
                prepared.namedThread == null &&
                prepared.networkThreadId == null) {
              prepared = await _hydrateUnknownThreadFromRoot(
                prepared,
                abortTrigger: read.abortTrigger,
                probe: read,
              );
            }
            try {
              await _fetchHistoryPage(
                prepared,
                includeLastKnown: false,
                abortTrigger: read.abortTrigger,
                probe: read,
              );
            } on _UnknownThreadNotFound {
              await _hydrateUnknownThreadFromRoot(
                prepared,
                abortTrigger: read.abortTrigger,
                probe: read,
              );
            }
          }),
          threadId: threadId,
        ),
      );
    } on _ChatReadDeferred {
      return;
    } on _ChatSynchronizationStale {
      return;
    } finally {
      read.close();
    }
  }

  Future<bool> _refreshMessage(
    String accountId,
    String roomToken,
    int messageId,
  ) async {
    if (messageId < 1) return false;
    final read = _ChatReadAdmission(
      this,
      accountId,
      roomToken,
      () => _hasActiveReader(accountId, roomToken),
    );
    try {
      return await read.run(() async {
        final prepared = await _prepare(
          accountId,
          roomToken,
          abortTrigger: read.abortTrigger,
        );
        read.ensureFetchAllowed(prepared);
        final request = ChatFetchRequest(
          accountId: AccountId.parse(accountId),
          requestId: ChatRequestId.parse(_uuid.v4()),
          server: prepared.authority.server,
          roomToken: prepared.room.token,
          profile: prepared.profile,
          direction: ChatFetchDirection.history,
          cursor: ChatCursor.parse(messageId.toString()),
          lastCommonRead: ChatCursor.parse('0'),
          limit: 1,
          includeLastKnown: true,
          timeoutSeconds: 0,
          interactive: !prepared.profile.backgroundCatchUp,
        );
        final response = await _api.getChat(
          chatRequest: request,
          loginName: prepared.account.loginName,
          appPassword: prepared.appPassword,
          abortTrigger: read.abortTrigger,
        );
        await _ensurePreparedContextCurrent(prepared);
        read.ensureActive();
        if (response.classification != ChatGetClassification.messages) {
          return false;
        }
        for (final message in response.messages) {
          if (message.messageId != messageId) continue;
          await _chat.applyMessageMutation(
            accountId: accountId,
            server: prepared.authority.server,
            message: message,
          );
          return true;
        }
        return false;
      });
    } on _ChatReadDeferred {
      return false;
    } on _ChatSynchronizationStale {
      return false;
    } finally {
      read.close();
    }
  }

  bool _hasActiveReader(String accountId, String roomToken) =>
      _liveBindings.any(
        (reader) =>
            !reader._closed &&
            reader._readerActive &&
            reader.accountId == accountId &&
            reader.roomToken == roomToken,
      );

  void _readerActivityChanged(
    String accountId,
    String roomToken, {
    required bool wake,
  }) {
    if (_closed) return;
    for (final read in _readAdmissions.toList()) {
      if (read.accountId == accountId && read.roomToken == roomToken) {
        read.readerChanged();
      }
    }
    if (wake) {
      for (final relay in _relayBindings.toList()) {
        if (relay.accountId == accountId && relay.roomToken == roomToken) {
          relay._readerBecameActive();
        }
      }
      _readerWakes.add((accountId: accountId, roomToken: roomToken));
    }
  }

  Future<void> _drainWithoutReading(String accountId, String roomToken) =>
      _serializeRoom(
        _roomKey(accountId, roomToken),
        () => _withRoomErrorPersistence(accountId, roomToken, () async {
          final prepared = await _prepare(
            accountId,
            roomToken,
            forceCapabilityNetworkRead: true,
          );
          await _chat.recoverInterruptedTextSends(accountId);
          await _ensurePreparedContextCurrent(prepared);
          await _processPending(prepared);
        }),
      );
}
