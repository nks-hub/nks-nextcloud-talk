import 'dart:collection';
import 'dart:convert';

import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'crypto_material.dart';
import 'identifiers.dart';

final RegExp _sha512Pattern = RegExp(r'^[a-f0-9]{128}$');

abstract final class PushWireLimits {
  static const int maximumOcsBodyBytes = 32768;
  static const int maximumPlaintextBytes = 4096;
}

final class PushGatewayOrigin {
  PushGatewayOrigin._(this._base);

  factory PushGatewayOrigin.parse(String value) {
    if (value.length > 256) {
      _pushFailure(TalkProtocolErrorCode.invalidPushOrigin, r'$.gateway');
    }
    final base = ServerBase.parse(value);
    if (base.basePath.isNotEmpty || base.uri.scheme != 'https') {
      _pushFailure(TalkProtocolErrorCode.invalidPushOrigin, r'$.gateway');
    }
    return PushGatewayOrigin._(base);
  }

  final ServerBase _base;

  String get value => _base.value;
  Uri get devicesUri => _base.uri.replace(path: '/devices');

  @override
  bool operator ==(Object other) =>
      other is PushGatewayOrigin && other._base == _base;

  @override
  int get hashCode => _base.hashCode;

  @override
  String toString() => 'PushGatewayOrigin(<trusted>)';
}

