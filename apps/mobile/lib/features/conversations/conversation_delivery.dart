import '../../data/app_database.dart';
import '../calls/call_state.dart';
import '../chat/outgoing_message_status.dart';

/// How far the conversation's last message got when this account wrote it:
/// stored on the server, or also read by everyone else in the room. The same
/// rule as the marks on the chat bubbles, read from the room the server last
/// described. Null for a message by somebody else, a system message, and a
/// room described without these fields.
OutgoingMessageDeliveryState? lastMessageDelivery(
  CachedConversation conversation,
) {
  final room = decodedConversationJson(conversation);
  final last = room['lastMessage'];
  if (last is! Map<String, Object?>) {
    return null;
  }
  final id = last['id'];
  final system = last['systemMessage'];
  if (id is! int || id < 1 || (system is String && system.isNotEmpty)) {
    return null;
  }
  final actorType = room['actorType'];
  final actorId = room['actorId'];
  if (actorType is! String ||
      actorId is! String ||
      last['actorType'] != actorType ||
      last['actorId'] != actorId) {
    return null;
  }
  // Zero where the server keeps read status private.
  final commonRead = room['lastCommonReadMessage'];
  return commonRead is int && commonRead >= id
      ? OutgoingMessageDeliveryState.read
      : OutgoingMessageDeliveryState.sent;
}
