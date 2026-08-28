import '../bootstrap/capabilities.dart';
import '../json_value.dart';
import '../protocol_exception.dart';

final class ChatCapabilityProfile {
  ChatCapabilityProfile._({
    required this.federated,
    required this.read,
    required this.sendText,
    required this.reply,
    required this.privateReply,
    required this.backgroundCatchUp,
    required this.threadFetch,
    required this.setReadMarker,
    required this.markUnread,
    required this.commonReadStatus,
    required this.silentSend,
  });

  factory ChatCapabilityProfile.fromSnapshot(
    CapabilitySnapshot snapshot, {
    required bool federated,
  }) {
    return ChatCapabilityProfile.fromTalkFeatures(
      snapshot.talkFeatures.toList(growable: false),
      federated: federated,
      readPrivacyIsPublic:
          snapshot.context == CapabilityContext.authenticated &&
          snapshot.chatReadPrivacy == ChatReadPrivacy.public,
    );
  }

  /// Builds the profile from the Talk feature list alone.
  ///
  /// [readPrivacyIsPublic] has to be supplied by the caller because the
  /// feature list does not carry it: whether other people's read markers are
  /// visible is an account setting, not a server capability. Callers that
  /// only have the cached feature list leave it at its default, which turns
  /// the common read status off rather than claiming a marker the server may
  /// refuse to share.
  factory ChatCapabilityProfile.fromTalkFeatures(
    Object? rawFeatures, {
    required bool federated,
    bool readPrivacyIsPublic = false,
  }) {
    final features = requireUniqueStringSet(
      rawFeatures,
      path: r'$.talkFeatures',
      code: TalkProtocolErrorCode.invalidChatProfile,
    );
    for (final feature in features) {
      if (feature.isEmpty ||
          feature.length > 128 ||
          feature.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
        protocolFailure(
          TalkProtocolErrorCode.invalidChatProfile,
          r'$.talkFeatures',
        );
      }
    }

    final read = features.contains('chat-v2');
    final sendText = read && features.contains('chat-reference-id');
    final reply = sendText && features.contains('chat-replies');
    final marker = read && features.contains('chat-read-marker');
    return ChatCapabilityProfile._(
      federated: federated,
      read: read,
      sendText: sendText,
      reply: reply,
      privateReply: reply && features.contains('private-reply') && !federated,
      backgroundCatchUp: read && features.contains('chat-keep-notifications'),
      threadFetch: read && features.contains('threads') && !federated,
      setReadMarker: marker && features.contains('chat-read-last'),
      markUnread: marker && features.contains('chat-unread'),
      commonReadStatus:
          read &&
          features.contains('chat-read-status') &&
          readPrivacyIsPublic &&
          !federated,
      silentSend: sendText && features.contains('silent-send'),
    );
  }

  final bool federated;
  final bool read;
  final bool sendText;
  final bool reply;
  final bool privateReply;
  final bool backgroundCatchUp;
  final bool threadFetch;
  final bool setReadMarker;
  final bool markUnread;
  final bool commonReadStatus;

  /// Whether the server accepts a message that raises no notification.
  final bool silentSend;

  @override
  String toString() =>
      'ChatCapabilityProfile(federated: $federated, read: $read, '
      'sendText: $sendText, reply: $reply)';
}
