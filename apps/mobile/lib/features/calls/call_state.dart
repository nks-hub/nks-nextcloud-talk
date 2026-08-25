import 'dart:convert';

import '../../data/app_database.dart';

/// The server-reported fact that a call is running in a conversation.
///
/// Only what the wire states plainly is modelled. `callFlag` is a bitmask
/// whose individual bits are not yet bound to a verified upstream reference,
/// so no media detail is derived from it; a call is never inferred from local
/// activity either.
final class ConversationCallState {
  const ConversationCallState({required this.startedAt});

  /// Returns null when the server reports no ongoing call. A malformed or
  /// missing payload also yields null, because a call must never be guessed.
  static ConversationCallState? fromConversation(
    CachedConversation conversation,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(conversation.rawJson);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?> || decoded['hasCall'] != true) {
      return null;
    }
    final startedAt = decoded['callStartTime'];
    return ConversationCallState(
      startedAt: startedAt is int && startedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(startedAt * 1000, isUtc: true)
          : null,
    );
  }

  final DateTime? startedAt;

  /// How long the call has been running, or null when the server did not
  /// report a start time.
  Duration? elapsed({DateTime? now}) {
    final start = startedAt;
    if (start == null) {
      return null;
    }
    final elapsed = (now ?? DateTime.now()).toUtc().difference(start);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  @override
  String toString() =>
      'ConversationCallState(started: ${startedAt != null})';
}