final class PushRegistrationAuthority {
  PushRegistrationAuthority({
    required this.accountId,
    required this.server,
    required this.gateway,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.cloudId,
    required this.supportsPushV2,
  }) {
    if (credentialGeneration < 1 || capabilityGeneration < 1) {
      _pushFailure(
        TalkProtocolErrorCode.invalidPushRegistration,
        r'$.authority.generation',
      );
    }
    final cloud = cloudId;
    if (cloud != null &&
        (cloud.isEmpty ||
            cloud.length > 512 ||
            cloud.trim() != cloud ||
            _hasControlCharacter(cloud))) {
      _pushFailure(
        TalkProtocolErrorCode.invalidPushRegistration,
        r'$.authority.cloudId',
      );
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final PushGatewayOrigin gateway;
  final int credentialGeneration;
  final int capabilityGeneration;
  final String? cloudId;
  final bool supportsPushV2;

  bool bindingEquals(PushRegistrationAuthority other) =>
      accountId == other.accountId &&
      server == other.server &&
      gateway == other.gateway &&
      credentialGeneration == other.credentialGeneration &&
      capabilityGeneration == other.capabilityGeneration &&
      cloudId == other.cloudId &&
      supportsPushV2 == other.supportsPushV2;

  @override
  String toString() =>
      'PushRegistrationAuthority(account: <redacted>, server: <redacted>)';
}

final class PushProviderTokenBinding {
  PushProviderTokenBinding({
    required this.handle,
    required this.sha512,
    required this.generation,
  }) {
    if (!_sha512Pattern.hasMatch(sha512) || generation < 1) {
      _pushFailure(
        TalkProtocolErrorCode.invalidPushRegistration,
        r'$.providerToken',
      );
    }
  }

  final PushTokenHandle handle;
  final String sha512;
  final int generation;

  bool bindingEquals(PushProviderTokenBinding other) =>
      handle == other.handle &&
      sha512 == other.sha512 &&
      generation == other.generation;

  @override
  String toString() => 'PushProviderTokenBinding(<redacted>)';
}

final class PushDeviceKeyBinding {
  PushDeviceKeyBinding({
    required this.handle,
    required this.publicKey,
    required this.generation,
  }) {
    if (generation < 1) {
      _pushFailure(
        TalkProtocolErrorCode.invalidPushCryptoMaterial,
        r'$.deviceKey.generation',
      );
    }
  }

  final PushKeyHandle handle;
  final PushRsaPublicKey publicKey;
  final int generation;

  bool bindingEquals(PushDeviceKeyBinding other) =>
      handle == other.handle &&
      publicKey == other.publicKey &&
      generation == other.generation;

  @override
  String toString() => 'PushDeviceKeyBinding(<redacted>)';
}

final class PushServerRegistration {
  const PushServerRegistration({
    required this.deviceIdentifier,
    required this.deviceIdentifierSignature,
    required this.userPublicKey,
  });

  final PushDeviceIdentifier deviceIdentifier;
  final PushDeviceSignature deviceIdentifierSignature;
  final PushRsaPublicKey userPublicKey;

  bool bindingEquals(PushServerRegistration other) =>
      deviceIdentifier == other.deviceIdentifier &&
      deviceIdentifierSignature == other.deviceIdentifierSignature &&
      userPublicKey == other.userPublicKey;

  @override
  String toString() => 'PushServerRegistration(<redacted>)';
}

final class PushEnvelope {
  PushEnvelope._({
    required this.envelopeId,
    required List<int> ciphertext,
    required List<int> signature,
  }) : ciphertext = UnmodifiableListView<int>(List<int>.of(ciphertext)),
       signature = UnmodifiableListView<int>(List<int>.of(signature));

  factory PushEnvelope.parse({
    required PushEnvelopeId envelopeId,
    required String subjectBase64,
    required String signatureBase64,
  }) => PushEnvelope._(
    envelopeId: envelopeId,
    ciphertext: decodeCanonicalPushBase64(
      subjectBase64,
      path: r'$.subject',
      expectedLength: 256,
      code: TalkProtocolErrorCode.invalidPushEnvelope,
    ),
    signature: decodeCanonicalPushBase64(
      signatureBase64,
      path: r'$.signature',
      expectedLength: 256,
      code: TalkProtocolErrorCode.invalidPushEnvelope,
    ),
  );

  final PushEnvelopeId envelopeId;
  final List<int> ciphertext;
  final List<int> signature;

  @override
  String toString() => 'PushEnvelope(<redacted>)';
}

enum PushWakeUpAction { catchUp, deleteOne, deleteMultiple, deleteAll }

final class PushWakeUpPayload {
  PushWakeUpPayload._({
    required this.action,
    required this.app,
    required this.subject,
    required this.type,
    required this.objectId,
    required this.notificationId,
    required List<int> notificationIds,
  }) : notificationIds = UnmodifiableListView<int>(notificationIds);

  final PushWakeUpAction action;
  final String? app;
  final String? subject;
  final String? type;
  final String? objectId;
  final int? notificationId;
  final List<int> notificationIds;

  @override
  String toString() => 'PushWakeUpPayload(action: ${action.name}, <redacted>)';
}

PushWakeUpPayload decodePushWakeUpPayload(String source) {
  if (utf8.encode(source).length > PushWireLimits.maximumPlaintextBytes) {
    _pushFailure(TalkProtocolErrorCode.invalidPushPayload, r'$.plaintext');
  }
  final decoded = decodeJsonRejectingDuplicateMembers(
    source,
    code: TalkProtocolErrorCode.invalidPushPayload,
    path: r'$.plaintext',
  );
  final object = requireObject(
    decoded,
    path: r'$.plaintext',
    code: TalkProtocolErrorCode.invalidPushPayload,
  );
  const actionKeys = <String>{'delete', 'delete-multiple', 'delete-all'};
  final presentActionKeys = actionKeys.where(object.containsKey).toList();
  if (presentActionKeys.length > 1) {
    _pushFailure(TalkProtocolErrorCode.invalidPushPayload, r'$.plaintext');
  }
  final action = presentActionKeys.isEmpty
      ? PushWakeUpAction.catchUp
      : switch (presentActionKeys.single) {
          'delete' => PushWakeUpAction.deleteOne,
          'delete-multiple' => PushWakeUpAction.deleteMultiple,
          'delete-all' => PushWakeUpAction.deleteAll,
          _ => throw StateError('The action-key set is exhaustive.'),
        };
  if (presentActionKeys.isNotEmpty) {
    final actionKey = presentActionKeys.single;
    final enabled = requireBool(
      object[actionKey],
      path:
          r'$.plaintext.'
          '$actionKey',
      code: TalkProtocolErrorCode.invalidPushPayload,
    );
    if (!enabled) {
      _pushFailure(TalkProtocolErrorCode.invalidPushPayload, r'$.plaintext');
    }
  }
  final allowedKeys = switch (action) {
    PushWakeUpAction.catchUp => const <String>{
      'app',
      'subject',
      'type',
      'id',
      'nid',
    },
    PushWakeUpAction.deleteOne => const <String>{'delete', 'nid'},
    PushWakeUpAction.deleteMultiple => const <String>{
      'delete-multiple',
      'nids',
    },
    PushWakeUpAction.deleteAll => const <String>{'delete-all'},
  };
  final requiresEveryKey = action != PushWakeUpAction.catchUp;
  if (object.isEmpty ||
      object.keys.any((key) => !allowedKeys.contains(key)) ||
      (requiresEveryKey && object.length != allowedKeys.length)) {
    _pushFailure(TalkProtocolErrorCode.invalidPushPayload, r'$.plaintext');
  }

  switch (action) {
    case PushWakeUpAction.catchUp:
      final app = _optionalString(object, 'app', maximum: 128);
      final subject = _optionalString(object, 'subject', maximum: 2048);
      final type = _optionalString(object, 'type', maximum: 128);
      final objectId = _optionalString(object, 'id', maximum: 512);
      final notificationId = _optionalPositiveInt(object, 'nid');
      return PushWakeUpPayload._(
        action: action,
        app: app,
        subject: subject,
        type: type,
        objectId: objectId,
        notificationId: notificationId,
        notificationIds: const <int>[],
      );
    case PushWakeUpAction.deleteOne:
      return PushWakeUpPayload._(
        action: action,
        app: null,
        subject: null,
        type: null,
        objectId: null,
        notificationId: _optionalPositiveInt(object, 'nid'),
        notificationIds: const <int>[],
      );
    case PushWakeUpAction.deleteMultiple:
      return PushWakeUpPayload._(
        action: action,
        app: null,
        subject: null,
        type: null,
        objectId: null,
        notificationId: null,
        notificationIds: _optionalPositiveIntList(object, 'nids'),
      );
    case PushWakeUpAction.deleteAll:
      return PushWakeUpPayload._(
        action: action,
        app: null,
        subject: null,
        type: null,
        objectId: null,
        notificationId: null,
        notificationIds: const <int>[],
      );
  }
}

int? _optionalPositiveInt(Map<String, Object?> object, String key) {
  if (!object.containsKey(key)) {
    return null;
  }
  return requireInt(
    object[key],
    path:
        r'$.plaintext.'
        '$key',
    code: TalkProtocolErrorCode.invalidPushPayload,
    minimum: 1,
    maximum: 0x7fffffffffffffff,
  );
}

List<int> _optionalPositiveIntList(Map<String, Object?> object, String key) {
  if (!object.containsKey(key)) {
    return const <int>[];
  }
  final value = object[key];
  final list = requireList(
    value,
    path:
        r'$.plaintext.'
        '$key',
    code: TalkProtocolErrorCode.invalidPushPayload,
  );
  if (list.isEmpty || list.length > 100) {
    _pushFailure(TalkProtocolErrorCode.invalidPushPayload, r'$.plaintext.nids');
  }
  final result = <int>[];
  final unique = <int>{};
  for (var index = 0; index < list.length; index++) {
    final item = requireInt(
      list[index],
      path:
          r'$.plaintext.nids['
          '$index]',
      code: TalkProtocolErrorCode.invalidPushPayload,
      minimum: 1,
      maximum: 0x7fffffffffffffff,
    );
    if (!unique.add(item)) {
      _pushFailure(
        TalkProtocolErrorCode.invalidPushPayload,
        r'$.plaintext.nids',
      );
    }
    result.add(item);
  }
  return result;
}

String? _optionalString(
  Map<String, Object?> object,
  String key, {
  required int maximum,
}) {
  if (!object.containsKey(key)) {
    return null;
  }
  return requireString(
    object[key],
    path:
        r'$.plaintext.'
        '$key',
    code: TalkProtocolErrorCode.invalidPushPayload,
    minLength: 1,
    maxLength: maximum,
  );
}

bool _hasControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

Never _pushFailure(TalkProtocolErrorCode code, String path) =>
    protocolFailure(code, path);
