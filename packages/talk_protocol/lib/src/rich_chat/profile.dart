import '../json_value.dart';
import '../protocol_exception.dart';

const int _reactPermission = 256;

/// Capability-derived rich-chat behavior for one room and account.
final class RichChatCapabilityProfile {
  const RichChatCapabilityProfile._({
    required this.federated,
    required this.reply,
    required this.mentions,
    required this.threadMetadata,
    required this.threadMessageFetch,
    required this.reactions,
    required this.canReact,
    required this.edit,
    required this.delete,
    required this.deleteAny,
    required this.pin,
    required this.hidePinned,
    required this.reminders,
    required this.scheduled,
  });

  factory RichChatCapabilityProfile.fromTalkFeatures({
    required Object? talkFeatures,
    required Object? talkLocalFeatures,
    required bool federated,
    required bool moderator,
    required int participantPermissions,
  }) {
    if (participantPermissions < 0) {
      _profileFailure(r'$.participantPermissions');
    }
    final global = _features(talkFeatures, r'$.talkFeatures');
    final local = _features(talkLocalFeatures, r'$.talkLocalFeatures');
    final base = global.contains('chat-v2');
    final reply =
        base &&
        global.contains('chat-reference-id') &&
        global.contains('chat-replies');
    final threads = base && global.contains('threads');
    final reactions = base && global.contains('reactions');
    final reactionPermission =
        !global.contains('react-permission') ||
        participantPermissions & _reactPermission == _reactPermission;
    final pinned = base && global.contains('pinned-messages');
    return RichChatCapabilityProfile._(
      federated: federated,
      reply: reply,
      mentions: base,
      threadMetadata: threads,
      threadMessageFetch: threads,
      reactions: reactions,
      canReact: reactions && reactionPermission,
      edit: base && global.contains('edit-messages'),
      delete: base && global.contains('delete-messages'),
      // A moderator deletes anyone's message, not just their own. Measured
      // against Nextcloud 34: the owner of a room deleted a message written
      // by another participant and the server answered 200, turning it into
      // a `message_deleted` notice. The time window stays the server's
      // business, exactly as it already is for one's own messages.
      deleteAny: base && global.contains('delete-messages') && moderator,
      pin: pinned && moderator,
      hidePinned: pinned,
      reminders: base && global.contains('remind-me-later'),
      scheduled: base && local.contains('scheduled-messages') && !federated,
    );
  }

  final bool federated;
  final bool reply;
  final bool mentions;
  final bool threadMetadata;
  final bool threadMessageFetch;
  final bool reactions;
  final bool canReact;
  final bool edit;
  final bool delete;

  /// Whether this account may delete a message somebody else wrote.
  final bool deleteAny;
  final bool pin;
  final bool hidePinned;
  final bool reminders;
  final bool scheduled;

  @override
  String toString() =>
      'RichChatCapabilityProfile(federated: $federated, '
      'reply: $reply, mentions: $mentions, threads: $threadMetadata, '
      'reactions: $reactions, scheduled: $scheduled)';
}

Set<String> _features(Object? raw, String path) {
  final features = requireUniqueStringSet(
    raw,
    path: path,
    code: TalkProtocolErrorCode.invalidRichChatProfile,
  );
  for (final feature in features) {
    if (feature.isEmpty ||
        feature.length > 128 ||
        feature.codeUnits.any((unit) => unit < 0x20)) {
      _profileFailure(path);
    }
  }
  return features;
}

Never _profileFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidRichChatProfile, path);
