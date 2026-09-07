import '../json_value.dart';
import '../protocol_exception.dart';

const int _reactPermission = 256;

/// Capability-derived rich-chat behavior for one room and account.
final class RichChatCapabilityProfile {
  const RichChatCapabilityProfile._({
    required this.federated,
    required this.reply,
    required this.privateReply,
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
    required this.translation,
    required this.silentSend,
    required this.geoLocation,
  });

  factory RichChatCapabilityProfile.fromTalkFeatures({
    required Object? talkFeatures,
    required Object? talkLocalFeatures,
    required bool federated,
    required bool moderator,
    required int participantPermissions,
    bool translationAvailable = false,
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
    // A bare 0 is the server's "use the defaults", which include reacting —
    // NOT "nothing is allowed". Testing the bit over a bare zero refuses every
    // permission at once, which on a server that advertises `react-permission`
    // took reactions away from every ordinary participant. The same mistake in
    // the same file once made reactions unavailable to everybody, that time by
    // reading the per-participant override instead of the effective value.
    final reactionPermission =
        !global.contains('react-permission') ||
        participantPermissions == 0 ||
        participantPermissions & _reactPermission == _reactPermission;
    final pinned = base && global.contains('pinned-messages');
    return RichChatCapabilityProfile._(
      federated: federated,
      reply: reply,
      // Same derivation the send-side `ChatCapabilityProfile` uses, so the
      // action offered in the sheet and the operation the outbox admits
      // cannot disagree. A federated room is excluded on both sides: the
      // eligibility snapshot rejects it outright.
      privateReply: reply && global.contains('private-reply') && !federated,
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
      translation: translationAvailable,
      silentSend: base && global.contains('silent-send'),
      geoLocation: base && global.contains('geo-location-sharing'),
    );
  }

  final bool federated;
  final bool reply;

  /// Whether this account may answer a message privately in the one-to-one
  /// conversation with its author.
  final bool privateReply;
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
  final bool translation;
  final bool silentSend;
  final bool geoLocation;

  @override
  String toString() =>
      'RichChatCapabilityProfile(federated: $federated, '
      'reply: $reply, mentions: $mentions, threads: $threadMetadata, '
      'reactions: $reactions, scheduled: $scheduled, '
      'translation: $translation)';
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
