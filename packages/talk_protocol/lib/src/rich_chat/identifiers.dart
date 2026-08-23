import '../json_value.dart';
import '../protocol_exception.dart';

final RegExp _snowflakePattern = RegExp(r'^[1-9][0-9]{0,39}$');

/// A server-issued numeric identifier that can exceed the platform integer.
final class RichChatScheduleId {
  const RichChatScheduleId._(this.value);

  factory RichChatScheduleId.parse(
    Object? value, {
    String path = r'$.scheduleId',
    TalkProtocolErrorCode code = TalkProtocolErrorCode.invalidRichChatRequest,
  }) {
    final identifier = requireString(value, path: path, code: code);
    if (!_snowflakePattern.hasMatch(identifier)) {
      protocolFailure(code, path);
    }
    return RichChatScheduleId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is RichChatScheduleId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'RichChatScheduleId(<redacted>)';
}

/// Account-bound actor identity used only to derive self reaction aggregates.
final class RichChatActorIdentity {
  RichChatActorIdentity({required Object? actorType, required Object? actorId})
    : actorType = requireString(
        actorType,
        path: r'$.actorType',
        code: TalkProtocolErrorCode.invalidRichChatRequest,
        minLength: 1,
        maxLength: 128,
      ),
      actorId = requireString(
        actorId,
        path: r'$.actorId',
        code: TalkProtocolErrorCode.invalidRichChatRequest,
        maxLength: 4096,
      );

  final String actorType;
  final String actorId;

  @override
  bool operator ==(Object other) =>
      other is RichChatActorIdentity &&
      other.actorType == actorType &&
      other.actorId == actorId;

  @override
  int get hashCode => Object.hash(actorType, actorId);

  @override
  String toString() => 'RichChatActorIdentity(<redacted>)';
}
