import 'dart:convert';

import '../json_value.dart';
import '../protocol_exception.dart';

final RegExp _opaqueIdentifierPattern = RegExp(r'^[A-Za-z0-9._:-]{1,160}$');
final RegExp _canonicalBase64Pattern = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);

final class PushEffectId {
  PushEffectId._(this.value);

  factory PushEffectId.parse(Object? value) =>
      PushEffectId._(_parseOpaqueIdentifier(value, path: r'$.effectId'));

  final String value;

  @override
  bool operator ==(Object other) =>
      other is PushEffectId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PushEffectId(<redacted>)';
}

final class PushEnvelopeId {
  PushEnvelopeId._(this.value);

  factory PushEnvelopeId.parse(Object? value) =>
      PushEnvelopeId._(_parseOpaqueIdentifier(value, path: r'$.envelopeId'));

  final String value;

  @override
  bool operator ==(Object other) =>
      other is PushEnvelopeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PushEnvelopeId(<redacted>)';
}

final class PushTokenHandle {
  PushTokenHandle._(this.value);

  factory PushTokenHandle.parse(Object? value) => PushTokenHandle._(
    _parseOpaqueIdentifier(value, path: r'$.providerToken.handle'),
  );

  final String value;

  @override
  bool operator ==(Object other) =>
      other is PushTokenHandle && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PushTokenHandle(<redacted>)';
}

final class PushKeyHandle {
  PushKeyHandle._(this.value);

  factory PushKeyHandle.parse(Object? value) => PushKeyHandle._(
    _parseOpaqueIdentifier(value, path: r'$.deviceKey.handle'),
  );

  final String value;

  @override
  bool operator ==(Object other) =>
      other is PushKeyHandle && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PushKeyHandle(<redacted>)';
}

final class PushDeviceIdentifier {
  PushDeviceIdentifier._(this.value, this.decodedLength);

  factory PushDeviceIdentifier.parse(Object? value) {
    final encoded = requireString(
      value,
      path: r'$.deviceIdentifier',
      code: TalkProtocolErrorCode.invalidPushRegistration,
      minLength: 1,
      maxLength: 128,
    );
    final decoded = decodeCanonicalPushBase64(
      encoded,
      path: r'$.deviceIdentifier',
      expectedLength: 64,
      code: TalkProtocolErrorCode.invalidPushRegistration,
    );
    return PushDeviceIdentifier._(encoded, decoded.length);
  }

  final String value;
  final int decodedLength;

  @override
  bool operator ==(Object other) =>
      other is PushDeviceIdentifier && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PushDeviceIdentifier(<redacted>)';
}

final class PushDeviceSignature {
  PushDeviceSignature._(this.value, this.decodedLength);

  factory PushDeviceSignature.parse(Object? value) {
    final encoded = requireString(
      value,
      path: r'$.deviceIdentifierSignature',
      code: TalkProtocolErrorCode.invalidPushRegistration,
      minLength: 1,
      maxLength: 512,
    );
    final decoded = decodeCanonicalPushBase64(
      encoded,
      path: r'$.deviceIdentifierSignature',
      expectedLength: 256,
      code: TalkProtocolErrorCode.invalidPushRegistration,
    );
    return PushDeviceSignature._(encoded, decoded.length);
  }

  final String value;
  final int decodedLength;

  @override
  bool operator ==(Object other) =>
      other is PushDeviceSignature && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PushDeviceSignature(<redacted>)';
}

List<int> decodeCanonicalPushBase64(
  String value, {
  required String path,
  required int expectedLength,
  required TalkProtocolErrorCode code,
}) {
  if (value.isEmpty || !_canonicalBase64Pattern.hasMatch(value)) {
    protocolFailure(code, path);
  }
  try {
    final decoded = base64Decode(value);
    if (decoded.length != expectedLength || base64Encode(decoded) != value) {
      protocolFailure(code, path);
    }
    return decoded;
  } on FormatException {
    protocolFailure(code, path);
  }
}

String _parseOpaqueIdentifier(Object? value, {required String path}) {
  final identifier = requireString(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidPushIdentifier,
    minLength: 1,
    maxLength: 160,
  );
  if (!_opaqueIdentifierPattern.hasMatch(identifier)) {
    protocolFailure(TalkProtocolErrorCode.invalidPushIdentifier, path);
  }
  return identifier;
}
