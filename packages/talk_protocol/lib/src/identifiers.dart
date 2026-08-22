import 'json_value.dart';
import 'protocol_exception.dart';

final RegExp _accountTokenPattern = RegExp(r'^[a-z0-9]{4,30}$');

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
    if (!_accountTokenPattern.hasMatch(token)) {
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

bool _hasControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}
