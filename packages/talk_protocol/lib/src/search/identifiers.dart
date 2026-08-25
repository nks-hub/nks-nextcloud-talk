import '../json_value.dart';
import '../protocol_exception.dart';

export '../identifiers.dart' show AccountId, ConversationToken;

/// Correlates a [MessageSearchRequest] with its response for diagnostics.
final class SearchRequestId {
  SearchRequestId._(this.value);

  factory SearchRequestId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.requestId',
      code: TalkProtocolErrorCode.invalidSearchIdentifier,
      minLength: 1,
      maxLength: 256,
    );
    if (identifier.trim() != identifier || _hasControlCharacter(identifier)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidSearchIdentifier,
        r'$.requestId',
      );
    }
    return SearchRequestId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is SearchRequestId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SearchRequestId(<redacted>)';
}

bool _hasControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}
