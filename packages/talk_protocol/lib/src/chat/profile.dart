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
  });

  factory ChatCapabilityProfile.fromSnapshot(
    CapabilitySnapshot snapshot, {
    required bool federated,
  }) {
    final profile = ChatCapabilityProfile.fromTalkFeatures(
      snapshot.talkFeatures.toList(growable: false),
      federated: federated,
    );
    return ChatCapabilityProfile._(
      federated: profile.federated,
      read: profile.read,
      sendText: profile.sendText,
      reply: profile.reply,
      privateReply: profile.privateReply,
      backgroundCatchUp: profile.backgroundCatchUp,
      threadFetch: profile.threadFetch,
      setReadMarker: profile.setReadMarker,
      markUnread: profile.markUnread,
      commonReadStatus:
          snapshot.context == CapabilityContext.authenticated &&
          snapshot.supportsTalk('chat-read-status') &&
          snapshot.chatReadPrivacy == ChatReadPrivacy.public &&
          !federated,
    );
  }

  factory ChatCapabilityProfile.fromTalkFeatures(
    Object? rawFeatures, {
    required bool federated,
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
      commonReadStatus: false,
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

  @override
  String toString() =>
      'ChatCapabilityProfile(federated: $federated, read: $read, '
      'sendText: $sendText, reply: $reply)';
}
