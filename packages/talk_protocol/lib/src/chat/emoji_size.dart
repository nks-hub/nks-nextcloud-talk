/// Enlarged-emoji marker carried in a message's `referenceId`.
///
/// Talk messages are plain text, so the size of an emoji sent with a long press
/// travels in the client-chosen correlation id instead: other clients show an
/// ordinary emoji and ignore the id, this client renders it larger. The UUID
/// part keeps the id unique, so the outbox correlates it like any other one.
final class ChatEmojiSizeReference {
  factory ChatEmojiSizeReference({required String uuid, required int step}) {
    if (!_uuidPattern.hasMatch(uuid) || step < 1 || step > maxStep) {
      throw ArgumentError('Invalid emoji size reference');
    }
    return ChatEmojiSizeReference._(uuid, step);
  }

  const ChatEmojiSizeReference._(this.uuid, this.step);

  /// Largest size step; step 0 is the ordinary size and carries no marker.
  static const int maxStep = 3;

  final String uuid;
  final int step;

  String get referenceId => 'oes1.$step.$uuid';

  static ChatEmojiSizeReference? tryParse(String value) {
    final match = _referencePattern.firstMatch(value);
    if (match == null) return null;
    return ChatEmojiSizeReference._(match[2]!, int.parse(match[1]!));
  }

  @override
  String toString() => 'ChatEmojiSizeReference(<redacted>)';
}

// Same shape as the plain correlation id accepted by `ChatReferenceId`.
const String _uuidSource =
    r'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
final RegExp _uuidPattern = RegExp('^$_uuidSource\$');
final RegExp _referencePattern = RegExp('^oes1\\.([1-3])\\.($_uuidSource)\$');
