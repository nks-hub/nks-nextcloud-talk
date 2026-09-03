// ignore_for_file: prefer_initializing_formals

part of 'chat_service.dart';

/// What one relayed payload did to the room.
enum _ChatRelayApplication {
  /// Messages above the confirmed anchor were merged.
  merged,

  /// Everything in the payload was already in the scope. The relay repeating
  /// itself is normal; deduplication is by the server-assigned message id.
  nothingNew,

  /// The payload cannot be merged on its own and the room has to be fetched:
  /// a bare `refresh`, or a scope the relay does not deliver messages for.
  fetchRequired,
}

/// The High Performance Backend chat relay, as the chat sync engine's second
/// inlet for one room.
///
/// Relayed messages never take a second path into the database. Each payload
/// is presented as the future-direction response the long poll would have
/// produced and merged by the very same `planChatGetMerge`, so chat blocks,
/// cursors and outbox reconciliation behave identically no matter which
/// transport carried the message.
///
/// Merging a relayed message extends the room's block from the confirmed
/// anchor to that message's id, and that block claims nothing was missed in
/// between. Message ids are global comment ids, so contiguity can never be
/// read off the ids themselves — it has to be earned:
///
/// 1. the signalling session confirms the room, which starts the relay
///    stream;
/// 2. an HTTP catch-up runs *after* that and converges.
///
/// Everything the catch-up did not return was created after the relay was
/// already listening, so the relay will deliver it. From there the claim
/// holds. Anything that can put a hole in the stream drops the trust again —
/// a new HPB session (the room epoch moves; a resume keeps it, because the
/// server replays what the disconnect missed), a lost socket, or a payload
/// that will not merge. The long poll then resumes from the same confirmed
/// anchor and closes the gap through the existing block machinery, which is
/// why a handover can neither lose a message nor deliver one twice.
final class ChatRelayBinding {
  ChatRelayBinding._({
    required ChatService service,
    required this.accountId,
    required this.roomToken,
  }) : _service = service;

  /// A relayed message arriving while trust is being established means the
  /// catch-up that was meant to establish it may have finished reading before
  /// that message existed. One more round settles it; the bound stops a busy
  /// room from looping.
  static const int _maximumTrustRounds = 3;

  final ChatService _service;
  final String accountId;
  final String roomToken;

  int? _epoch;
  bool _trusted = false;
  bool _establishing = false;
  bool _sawWhileUntrusted = false;
  bool _closed = false;
  Completer<void>? _idle;

  /// Whether the relay currently owns delivery for this room.
  bool get isTrusted => _trusted && !_closed;

  /// The signalling session has this room confirmed on [epoch]. Called on
  /// every update while the relay is live; only an epoch change or a lost
  /// stream does any work.
  void activate(int epoch) {
    if (_closed || (_epoch == epoch && (_trusted || _establishing))) {
      return;
    }
    _epoch = epoch;
    _trusted = false;
    unawaited(_establishTrust(epoch));
  }

  /// A relayed `data.chat` payload arrived on [epoch].
  void receive(int epoch, Map<String, Object?> chat) {
    if (_closed || epoch != _epoch) {
      return;
    }
    if (!_trusted) {
      _sawWhileUntrusted = true;
      return;
    }
    unawaited(_apply(epoch, chat));
  }

  /// The relay stream is gone. The long poll owns delivery from the next
  /// cycle, which is why the idle wait is released here rather than left to
  /// time out.
  void deactivate() {
    _epoch = null;
    _trusted = false;
    _wake();
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    deactivate();
    _service._relayBindings.remove(this);
  }

  /// Completes when the relay delivers something or stops being trusted.
  /// Null while the relay is not trusted, which is the long poll's cue to run
  /// normally.
  Future<void>? get _idleWait {
    if (!isTrusted) {
      return null;
    }
    return (_idle ??= Completer<void>()).future;
  }

