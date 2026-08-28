part of 'chat_repository.dart';

typedef _ThreadReplyScope = ({
  String accountId,
  String roomToken,
  int threadId,
});

final class _ThreadReplyAccumulator {
  _ThreadReplyAccumulator({
    required this.replyIds,
    required this.cachedCountFloor,
  });

  final Set<int> replyIds;
  int? cachedCountFloor;

  int resolve(int? serverCount) {
    if (serverCount != null) {
      cachedCountFloor = serverCount;
      return serverCount;
    }
    final floor = cachedCountFloor;
    final resolved = floor != null && floor > replyIds.length
        ? floor
        : replyIds.length;
    cachedCountFloor = resolved;
    return resolved;
  }
}

ChatFullParent? _matchingThreadParent(ChatMessage message) {
  final threadId = message.threadId;
  final parent = message.parent;
  if (threadId == null ||
      threadId < 1 ||
      parent is! ChatFullParent ||
      parent.messageId != threadId ||
      parent.roomToken != message.roomToken ||
      parent.message.threadId != threadId) {
    return null;
  }
  return parent;
}

int? _storedThreadReplyCount(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is Map<String, Object?>) {
      final value = decoded['threadReplies'];
      if (value is int && value >= 0) {
        return value;
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

ChatSendRequest _restoreSendRequest({
  required ChatAccountState account,
  required TextSendOutboxOperation operation,
  required ChatTextSendAuthority authority,
  required ChatRequestId requestId,
}) {
  return ChatSendRequest.restored(
    accountId: account.accountId,
    requestId: requestId,
    server: account.server,
    roomToken: operation.roomToken,
    operationId: operation.operationId,
    profile: authority.profile,
    message: operation.message,
    referenceId: operation.referenceId,
    replyTo: operation.replyTo,
    threadId: operation.threadId,
    parentRoomToken: operation.parentRoomToken,
    replyToToken: operation.replyToToken,
    silent: operation.silent,
  );
}

/// Decodes the `blocks` column of a [StoredChatScope] row into the ranges of
/// message IDs the client has actually confirmed by fetching them from the
/// server. A scope can hold more than one block: two ranges that are not
/// adjacent mean there is a gap of messages between them that was never
/// fetched. Callers that render cached messages (see `chat_room_pane.dart`)
/// use this to tell honest contiguous history apart from two cached islands
/// with a hole in between, instead of gluing them together.
List<ChatBlock> decodeChatScopeBlocks(String source) => _decodeBlocks(source);

String _encodeBlocks(Iterable<ChatBlock> blocks) => jsonEncode(
  blocks
      .map((block) => [block.start.value, block.end.value])
      .toList(growable: false),
);

List<ChatBlock> _decodeBlocks(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! List<Object?> || decoded.isEmpty) {
    throw StateError('Stored chat blocks are invalid');
  }
  return decoded
      .map((raw) {
        if (raw is! List<Object?> || raw.length != 2) {
          throw StateError('Stored chat block is invalid');
        }
        return ChatBlock(
          start: ChatCursor.parse(raw[0]),
          end: ChatCursor.parse(raw[1]),
        );
      })
      .toList(growable: false);
}

/// Whether the outbox row provably never left this device.
///
/// `queued` was never claimed, so no request body exists. `retryable` is only
/// reached for failures the contract classifies as happening before the
/// server stored a comment, which is exactly why the same payload may be
/// replayed - and therefore dropped - without risking a duplicate. A `failed`
/// row is a deterministic server refusal.
///
/// Everything else may already exist on the server: `sending` is in flight,
/// `awaitingConfirmation` is the contract's explicit ambiguous state,
/// `completed` has a real message, and a `failed` row quarantined out of an
/// ambiguous state by an obsolete replay contract inherits that ambiguity.
/// A known server match, recorded as message IDs, rules out a cancel too.
bool _isCancellableTextSend(StoredTextSendOperation operation) {
  if (operation.errorClass == 'obsolete-replay-contract' ||
      _decodeMessageIds(operation.messageIdsJson).isNotEmpty) {
    return false;
  }
  return const <String>{
    'queued',
    'retryable',
    'failed',
  }.contains(operation.outboxState);
}

List<int> _decodeMessageIds(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! List<Object?> || decoded.any((value) => value is! int)) {
    throw StateError('Stored outbox message IDs are invalid');
  }
  return decoded.cast<int>();
}

TextSendOutboxState _outboxState(String value) {
  return TextSendOutboxState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => throw StateError('Stored outbox state is invalid'),
  );
}

final class _OutgoingTextMessageAccumulator {
  _OutgoingTextMessageAccumulator(
    this.operation, {
    required this.lastCommonRead,
  }) : confirmedMessageIds = _decodeMessageIds(
         operation.messageIdsJson,
       ).toSet();

  final StoredTextSendOperation operation;
  final ChatCursor? lastCommonRead;
  final Set<int> confirmedMessageIds;
  final Map<int, CachedChatMessage> confirmedMessages = {};

  StoredOutgoingTextMessage build() {
    final messages = confirmedMessages.values.toList(growable: false)
      ..sort((left, right) => left.messageId.compareTo(right.messageId));
    return StoredOutgoingTextMessage(
      operation: operation,
      confirmedMessages: messages,
      lastCommonRead: lastCommonRead,
    );
  }
}

ChatAccountLane _accountLane(String value) {
  return ChatAccountLane.values.firstWhere(
    (lane) => lane.name == value,
    orElse: () => throw StateError('Stored chat account lane is invalid'),
  );
}

String _scopeKey(int? threadId) =>
    threadId == null ? _rootScopeKey : 'thread:$threadId';

String _networkScopeKey(int? threadId) =>
    threadId == null ? _networkRootScopeKey : 'network-thread:$threadId';
