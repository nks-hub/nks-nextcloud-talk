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
  String toString() => 'ConversationCallState(started: ${startedAt != null})';
}

/// Whether this participant may START a call in the conversation, and with
/// what media.
///
/// The server states all of it plainly and nothing is guessed: `canStartCall`
/// is the room's own answer, `readOnly` closes a conversation to everything,
/// a lobby keeps non-moderators out until it lifts, and `permissions` carries
/// the per-participant bits. A call already running is not this class's
/// business — the banner offers to join that one.
final class ConversationCallStartPolicy {
  const ConversationCallStartPolicy._({
    required this.canStart,
    required this.withVideo,
  });

  static const _denied = ConversationCallStartPolicy._(
    canStart: false,
    withVideo: false,
  );

  /// Talk's participant permission bits, as `CallPermission` in the protocol
  /// package already spells them out. Bit 0 means "default permissions
  /// apply", so the rest are only read when it is clear — the same rule
  /// `CallRoomPolicy` follows there.
  static const _permissionsDefault = 1;
  static const _permissionStartCall = 2;
  static const _permissionPublishAudio = 16;
  static const _permissionPublishVideo = 32;

  static const _participantOwner = 1;
  static const _participantModerator = 2;
  static const _participantGuestModerator = 6;

  static ConversationCallStartPolicy fromConversation(
    CachedConversation conversation,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(conversation.rawJson);
    } on FormatException {
      return _denied;
    }
    if (decoded is! Map<String, Object?>) {
      return _denied;
    }
    // A call already running is joined, not started.
    if (decoded['hasCall'] == true || decoded['canStartCall'] != true) {
      return _denied;
    }
    final readOnly = decoded['readOnly'];
    if (readOnly is int && readOnly != 0) {
      return _denied;
    }
    final participantType = decoded['participantType'];
    final moderator =
        participantType == _participantOwner ||
        participantType == _participantModerator ||
        participantType == _participantGuestModerator;
    final lobbyState = decoded['lobbyState'];
    if (lobbyState is int && lobbyState != 0 && !moderator) {
      return _denied;
    }
    final permissions = decoded['permissions'];
    final bits = permissions is int ? permissions : 0;
    final custom = bits & _permissionsDefault == 0 && bits != 0;
    if (custom && bits & _permissionStartCall == 0) {
      return _denied;
    }
    if (custom && bits & _permissionPublishAudio == 0) {
      // Without a microphone there is nothing to start a call with; Talk
      // treats the audio bit as the floor for joining at all.
      return _denied;
    }
    return ConversationCallStartPolicy._(
      canStart: true,
      withVideo: !custom || bits & _permissionPublishVideo != 0,
    );
  }

  /// Whether to offer starting a call at all.
  final bool canStart;

  /// Whether the camera may be on from the start; a room that forbids
  /// publishing video offers the audio call alone.
  final bool withVideo;
}
