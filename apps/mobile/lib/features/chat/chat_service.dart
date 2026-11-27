// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../data/text_send_ownership.dart';
import '../../network/nextcloud_api.dart';
import 'outgoing_message_status.dart';

part 'chat_service_models.dart';
part 'chat_service_outbox.dart';
part 'chat_service_private_reply.dart';
part 'chat_service_relay.dart';
part 'chat_service_runtime.dart';
part 'chat_service_fetch.dart';
part 'chat_service_read_admission.dart';

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
    TextSendOwnership? ownership,
    Uuid? uuid,
    int absenceGraceSeconds = textSendAbsenceGraceSeconds,
    void Function(bool active)? reportSendActivity,
    void Function()? retryDeliveryQueuedForTesting,
    Future<void> Function()? holdRetryDeliveryLaneForTesting,
  }) : _reportSendActivity = reportSendActivity,
       _retryDeliveryQueuedForTesting = retryDeliveryQueuedForTesting,
       _holdRetryDeliveryLaneForTesting = holdRetryDeliveryLaneForTesting,
       _accounts = accounts,
       _chat = chat,
       _textSends = ownership ?? textSendOwnership(),
       _credentials = credentials,
       _api = api,
       _uuid = uuid ?? const Uuid(),
       _absenceGraceSeconds = absenceGraceSeconds;

  static const int _pageSize = 100;
  static const int _maximumCatchUpPages = 12;

  /// Upper bound for [catchUpRoom] joining a live poll. A long poll normally
  /// answers the moment the room changes, so this only stops a background
  /// reconciler from waiting out an idle 30 s poll.
  static const Duration _livePollJoinTimeout = Duration(seconds: 3);
  static const Duration _accountSuspendDrainTimeout = Duration(seconds: 5);

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final TextSendOwnership _textSends;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;

  /// The contract's grace period. Only tests shorten it.
  final int _absenceGraceSeconds;

  /// Told when the first text send starts and when the last one has been
  /// delivered or given up for now, so the platform can keep the process
  /// alive in between. A send waiting for its retry holds nothing.
  final void Function(bool active)? _reportSendActivity;
  final void Function()? _retryDeliveryQueuedForTesting;
  final Future<void> Function()? _holdRetryDeliveryLaneForTesting;
  int _sendsInFlight = 0;

  void _sendActivity(int change) {
    final before = _sendsInFlight > 0;
    _sendsInFlight += change;
    final active = _sendsInFlight > 0;
    if (before != active) {
      _reportSendActivity?.call(active);
    }
  }

  final Map<String, Future<void>> _roomTails = {};
  final Map<String, Future<ChatSynchronizationResult>> _syncInFlight = {};
  final Map<String, _SharedLivePoll> _liveNetworkPolls = {};
  final Set<ChatLiveRoomBinding> _liveBindings = {};
  final Set<ChatRelayBinding> _relayBindings = {};
  final Set<String> _suspendedAccounts = {};

  /// The capability snapshot whose rows this service last wrote, per account.
  final Map<String, CapabilitySnapshot> _recordedCapabilities = {};

  /// The pending retry of a send that never left, or the pending check of
  /// one that may have, one per room: only the oldest undelivered send of a
  /// room is ever waiting for either.
  final Map<String, _ChatRetryWake> _retryTimers = {};
  int _retryGeneration = 0;
  final Set<_ChatReadAdmission> _readAdmissions = {};
  final _readerWakes =
      StreamController<({String accountId, String roomToken})>.broadcast();
  bool _closed = false;

  Stream<({String accountId, String roomToken})> get readerWakeEvents =>
      _readerWakes.stream;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final entry in _retryTimers.entries.toList(growable: false)) {
      _cancelRetryWake(entry.key, entry.value);
    }
    for (final binding in _liveBindings.toList()) {
      binding.close();
    }
    for (final relay in _relayBindings.toList()) {
      relay.close();
    }
    for (final read in _readAdmissions.toList()) {
      read.close();
    }
    await _readerWakes.close();
  }

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
    bool readerActive = true,
  }) {
    final binding = ChatLiveRoomBinding._(
      service: this,
      accountId: accountId,
      roomToken: roomToken,
      threadId: threadId,
      readerActive: readerActive,
    );
    _liveBindings.add(binding);
    _readerActivityChanged(accountId, roomToken, wake: readerActive);
    if (_suspendedAccounts.contains(accountId)) {
      binding.close();
    }
    return binding;
  }

  /// Opens this room's HPB chat relay inlet. The caller feeds it the
  /// signalling session's relay events; see [ChatRelayBinding] for why the
  /// relay is trusted only after a catch-up and what drops that trust.
  ChatRelayBinding bindRelay({
    required String accountId,
    required String roomToken,
  }) {
    final binding = ChatRelayBinding._(
      service: this,
      accountId: accountId,
      roomToken: roomToken,
    );
    _relayBindings.add(binding);
    if (_suspendedAccounts.contains(accountId)) {
      binding.close();
    }
    return binding;
  }

  /// Stops every root and thread poll for [accountId] before its credentials
  /// can be revoked. Once suspended, this service never admits more work for
  /// that account; a new login creates a new service lifetime.
  Future<void> suspendAccount(String accountId) async {
    _suspendedAccounts.add(accountId);
    final bindings = _liveBindings
        .where((binding) => binding.accountId == accountId)
        .toList(growable: false);
    final active = bindings
        .map((binding) => binding._inFlight)
        .whereType<Future<void>>()
        .toList(growable: true);
    final prefix = '$accountId\u0000';
    for (final entry
        in _retryTimers.entries
            .where((entry) => entry.key.startsWith(prefix))
            .toList(growable: false)) {
      _cancelRetryWake(entry.key, entry.value);
    }
    active.addAll(
      _liveNetworkPolls.entries
          .where((entry) => entry.key.startsWith(prefix))
          .map((entry) => entry.value.operation),
    );
    for (final binding in bindings) {
      binding.close();
    }
    for (final relay
        in _relayBindings
            .where((binding) => binding.accountId == accountId)
            .toList(growable: false)) {
      relay.close();
    }
    active.addAll(
      _roomTails.entries
          .where((entry) => entry.key.startsWith(prefix))
          .map((entry) => entry.value),
    );
    if (active.isEmpty) {
      return;
    }
    final settled = active.map((operation) async {
      try {
        await operation;
      } on Object {
        // The operation owns any protocol-specific failure persistence.
      }
    });
    await Future.wait<void>(
      settled,
    ).timeout(_accountSuspendDrainTimeout, onTimeout: () => const <void>[]);
  }

  /// Delivers what the outbox still holds in rooms nobody has open.
  ///
  /// The room pane replays its own room while it is on screen. A message
  /// queued in a tunnel and an app reopened on the conversation list have no
  /// pane, so without this the text would wait until the room was opened
  /// again. Each room goes through the ordinary sync, which also verifies
  /// capabilities online before anything is claimed; a room whose sync fails
  /// keeps its rows and the error is the pane's to show.
  ///
  /// Each account drains in its own lane. A server that hangs until its
  /// timeout would otherwise hold every later room in the drain behind it,
  /// including the rooms of a second account whose server is reachable, so a
  /// signed-in account's queued text waits on an unrelated account's outage.
  Future<void> drainPendingSends() async {
    // A drain answers a wake: the network is back, the app resumed. A send
    // that failed for want of a connection is worth trying now, not when its
    // backoff runs out.
    await _chat.expediteUnsentTextSends();
    final lanes = <String, List<String>>{};
    for (final room in await _chat.roomsWithPendingTextSends()) {
      (lanes[room.accountId] ??= <String>[]).add(room.roomToken);
    }
    await Future.wait<void>([
      for (final lane in lanes.entries) _drainAccountLane(lane.key, lane.value),
    ]);
  }

  /// One account's rooms, one at a time. The transport serializes an account's
  /// requests onto a single session anyway, so racing them inside a lane buys
  /// no parallelism and only reorders the sends.
  Future<void> _drainAccountLane(
    String accountId,
    List<String> roomTokens,
  ) async {
    for (final roomToken in roomTokens) {
      if (_suspendedAccounts.contains(accountId)) {
        return;
      }
      try {
        final result = await _syncRoom(
          accountId: accountId,
          roomToken: roomToken,
          joinExisting: true,
          automatic: true,
        );
        if (result == ChatSynchronizationResult.deferred) {
          await _drainWithoutReading(accountId, roomToken);
        }
        // A send into a named thread is proven absent only by a read of that
        // thread, which the room's own sync does not make.
        final pending = await _chat.pendingAbsenceVerification(
          accountId: accountId,
          roomToken: roomToken,
        );
        if (pending?.threadId != null) {
          await _syncRoom(
            accountId: accountId,
            roomToken: roomToken,
            threadId: pending!.threadId,
            joinExisting: true,
            automatic: true,
          );
        }
      } on ChatServiceException {
        // Recorded on the room by syncRoom; the next wake tries again.
      } on _ChatSynchronizationCancelled {
        // The account went away underneath; nothing to deliver for it.
      }
    }
  }

  Future<ChatSynchronizationResult> syncRoom({
    required String accountId,
    required String roomToken,
    int? threadId,
    bool Function()? readerIsActive,
  }) => _syncRoom(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
    joinExisting: readerIsActive == null,
    readerIsActive: readerIsActive,
  );

  /// Brings a room up to date for a background reconciler, such as the
  /// attachment confirmation loop waiting for its own `file_shared` message.
  ///
  /// An open room already polls the same scope, and that poll reads the same
  /// server state a fresh request would. Racing it costs a second request and
  /// makes the poll's own answer arrive against a moved cursor, where it is
  /// discarded as stale and repeated. Joining it costs nothing and observes
  /// exactly the same messages. Interactive callers keep using [syncRoom],
  /// which never waits on somebody else's poll.
  Future<ChatSynchronizationResult> catchUpRoom({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) async {
    final joined = await _awaitLiveNetworkPoll(accountId, roomToken, threadId);
    if (joined != null && joined != ChatSynchronizationResult.deferred) {
      return joined;
    }
    return _syncRoom(
      accountId: accountId,
      roomToken: roomToken,
      threadId: threadId,
      joinExisting: true,
      automatic: true,
    );
  }

  /// Pages history back from the history cursor.
  Future<ChatFetchOutcome> loadOlder({
    required String accountId,
    required String roomToken,
    int? threadId,
    bool Function()? readerIsActive,
  }) => _loadOlder(accountId, roomToken, threadId, readerIsActive);

  /// Caches the messages around [messageId], the island a jump shows. The
  /// room's history takes it in only once the two touch.
  /// [ChatFetchOutcome.unsupported] when the server cannot do that (no
  /// `chat-get-context`, a thread whose kind is not known yet, or an answer
  /// outside the documented shape), so the caller has to page history.
  Future<ChatIslandFetch> loadMessageContext({
    required String accountId,
    required String roomToken,
    required int messageId,
    int? threadId,
    bool Function()? readerIsActive,
  }) => _loadMessageContext(
    accountId,
    roomToken,
    threadId,
    messageId,
    readerIsActive,
  );

  /// Fetches a page from one edge of [island]: older messages from its
  /// oldest end when [older], newer ones from its newest end otherwise.
  Future<ChatIslandFetch> loadIslandPage({
    required String accountId,
    required String roomToken,
    required ChatBlock island,
    required bool older,
    int? threadId,
    bool Function()? readerIsActive,
  }) => _loadIslandPage(
    accountId,
    roomToken,
    threadId,
    island,
    older,
    readerIsActive,
  );

  /// Refreshes one cached message without moving cursors.
  /// Legacy servers defer this repair until the room has an active reader.
  ///
  /// Returns whether the cache holds the server's copy afterwards: false when
  /// the server did not return it or the row changed while it was read.
  Future<bool> refreshMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) => _refreshMessage(accountId, roomToken, messageId);

  /// [replyTo] answers a specific root message. Talk turns that into a thread,
  /// so it is mutually exclusive with sending inside an existing [threadId].
  ///
  /// [emojiSizeStep] (1 to [ChatEmojiSizeReference.maxStep]) marks an
  /// emoji-only message to be shown enlarged by this client; it rides in the
  /// `referenceId` and does not change the message text.
  ///
  /// Completes once the message is durably in the outbox, not once it reaches
  /// the server: the composer is free for the next line while this one is
  /// still on the wire. Delivery continues on the room lane, so the outbox is
  /// still emptied in admission order and a later message cannot overtake an
  /// earlier one. Everything after admission is reported through the
  /// operation's own state, not by this future. The value is the id the
  /// operation was admitted under, so a caller showing a provisional entry
  /// can tell when the outbox row has taken its place.
  Future<String> sendText({
    required String accountId,
    required String roomToken,
    required String message,
    bool silent = false,
    int? threadId,
    int? replyTo,
    String? replyToToken,
    PrivateReplyEligibilitySnapshot? privateReplyEligibility,
    int? emojiSizeStep,
  }) {
    final key = _roomKey(accountId, roomToken);
    // Held from the tap: the app may be left before the message is admitted.
    _sendActivity(1);
    // Admission has a lane of its own. On the room lane it would queue behind
    // the previous message's request, and a send into a tunnel would hold the
    // composer for as long as that request takes to fail.
    return _serializeRoom<String>(_admissionKey(key), () {
      return _withRoomErrorPersistence<String>(accountId, roomToken, () async {
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
        // The text exists only in memory until it is admitted, so nothing
        // before that may wait on the network: without a snapshot in memory
        // the stored capabilities admit it and the server is asked afterwards.
        var prepared = await _prepare(
          accountId,
          roomToken,
          threadId: threadId,
          allowPersistedCapabilitiesForSend: true,
          preferPersistedCapabilities: true,
        );
        if (prepared.threadId != null &&
            prepared.namedThread == null &&
            !prepared.capabilitiesVerifiedOnline) {
          // Where a thread of unknown kind posts to is read from the server
          // below, which needs it reachable anyway.
          prepared = await _prepare(
            accountId,
            roomToken,
            threadId: threadId,
            allowPersistedCapabilitiesForSend: true,
          );
        }
        if (replyTo != null && !prepared.profile.reply) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }
        if (prepared.room.readOnly != 0) {
          throw const ChatServiceException(ChatServiceError.readOnly);
        }
        if (!prepared.profile.sendText) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }
        // Fail closed rather than send loudly: a server without silent-send
        // ignores the flag and notifies anyway, which is the opposite of what
        // the switch promised.
        if (silent && !prepared.profile.silentSend) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }
        if (prepared.threadId != null && prepared.namedThread == null) {
          if (!prepared.capabilitiesVerifiedOnline) {
            throw const ChatServiceException(ChatServiceError.network);
          }
          // Reads and applies server state, so it belongs on the room lane
          // with every other synchronization. Where the message goes has to
          // be known before it can be admitted, so this one send does wait.
          prepared = await _serializeRoom<_PreparedChat>(
            key,
            () async =>
                (await _resolveAndSynchronizePrepared(prepared)).prepared,
          );
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
        final operationId = _uuid.v4();
        final referenceUuid = _uuid.v4();
        await _chat.admitTextSend(
          accountId: accountId,
          roomToken: prepared.room.token,
          authority: prepared.authority,
          operationId: ChatOperationId.parse(operationId),
          referenceId: ChatReferenceId.parse(
            emojiSizeStep == null
                ? referenceUuid
                : ChatEmojiSizeReference(
                    uuid: referenceUuid,
                    step: emojiSizeStep,
                  ).referenceId,
          ),
          message: normalized,
          silent: silent,
          replyTo: effectiveReplyTo,
          threadId: prepared.namedThread == true ? prepared.threadId : null,
          replyToToken: crossRoomReply ? parentRoomToken : null,
          parentRoomToken: parentRoomToken,
          privateReplyEligibility: privateReplyEligibility,
        );
        // Also when the capabilities came from storage because the server
        // could not be asked: a send that finds no network ends unsent and
        // arms its own retry, where waiting here left it to chance.
        _sendActivity(1);
        unawaited(
          (prepared.capabilitiesVerifiedOnline
                  ? _deliverPending(prepared, threadId: threadId)
                  : _deliverAfterStoredAdmission(prepared, threadId))
              .whenComplete(() => _sendActivity(-1)),
        );
        return operationId;
      }, threadId: threadId);
    }).whenComplete(() => _sendActivity(-1));
  }

  /// Empties the room's outbox after an admission, without the caller waiting
  /// for it.
  ///
  /// Off the room lane: a request there would wait behind the room's reads,
  /// and one that hangs would keep incoming messages from being applied.
  /// [_processPending] orders it against every other delivery. A failure is
  /// recorded on the room and on the operation exactly as a drain's would be,
  /// and the next wake picks the rows up again.
  ///
  /// [clearsRoomError] is false for a caller whose own outcome decides what
  /// the room shows: a delivery with nothing to send would otherwise wipe an
  /// error that caller is about to record or has just recorded.
  Future<void> _deliverPending(
    _PreparedChat prepared, {
    int? threadId,
    bool clearsRoomError = true,
    _ChatRetryWake? retryWake,
  }) async {
    final accountId = prepared.account.id;
    final roomToken = prepared.room.token.value;
    try {
      if (retryWake != null) {
        final processed = await _withRoomErrorPersistence<bool>(
          accountId,
          roomToken,
          () => _processPendingWithRetryGuard(prepared, retryWake),
          threadId: threadId,
          clearsRoomError: false,
        );
        if (processed) {
          await _chat.clearRoomError(
            accountId: accountId,
            roomToken: roomToken,
            threadId: threadId,
          );
        }
        return;
      }
      await _withRoomErrorPersistence(
        accountId,
        roomToken,
        () => _processPending(prepared),
        threadId: threadId,
        clearsRoomError: clearsRoomError,
      );
    } on Object {
      // Persisted by the wrapper, or the account went away underneath.
    }
  }

  /// Delivery for a message admitted on stored capabilities.
  ///
  /// The server is asked now, because a change it reports would make it
  /// refuse a claim made with the stored ones. If it cannot be asked, the
  /// stored ones still send the message or arm its retry.
  Future<void> _deliverAfterStoredAdmission(
    _PreparedChat stored,
    int? threadId,
  ) async {
    var prepared = stored;
    try {
      prepared = await _prepare(
        stored.account.id,
        stored.room.token.value,
        threadId: threadId,
        allowPersistedCapabilitiesForSend: true,
      );
    } on Object {
      // Falls back to [stored].
    }
    await _deliverPending(prepared, threadId: threadId);
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
        await _serializeRoom<void>(_deliveryKey(key), () async {
          final claim = await _chat.manuallyResend(
            accountId: accountId,
            operationId: ChatOperationId.parse(operationId),
            authority: prepared.authority,
            requestId: ChatRequestId.parse(_uuid.v4()),
            ownership: _textSends,
          );
          if (claim == null) {
            throw const ChatServiceException(ChatServiceError.invalidResponse);
          }
          if (!await _transmitClaim(prepared, claim)) {
            unawaited(_deliverWithCurrentCredentials(prepared));
          }
        });
      });
    });
  }

  Future<void> _recoverInterruptedSends(String accountId) =>
      _chat.recoverInterruptedTextSends(
        accountId,
        ownership: _textSends,
        now: _nowSeconds(),
        absenceGraceSeconds: _absenceGraceSeconds,
      );

  /// Reads the scope of the room's ambiguous head-of-line send over HTTP, so
  /// that the read can prove the message absent and queue it again. Returns
  /// false when the room has no such send.
  ///
  /// Never a joined read: a poll already under way began before the grace
  /// period ended, and one standing down for the relay reads nothing at all.
  Future<bool> _verifyPendingAbsence(_PreparedChat stale) async {
    final accountId = stale.account.id;
    final roomToken = stale.room.token.value;
    try {
      final pending = await _chat.pendingAbsenceVerification(
        accountId: accountId,
        roomToken: roomToken,
      );
      if (pending == null) {
        return false;
      }
      final result = await _syncRoom(
        accountId: accountId,
        roomToken: roomToken,
        threadId: pending.threadId,
        joinExisting: false,
        automatic: true,
      );
      if (result != ChatSynchronizationResult.incomplete) {
        // Converged decided it; deferred waits for a reader, whose arrival
        // reads the room anyway.
        return true;
      }
    } on ChatServiceException {
      // Recorded on the room by the sync.
    } on Object {
      // The account or the service went away underneath.
      return true;
    }
    // Nothing was proven either way. Asked again, no sooner than one more
    // grace period, until a read gets through.
    _armRetry(stale, _absenceGraceSeconds);
    return true;
  }

  /// [readStartedAt] is when the HTTP request left whose answer said the
  /// scope holds nothing newer. Only such an answer proves an absence: the
  /// relay and the cache never say what the server does not have.
  Future<void> _resendVerifiedAbsent(
    _PreparedChat prepared,
    int readStartedAt,
  ) => _chat.resendVerifiedAbsentTextSend(
    accountId: prepared.account.id,
    roomToken: prepared.room.token,
    threadId: prepared.networkThreadId,
    authority: prepared.authority,
    readStartedAt: readStartedAt,
    now: _nowSeconds(),
  );

  /// Tries the room's outbox again once a send that could not go out is due,
  /// or checks a send that may have gone out once its grace period is over.
  ///
  /// One timer per room. It fires once, and only an attempt that fails again
  /// arms the next one with a longer pause, so it cannot spin.
  void _armRetry(
    _PreparedChat prepared,
    int delaySeconds, {
    String? operationId,
  }) {
    if (_closed || _suspendedAccounts.contains(prepared.account.id)) {
      return;
    }
    final key = _roomKey(prepared.account.id, prepared.room.token.value);
    _cancelRetryWake(key, _retryTimers[key]);
    final retry = _ChatRetryWake(
      generation: ++_retryGeneration,
      operationId: operationId,
    );
    retry.timer = Timer(
      Duration(seconds: delaySeconds < 1 ? 1 : delaySeconds),
      () {
        if (!_retryWakeIsCurrent(key, retry)) {
          return;
        }
        retry.running = true;
        unawaited(_retryDelivery(prepared, key, retry));
      },
    );
    _retryTimers[key] = retry;
  }

  bool _retryWakeIsCurrent(String key, _ChatRetryWake retry) {
    final current = _retryTimers[key];
    return !retry.cancelled &&
        identical(current, retry) &&
        current?.generation == retry.generation;
  }

  /// Prepared afresh, because the capabilities or the password may have
  /// changed while the timer ran and a claim made with the old ones is
  /// refused. If the room cannot be prepared right now the old state still
  /// keeps the retries going.
  Future<void> _retryDelivery(
    _PreparedChat stale,
    String key,
    _ChatRetryWake retry,
  ) async {
    try {
      if (!_retryWakeIsCurrent(key, retry)) {
        return;
      }
      if (await _verifyPendingAbsence(stale) ||
          !_retryWakeIsCurrent(key, retry)) {
        return;
      }
      var prepared = stale;
      try {
        prepared = await _prepare(
          stale.account.id,
          stale.room.token.value,
          allowPersistedCapabilitiesForSend: true,
        );
      } on Object {
        // Falls back to [stale].
      }
      if (!_retryWakeIsCurrent(key, retry)) {
        return;
      }
      final delivery = _deliverPending(prepared, retryWake: retry);
      _retryDeliveryQueuedForTesting?.call();
      await delivery;
    } finally {
      retry.running = false;
      if (identical(_retryTimers[key], retry)) {
        _retryTimers.remove(key);
      }
    }
  }

  /// Removes a pending outbox operation. Returns `false` when the send may
  /// already have reached the server, in which case nothing was cancelled and
  /// the caller has to tell the user instead of pretending otherwise.
  ///
  /// Local only: no request is made and no room sync error is recorded, and
  /// the delivery lane keeps a claim from racing the gate.
  Future<bool> cancelText({
    required String accountId,
    required String roomToken,
    required String operationId,
  }) => _updatePendingTextSend(
    accountId,
    roomToken,
    operationId,
    () => _chat.cancelTextSend(accountId: accountId, operationId: operationId),
  );

  /// Releases an exhausted send's queue position while keeping its reference
  /// for confirmation. Returns false if the operation is no longer eligible.
  Future<bool> skipText({
    required String accountId,
    required String roomToken,
    required String operationId,
  }) => _updatePendingTextSend(
    accountId,
    roomToken,
    operationId,
    () => _chat.skipTextSend(
      accountId: accountId,
      roomToken: roomToken,
      operationId: operationId,
    ),
  );

  void _cancelRetryWake(String roomKey, _ChatRetryWake? retry) {
    if (retry == null || !identical(_retryTimers[roomKey], retry)) {
      return;
    }
    retry.cancelled = true;
    retry.timer.cancel();
    if (!retry.running) {
      _retryTimers.remove(roomKey);
    }
  }

  void _cancelRetryWakeForOperation(String roomKey, String operationId) {
    final retry = _retryTimers[roomKey];
    if (retry?.operationId != operationId) {
      return;
    }
    _cancelRetryWake(roomKey, retry);
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
    bool preferPersistedCapabilities = false,
    bool forceCapabilityNetworkRead = false,
  }) async {
    _ensureAccountActive(accountId);
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
      preferPersisted: preferPersistedCapabilities,
      forceNetworkRead: forceCapabilityNetworkRead,
    );
    _ensureAccountActive(accountId);
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    final profile = ChatCapabilityProfile.fromTalkFeatures(
      preparedCapabilities.talkFeatures.toList(growable: false),
      federated: room.isFederated,
      readPrivacyIsPublic: preparedCapabilities.readPrivacyIsPublic,
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

  /// A 401 for a password the user has since replaced belongs to the old
  /// login and must not push the account back into re-login.
  Future<bool> _credentialReplacedSince(
    String accountId,
    String usedAppPassword,
  ) async {
    try {
      final current = await _credentials.readAppPassword(accountId);
      return current != null && current != usedAppPassword;
    } on Object {
      return false;
    }
  }

  void _ensureAccountActive(String accountId) {
    if (_closed || _suspendedAccounts.contains(accountId)) {
      throw const _ChatSynchronizationCancelled();
    }
  }

  Future<_PreparedCapabilities> _prepareCapabilities({
    required StoredAccount account,
    required ServerBase server,
    required String appPassword,
    required Future<void>? abortTrigger,
    required bool allowPersistedCapabilitiesForSend,
    required bool preferPersisted,
    required bool forceNetworkRead,
  }) async {
    if (preferPersisted &&
        !_api.hasSettledCapabilities(
          server: server,
          loginName: account.loginName,
          appPassword: appPassword,
        )) {
      final persisted = await _loadPersistedCapabilities(account);
      if (persisted != null) {
        return persisted;
      }
    }
    try {
      final capabilityRead = await _api.getAuthenticatedCapabilitiesWithSource(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
        abortTrigger: abortTrigger,
        forceRefresh: forceNetworkRead,
      );
      _ensureAccountActive(account.id);
      final capabilities = capabilityRead.snapshot;
      if (!capabilities.hasTalk) {
        throw const ChatServiceException(ChatServiceError.talkUnavailable);
      }
      final sortedTalkFeatures = capabilities.talkFeatures.toList()..sort();
      final fingerprint = jsonEncode(sortedTalkFeatures);
      // A cache hit returns the snapshot this service already stored. Its
      // rows are rewritten only if something else has moved them since.
      var storedCapability =
          identical(_recordedCapabilities[account.id], capabilities) &&
              account.talkFeaturesJson == fingerprint
          ? await _chat.getReadyCapabilitySnapshot(account.id)
          : null;
      if (storedCapability?.fingerprint != fingerprint) {
        await _accounts.updateCapabilities(
          account.id,
          capabilities.talkFeatures,
          serverThemeColor: capabilities.serverThemeColor,
        );
        storedCapability = await _chat.recordCapabilities(
          accountId: account.id,
          talkFeatures: capabilities.talkFeatures,
          observedAt: DateTime.now().toUtc(),
        );
        _recordedCapabilities[account.id] = capabilities;
      }
      return _PreparedCapabilities(
        talkFeatures: capabilities.talkFeatures,
        fingerprint: fingerprint,
        generation: storedCapability!.generation,
        // The in-memory snapshot was read from this server within its short
        // lifetime, which is as much as a probe before every send proved. A
        // send that turns out to be offline fails before its body leaves and
        // is retried, so nothing ambiguous comes of trusting it.
        verifiedOnline: true,
        readPrivacyIsPublic:
            capabilities.context == CapabilityContext.authenticated &&
            capabilities.chatReadPrivacy == ChatReadPrivacy.public,
      );
    } on NextcloudApiException catch (error) {
      _ensureAccountActive(account.id);
      if (error.statusCode == 401 &&
          !await _credentialReplacedSince(account.id, appPassword)) {
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
        readPrivacyIsPublic: false,
      );
    } on FormatException {
      return null;
    } on TalkProtocolException {
      return null;
    }
  }

  Future<ChatMergeOutcome> _applyGetResponse(
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
      case ChatGetClassification.lobby:
        // Closed, not broken: the room pane already shows the lobby notice
        // from the room state, so a 412 poll is simply nothing to merge.
        return outcome;
      case ChatGetClassification.messages:
      case ChatGetClassification.invisibleCursorAdvance:
      case ChatGetClassification.commonReadOnly:
      case ChatGetClassification.notModified:
        if (outcome == ChatMergeOutcome.rejected) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
    }
    return outcome;
  }

  /// Sends what the room's outbox has due, oldest first.
  ///
  /// Serialized on the room's delivery lane, which callers may enter while
  /// holding the room lane but never the other way round.
  Future<void> _processPending(_PreparedChat prepared) async {
    await _processPendingInLane(prepared);
  }

  Future<bool> _processPendingWithRetryGuard(
    _PreparedChat prepared,
    _ChatRetryWake retry,
  ) {
    return _processPendingInLane(prepared, retryWake: retry);
  }

  Future<bool> _processPendingInLane(
    _PreparedChat prepared, {
    _ChatRetryWake? retryWake,
  }) {
    final roomKey = _roomKey(prepared.account.id, prepared.room.token.value);
    final key = _deliveryKey(roomKey);
    return _serializeRoom<bool>(key, () async {
      if (retryWake != null) {
        await _holdRetryDeliveryLaneForTesting?.call();
        if (!_retryWakeIsCurrent(roomKey, retryWake)) {
          return false;
        }
      }
      while (true) {
        _ensureAccountActive(prepared.account.id);
        final claim = await _chat.claimNextTextSend(
          accountId: prepared.account.id,
          roomToken: prepared.room.token,
          authority: prepared.authority,
          requestId: ChatRequestId.parse(_uuid.v4()),
          now: _nowSeconds(),
          ownership: _textSends,
        );
        if (claim == null) {
          return true;
        }
        if (!await _transmitClaim(prepared, claim)) {
          unawaited(_deliverWithCurrentCredentials(prepared));
          return true;
        }
      }
    });
  }

  /// Picks the outbox up again after [stale] turned out to carry a password
  /// the user has replaced. Nothing is sent unless the stored one differs, so
  /// a server that keeps answering 401 cannot make this go round.
  Future<void> _deliverWithCurrentCredentials(_PreparedChat stale) async {
    try {
      final prepared = await _prepare(
        stale.account.id,
        stale.room.token.value,
        allowPersistedCapabilitiesForSend: true,
      );
      if (prepared.appPassword != stale.appPassword &&
          prepared.capabilitiesVerifiedOnline) {
        await _deliverPending(prepared);
      }
    } on Object {
      // The rows stay queued; the next sync or wake delivers them.
    }
  }

  /// Keeps ownership until the send and its result write have both settled.
  Future<bool> _transmitClaim(
    _PreparedChat prepared,
    ClaimedTextSend claim,
  ) async {
    try {
      return await _sendClaim(prepared, claim);
    } finally {
      await claim.reservation?.release();
    }
  }

  // Returns false when the request used a password that has been replaced.
  Future<bool> _sendClaim(_PreparedChat prepared, ClaimedTextSend claim) async {
    _ensureAccountActive(prepared.account.id);

    Future<ChatOutboxOutcome> recordFailure(
      ChatTransportBodyState bodyState, {
      int? nextAttemptAt,
    }) => _chat.recordTextSendFailure(
      accountId: prepared.account.id,
      operationId: claim.operation.operationId,
      bodyState: bodyState,
      nextAttemptAt: nextAttemptAt,
      now: _nowSeconds(),
      absenceGraceSeconds: _absenceGraceSeconds,
    );

    final ChatSendResponse response;
    try {
      response = await _api.sendChat(
        chatRequest: claim.request,
        loginName: prepared.account.loginName,
        appPassword: prepared.appPassword,
      );
    } on NextcloudApiException catch (error) {
      _ensureAccountActive(prepared.account.id);
      // Only a request whose body never left may be repeated at once: the
      // server does not deduplicate by reference, so anything less certain
      // waits for a confirmation, or for a read that proves it absent.
      final retryDelay =
          error.retryAfter?.inSeconds ??
          _unsentRetryDelaySeconds(claim.operation.attemptCount);
      final outcome = await recordFailure(
        error.requestNotSent
            ? ChatTransportBodyState.notSent
            : ChatTransportBodyState.possiblySent,
        nextAttemptAt: error.requestNotSent ? _nowSeconds() + retryDelay : null,
      );
      if (error.requestNotSent) {
        _armRetry(
          prepared,
          retryDelay,
          operationId: claim.operation.operationId.value,
        );
      } else if (outcome == ChatOutboxOutcome.awaitingConfirmation) {
        await _checkSendConfirmation(prepared, claim.operation.threadId);
      }
      return true;
    } on TalkProtocolException {
      _ensureAccountActive(prepared.account.id);
      final outcome = await recordFailure(ChatTransportBodyState.possiblySent);
      if (outcome == ChatOutboxOutcome.awaitingConfirmation) {
        await _checkSendConfirmation(prepared, claim.operation.threadId);
      }
      return true;
    }
    _ensureAccountActive(prepared.account.id);
    if (response.classification ==
            ChatSendClassification.reauthenticationRequired &&
        await _credentialReplacedSince(
          prepared.account.id,
          prepared.appPassword,
        )) {
      // The 401 answers the password this request was built with, and the
      // user has logged in again since. It refused the request before any
      // save, so the operation goes back to the queue rather than taking the
      // new login down with it.
      _ensureAccountActive(prepared.account.id);
      await recordFailure(
        ChatTransportBodyState.notSent,
        nextAttemptAt: _nowSeconds(),
      );
      return false;
    }
    final outcome = await _chat.applyTextSendResponse(
      accountId: prepared.account.id,
      operationId: claim.operation.operationId,
      response: response,
      now: _nowSeconds(),
      absenceGraceSeconds: _absenceGraceSeconds,
    );
    if (outcome == ChatOutboxOutcome.completed ||
        outcome == ChatOutboxOutcome.failed ||
        outcome == ChatOutboxOutcome.reauthenticationRequired ||
        outcome == ChatOutboxOutcome.unchanged ||
        outcome == ChatOutboxOutcome.conflictAfterCompletion) {
      _cancelRetryWakeForOperation(
        _roomKey(prepared.account.id, prepared.room.token.value),
        claim.operation.operationId.value,
      );
    }
    if (outcome == ChatOutboxOutcome.awaitingConfirmation) {
      await _checkSendConfirmation(prepared, claim.operation.threadId);
    }
    if (outcome == ChatOutboxOutcome.retryable) {
      // The pause the outbox stored is this one or shorter.
      _armRetry(
        prepared,
        response.retryAfterSeconds ??
            _unsentRetryDelaySeconds(claim.operation.attemptCount),
        operationId: claim.operation.operationId.value,
      );
    }
    if (outcome == ChatOutboxOutcome.reauthenticationRequired) {
      await _chat.recordRoomError(
        accountId: prepared.account.id,
        roomToken: prepared.room.token.value,
        threadId: claim.operation.threadId ?? claim.operation.replyTo,
        errorCode: ChatServiceError.reauthenticationRequired.name,
      );
    }
    return true;
  }

  Future<T> _withRoomErrorPersistence<T>(
    String accountId,
    String roomToken,
    Future<T> Function() action, {
    int? threadId,
    bool clearsRoomError = true,
  }) async {
    try {
      final result = await action();
      _ensureAccountActive(accountId);
      if (!clearsRoomError) return result;
      if (result == ChatSynchronizationResult.deferred) return result;
      await _chat.clearRoomError(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
      );
      return result;
    } on ChatServiceException catch (error) {
      _ensureAccountActive(accountId);
      await _chat.recordRoomError(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
        errorCode: error.code.name,
      );
      rethrow;
    } on NextcloudApiException catch (error) {
      _ensureAccountActive(accountId);
      final mapped = ChatServiceException(_mapApiError(error));
      await _chat.recordRoomError(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
        errorCode: mapped.code.name,
      );
      throw mapped;
    } on TalkProtocolException catch (error) {
      if (kDebugMode) {
        debugPrint('Chat sync rejected: ${error.code.name} at ${error.path}');
      }
      _ensureAccountActive(accountId);
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

final class _ChatRetryWake {
  _ChatRetryWake({required this.generation, required this.operationId});

  final int generation;
  final String? operationId;
  late final Timer timer;
  bool running = false;
  bool cancelled = false;
}
