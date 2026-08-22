import '../json_value.dart';
import '../protocol_exception.dart';

final RegExp _decimalCursorPattern = RegExp(r'^(0|[1-9][0-9]*)$');
final RegExp _referenceIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _operationIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

final class ChatCursor implements Comparable<ChatCursor> {
  ChatCursor._(this.value);

  factory ChatCursor.parse(
    Object? value, {
    String path = r'$.cursor',
    TalkProtocolErrorCode code = TalkProtocolErrorCode.invalidChatIdentifier,
  }) {
    final cursor = requireString(
      value,
      path: path,
      code: code,
      minLength: 1,
      maxLength: 20,
    );
    if (!_decimalCursorPattern.hasMatch(cursor)) {
      protocolFailure(code, path);
    }
    return ChatCursor._(cursor);
  }

  final String value;

  @override
  int compareTo(ChatCursor other) {
    final lengthOrder = value.length.compareTo(other.value.length);
    return lengthOrder == 0 ? value.compareTo(other.value) : lengthOrder;
  }

  @override
  bool operator ==(Object other) => other is ChatCursor && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ChatCursor(<redacted>)';
}

final class ChatOperationId {
  ChatOperationId._(this.value);

  factory ChatOperationId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.operationId',
      code: TalkProtocolErrorCode.invalidChatIdentifier,
      minLength: 36,
      maxLength: 36,
    );
    if (!_operationIdPattern.hasMatch(identifier)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidChatIdentifier,
        r'$.operationId',
      );
    }
    return ChatOperationId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ChatOperationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ChatOperationId(<redacted>)';
}

final class ChatReferenceId {
  ChatReferenceId._(this.value);

  factory ChatReferenceId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.referenceId',
      code: TalkProtocolErrorCode.invalidChatIdentifier,
      minLength: 36,
      maxLength: 36,
    );
    if (!_referenceIdPattern.hasMatch(identifier)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidChatIdentifier,
        r'$.referenceId',
      );
    }
    return ChatReferenceId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ChatReferenceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ChatReferenceId(<redacted>)';
}

final class ChatRequestId {
  ChatRequestId._(this.value);

  factory ChatRequestId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.requestId',
      code: TalkProtocolErrorCode.invalidChatIdentifier,
      minLength: 1,
      maxLength: 256,
    );
    if (identifier.trim() != identifier || _hasControlCharacter(identifier)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidChatIdentifier,
        r'$.requestId',
      );
    }
    return ChatRequestId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ChatRequestId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ChatRequestId(<redacted>)';
}

bool _hasControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}
