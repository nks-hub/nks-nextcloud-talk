import 'dart:convert';

import '../../data/app_database.dart';

/// Why a conversation refuses new messages, when it does.
enum ChatPostingBlock {
  /// The whole conversation is an announcement: nobody but a moderator posts.
  readOnly,

  /// This participant had the chat permission taken away.
  noChatPermission,

  /// The conversation is behind its lobby and this participant is waiting.
  lobby,
}

/// Whether the current participant may post in a conversation.
///
/// Read leniently from the cached room payload. A row written by an older
/// schema, or by a test that only filled the columns it cared about, must read
/// as "may post": the server still refuses what it refuses, so guessing the
/// other way would silence a composer that actually works. Only a payload that
/// positively says otherwise closes it.
final class ChatPostingAccess {
  const ChatPostingAccess._(this.block);

  const ChatPostingAccess.allowed() : block = null;

  /// Reads posting access out of a cached conversation's stored room payload.
  ///
  /// Permission values are measured, not assumed: on the reference server
  /// (Nextcloud 34) `permissions` on the room comes back already resolved -
  /// 510 for an owner, 502 for a plain user, never the bare 0 that would mean
  /// "server defaults". The bit test is therefore safe for an ordinary
  /// participant, who keeps the chat bit and only lacks 8 (ignore lobby).
  factory ChatPostingAccess.fromCachedConversation(
    CachedConversation conversation,
  ) {
    if (conversation.readOnly != 0) {
      return const ChatPostingAccess._(ChatPostingBlock.readOnly);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(conversation.rawJson);
    } on FormatException {
      return const ChatPostingAccess.allowed();
    }
    if (decoded is! Map<String, Object?>) {
      return const ChatPostingAccess.allowed();
    }
    final permissions = decoded['permissions'];
    final lobbyState = decoded['lobbyState'];
    final participantType = decoded['participantType'];
    // A payload without resolved permissions says nothing either way, and a
    // bare 0 is the server's "use the defaults", which include chat.
    if (permissions is int &&
        permissions != 0 &&
        permissions & _chatPermission == 0) {
      return const ChatPostingAccess._(ChatPostingBlock.noChatPermission);
    }
    final moderator =
        participantType is int && _moderatorTypes.contains(participantType);
    if (lobbyState is int &&
        lobbyState != 0 &&
        !moderator &&
        !(permissions is int &&
            permissions & _ignoreLobbyPermission == _ignoreLobbyPermission)) {
      return const ChatPostingAccess._(ChatPostingBlock.lobby);
    }
    return const ChatPostingAccess.allowed();
  }

  /// Null while the participant may post.
  final ChatPostingBlock? block;

  bool get canPost => block == null;

  static const int _chatPermission = 128;
  static const int _ignoreLobbyPermission = 8;
  static const Set<int> _moderatorTypes = <int>{1, 2, 6};
}