  Future<void> _establishTrust(int epoch) async {
    if (_establishing) {
      return;
    }
    _establishing = true;
    try {
      for (var round = 0; round < _maximumTrustRounds; round++) {
        _sawWhileUntrusted = false;
        try {
          // Deliberately not `catchUpRoom`: joining the live poll is right
          // for a background reconciler, but here it could join a poll that
          // is standing down for this very relay and return without having
          // read anything, which would establish trust on no evidence at all.
          await _service.syncRoom(accountId: accountId, roomToken: roomToken);
        } on Object {
          // The room stays on the long poll, which reports the failure and
          // retries on its own schedule.
          return;
        }
        if (_closed || _epoch != epoch) {
          return;
        }
        if (!_sawWhileUntrusted) {
          break;
        }
      }
      if (_closed || _epoch != epoch) {
        return;
      }
      _trusted = true;
      _wake();
    } finally {
      _establishing = false;
    }
  }

  Future<void> _apply(int epoch, Map<String, Object?> chat) async {
    try {
      final outcome = await _service._applyRelayChat(
        accountId: accountId,
        roomToken: roomToken,
        chat: chat,
      );
      if (_closed || _epoch != epoch) {
        return;
      }
      if (outcome == _ChatRelayApplication.fetchRequired) {
        await _service.syncRoom(accountId: accountId, roomToken: roomToken);
      }
      _wake();
      return;
    } on Object {
      if (_closed || _epoch != epoch) {
        return;
      }
    }
    // Whatever the relay could not merge cleanly is handed back to HTTP,
    // which re-reads from the confirmed anchor and so cannot skip a message.
    _trusted = false;
    _sawWhileUntrusted = false;
    _wake();
    unawaited(_establishTrust(epoch));
  }

  void _wake() {
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
  }
}

extension _ChatServiceRelay on ChatService {
  /// Merges one relayed payload through the ordinary chat response path.
  ///
  /// Only the room's root scope is delivered this way. A thread scope's
  /// blocks are cut from the same global id space but only ever contain that
  /// thread's messages, so a relayed room message says nothing about where
  /// its future cursor may be moved to; those scopes are fetched instead.
  Future<_ChatRelayApplication> _applyRelayChat({
    required String accountId,
    required String roomToken,
    required Map<String, Object?> chat,
  }) {
    return _serializeRoom<_ChatRelayApplication>(
      _roomKey(accountId, roomToken),
      () async {
        final prepared = await _prepare(accountId, roomToken);
        final relay = decodeChatRelayEvent(
          chat,
          roomToken: prepared.room.token,
        );
        if (relay.comments.isEmpty) {
          return relay.refreshRequested
              ? _ChatRelayApplication.fetchRequired
              : _ChatRelayApplication.nothingNew;
        }
        final scope = (await _chat.getNetworkScope(
          accountId: prepared.account.id,
          roomToken: prepared.conversation.token,
          threadId: null,
        ))!;
        final response = chatRelayGetResponse(
          request: ChatFetchRequest(
            accountId: AccountId.parse(prepared.account.id),
            requestId: ChatRequestId.parse(_uuid.v4()),
            server: prepared.authority.server,
            roomToken: prepared.room.token,
            profile: prepared.profile,
            direction: ChatFetchDirection.future,
            cursor: ChatCursor.parse(scope.futureCursor),
            lastCommonRead: ChatCursor.parse(scope.lastCommonRead),
            limit: ChatService._pageSize,
            includeLastKnown: false,
            timeoutSeconds: 0,
            interactive: true,
            threadId: null,
            futureConverged: scope.futureConverged,
          ),
          comments: relay.comments,
        );
        if (response == null) {
          return _ChatRelayApplication.nothingNew;
        }
        await _ensurePreparedContextCurrent(prepared);
        await _applyGetResponse(prepared, response);
        return _ChatRelayApplication.merged;
      },
    );
  }

  /// The long poll's stand-down. While a trusted relay covers this room's
  /// root scope, the poll waits on the relay instead of holding an HTTP
  /// request open, and resumes the moment the relay stops being trusted.
  Future<void>? _relayIdleWait(_PreparedChat prepared) {
    if (prepared.networkThreadId != null) {
      return null;
    }
    for (final binding in _relayBindings) {
      if (binding.accountId == prepared.account.id &&
          binding.roomToken == prepared.conversation.token) {
        final wait = binding._idleWait;
        if (wait != null) {
          return wait;
        }
      }
    }
    return null;
  }
}
