import '../json_value.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidSearchResponse;

/// A search excerpt is truncated to this many characters before exposure.
const int messageSearchExcerptMaximumLength = 280;

const String _searchTruncationSuffix = '…';

/// One typed, validated hit from a Talk message unified search provider.
final class MessageSearchResult {
  MessageSearchResult._({
    required this.messageId,
    required this.roomToken,
    required this.author,
    required this.excerpt,
    required this.timestamp,
    required this.resourceUrl,
    required this.wire,
  });

  final int messageId;
  final ConversationToken roomToken;
  final String author;
  final String excerpt;

  /// ASSUMPTION (unverified): Nextcloud's generic unified search entry
  /// contract (`thumbnailUrl`, `title`, `subline`, `resourceUrl`, `icon`,
  /// `rounded`, `attributes`) does not document a timestamp field. This is
  /// populated only when the server adds an optional `attributes.timestamp`
  /// (Unix seconds) beyond the documented `conversation`/`messageId` pair.
  /// Confirm against a real server whether Talk's message search providers
  /// actually send it before relying on this being non-null.
  final DateTime? timestamp;
  final String resourceUrl;
  final Map<String, Object?> wire;

  @override
  String toString() => 'MessageSearchResult(<redacted>)';
}

MessageSearchResult parseMessageSearchResult(
  Object? json, {
  required String path,
}) {
  final entry = requireObject(json, path: path, code: _responseCode);

  final title = requireString(
    entry['title'],
    path: '$path.title',
    code: _responseCode,
    maxLength: 512,
  );
  final subline = requireString(
    entry['subline'],
    path: '$path.subline',
    code: _responseCode,
    maxLength: 4096,
  );
  final resourceUrl = requireString(
    entry['resourceUrl'],
    path: '$path.resourceUrl',
    code: _responseCode,
    minLength: 1,
    maxLength: 2048,
  );
  if (entry['thumbnailUrl'] != null) {
    requireString(
      entry['thumbnailUrl'],
      path: '$path.thumbnailUrl',
      code: _responseCode,
      maxLength: 2048,
    );
  }
  if (entry['icon'] != null) {
    requireString(
      entry['icon'],
      path: '$path.icon',
      code: _responseCode,
      maxLength: 256,
    );
  }
  if (entry['rounded'] != null) {
    requireBool(entry['rounded'], path: '$path.rounded', code: _responseCode);
  }

  final attributes = requireObject(
    entry['attributes'],
    path: '$path.attributes',
    code: _responseCode,
  );
  final roomToken = ConversationToken.parse(
    attributes['conversation'],
    path: '$path.attributes.conversation',
    code: _responseCode,
  );
  final rawMessageId = requireString(
    attributes['messageId'],
    path: '$path.attributes.messageId',
    code: _responseCode,
    minLength: 1,
    maxLength: 20,
  );
  final messageId = int.tryParse(rawMessageId);
  if (messageId == null || messageId < 1) {
    protocolFailure(_responseCode, '$path.attributes.messageId');
  }

  DateTime? timestamp;
  if (attributes['timestamp'] != null) {
    final rawTimestamp = requireInt(
      attributes['timestamp'],
      path: '$path.attributes.timestamp',
      code: _responseCode,
      minimum: 0,
    );
    timestamp = DateTime.fromMillisecondsSinceEpoch(
      rawTimestamp * 1000,
      isUtc: true,
    );
  }

  final excerpt = subline.length > messageSearchExcerptMaximumLength
      ? subline.substring(0, messageSearchExcerptMaximumLength) +
            _searchTruncationSuffix
      : subline;

  return MessageSearchResult._(
    messageId: messageId,
    roomToken: roomToken,
    author: title,
    excerpt: excerpt,
    timestamp: timestamp,
    resourceUrl: resourceUrl,
    wire: entry,
  );
}
