import '../json_value.dart';
import '../protocol_exception.dart';

final RegExp _conversationTokenPattern = RegExp(r'^[a-z0-9]{4,30}$');
final RegExp _decimalCursorPattern = RegExp(r'^(0|[1-9][0-9]*)$');
final RegExp _configurationHashPattern = RegExp(r'^[!-~]{1,256}$');

final class AccountId {
  AccountId._(this.value);

  factory AccountId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.accountId',
      code: TalkProtocolErrorCode.invalidConversationIdentifier,
      minLength: 1,
      maxLength: 256,
    );
    if (identifier.trim() != identifier || _hasControlCharacter(identifier)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationIdentifier,
        r'$.accountId',
      );
    }
    return AccountId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) => other is AccountId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AccountId(<redacted>)';
}

final class ConversationToken {
  ConversationToken._(this.value);

  factory ConversationToken.parse(
    Object? value, {
    required String path,
    TalkProtocolErrorCode code =
        TalkProtocolErrorCode.invalidConversationResponse,
  }) {
    final token = requireString(
      value,
      path: path,
      code: code,
      minLength: 4,
      maxLength: 30,
    );
    if (!_conversationTokenPattern.hasMatch(token)) {
      protocolFailure(code, path);
    }
    return ConversationToken._(token);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ConversationToken && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ConversationToken(<redacted>)';
}

final class ConversationCursor {
  ConversationCursor._(this.value);

  factory ConversationCursor.parse(
    Object? value, {
    String path = r'$.cursor',
    TalkProtocolErrorCode code =
        TalkProtocolErrorCode.invalidConversationIdentifier,
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
    return ConversationCursor._(cursor);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ConversationCursor && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ConversationCursor(<redacted>)';
}

final class ConversationConfigurationHash {
  ConversationConfigurationHash._(this.value);

  factory ConversationConfigurationHash.parse(
    Object? value, {
    String path = r'$.configurationHash',
    TalkProtocolErrorCode code =
        TalkProtocolErrorCode.invalidConversationHeaders,
  }) {
    final hash = requireString(
      value,
      path: path,
      code: code,
      minLength: 1,
      maxLength: 256,
    );
    if (!_configurationHashPattern.hasMatch(hash)) {
      protocolFailure(code, path);
    }
    return ConversationConfigurationHash._(hash);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ConversationConfigurationHash && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ConversationConfigurationHash(<redacted>)';
}

final class ConversationRequestId {
  ConversationRequestId._(this.value);

  factory ConversationRequestId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.requestId',
      code: TalkProtocolErrorCode.invalidConversationMerge,
      minLength: 1,
      maxLength: 256,
    );
    if (identifier.trim() != identifier || _hasControlCharacter(identifier)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.requestId',
      );
    }
    return ConversationRequestId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ConversationRequestId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ConversationRequestId(<redacted>)';
}

bool _hasControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}
