import '../json_value.dart';
import '../protocol_exception.dart';

final RegExp _safeIdentifierPattern = RegExp(r'^[\x21-\x7e]+$');

final class SignalingRequestId {
  SignalingRequestId._(this.value);

  factory SignalingRequestId.parse(Object? value, {String path = r'$.id'}) =>
      SignalingRequestId._(
        _parseIdentifier(value, path: path, maximumLength: 128),
      );

  final String value;

  @override
  bool operator ==(Object other) =>
      other is SignalingRequestId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SignalingRequestId(<redacted>)';
}

final class SignalingEffectId {
  SignalingEffectId._(this.value);

  factory SignalingEffectId.parse(
    Object? value, {
    String path = r'$.effectId',
  }) => SignalingEffectId._(
    _parseIdentifier(value, path: path, maximumLength: 128),
  );

  final String value;

  @override
  bool operator ==(Object other) =>
      other is SignalingEffectId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SignalingEffectId(<redacted>)';
}

final class HpbSessionId {
  HpbSessionId._(this.value);

  factory HpbSessionId.parse(
    Object? value, {
    String path = r'$.hello.sessionid',
  }) =>
      HpbSessionId._(_parseIdentifier(value, path: path, maximumLength: 1024));

  final String value;

  @override
  bool operator ==(Object other) =>
      other is HpbSessionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'HpbSessionId(<redacted>)';
}

final class HpbResumeId {
  HpbResumeId._(this.value);

  factory HpbResumeId.parse(
    Object? value, {
    String path = r'$.hello.resumeid',
  }) => HpbResumeId._(_parseIdentifier(value, path: path, maximumLength: 2048));

  final String value;

  @override
  bool operator ==(Object other) =>
      other is HpbResumeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'HpbResumeId(<redacted>)';
}

final class SignalingPeerId {
  SignalingPeerId._(this.value);

  factory SignalingPeerId.parse(
    Object? value, {
    String path = r'$.sessionid',
  }) => SignalingPeerId._(
    _parseIdentifier(value, path: path, maximumLength: 1024),
  );

  final String value;

  @override
  bool operator ==(Object other) =>
      other is SignalingPeerId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SignalingPeerId(<redacted>)';
}

String _parseIdentifier(
  Object? value, {
  required String path,
  required int maximumLength,
}) {
  final identifier = requireString(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidSignalingIdentifier,
    minLength: 1,
    maxLength: maximumLength,
  );
  if (!_safeIdentifierPattern.hasMatch(identifier)) {
    protocolFailure(TalkProtocolErrorCode.invalidSignalingIdentifier, path);
  }
  return identifier;
}
