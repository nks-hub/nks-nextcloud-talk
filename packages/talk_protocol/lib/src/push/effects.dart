import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';

enum PushEffectKind {
  ensureDeviceKey,
  registerNextcloud,
  registerGateway,
  unregisterNextcloud,
  unregisterGateway,
  destroyDeviceKey,
}

enum PushCompletionClass {
  success,
  conflict,
  reauthenticationRequired,
  transientFailure,
  rejected,
}

final class PushEffectContext {
  PushEffectContext({
    required this.effectId,
    required this.accountId,
    required this.server,
    required this.gateway,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.providerTokenGeneration,
    required this.keyGeneration,
    required this.registrationRevision,
  }) {
    if (credentialGeneration < 1 ||
        capabilityGeneration < 1 ||
        providerTokenGeneration < 1 ||
        keyGeneration < 0 ||
        registrationRevision < 0) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushState,
        r'$.effect.context',
      );
    }
  }

  factory PushEffectContext.forAuthority({
    required PushEffectId effectId,
    required PushRegistrationAuthority authority,
    required int providerTokenGeneration,
    required int keyGeneration,
    required int registrationRevision,
  }) => PushEffectContext(
    effectId: effectId,
    accountId: authority.accountId,
    server: authority.server,
    gateway: authority.gateway,
    credentialGeneration: authority.credentialGeneration,
    capabilityGeneration: authority.capabilityGeneration,
    providerTokenGeneration: providerTokenGeneration,
    keyGeneration: keyGeneration,
    registrationRevision: registrationRevision,
  );

  final PushEffectId effectId;
  final AccountId accountId;
  final ServerBase server;
  final PushGatewayOrigin gateway;
  final int credentialGeneration;
  final int capabilityGeneration;
  final int providerTokenGeneration;
  final int keyGeneration;
  final int registrationRevision;

  bool bindingEquals(PushEffectContext other) =>
      effectId == other.effectId &&
      accountId == other.accountId &&
      server == other.server &&
      gateway == other.gateway &&
      credentialGeneration == other.credentialGeneration &&
      capabilityGeneration == other.capabilityGeneration &&
      providerTokenGeneration == other.providerTokenGeneration &&
      keyGeneration == other.keyGeneration &&
      registrationRevision == other.registrationRevision;

  @override
  String toString() => 'PushEffectContext(<redacted>)';
}

sealed class PushEffect {
  const PushEffect({required this.context});

  final PushEffectContext context;
  PushEffectKind get kind;

  bool bindingEquals(PushEffect other);

  @override
  String toString() => 'PushEffect(${kind.name}, <redacted>)';
}

final class EnsurePushDeviceKeyEffect extends PushEffect {
  const EnsurePushDeviceKeyEffect({required super.context});

  @override
  PushEffectKind get kind => PushEffectKind.ensureDeviceKey;

  @override
  bool bindingEquals(PushEffect other) =>
      other is EnsurePushDeviceKeyEffect &&
      context.bindingEquals(other.context);
}

final class RegisterPushWithNextcloudEffect extends PushEffect {
  RegisterPushWithNextcloudEffect({
    required super.context,
    required this.providerToken,
    required this.key,
  }) {
    if (context.providerTokenGeneration != providerToken.generation ||
        context.keyGeneration != key.generation) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushState,
        r'$.effect.registerNextcloud',
      );
    }
  }

  final PushProviderTokenBinding providerToken;
  final PushDeviceKeyBinding key;

  @override
  PushEffectKind get kind => PushEffectKind.registerNextcloud;

  Uri get uri => _nextcloudPushUri(context);

  Map<String, String> get formFields => <String, String>{
    'pushTokenHash': providerToken.sha512,
    'devicePublicKey': key.publicKey.pem,
    'proxyServer': context.gateway.value,
  };

  @override
  bool bindingEquals(PushEffect other) =>
      other is RegisterPushWithNextcloudEffect &&
      context.bindingEquals(other.context) &&
      providerToken.bindingEquals(other.providerToken) &&
      key.bindingEquals(other.key);
}

final class RegisterPushWithGatewayEffect extends PushEffect {
  RegisterPushWithGatewayEffect({
    required super.context,
    required this.providerToken,
    required this.registration,
    required this.cloudId,
  }) {
    if (context.providerTokenGeneration != providerToken.generation ||
        context.registrationRevision < 1 ||
        (cloudId != null && cloudId!.isEmpty)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushState,
        r'$.effect.registerGateway',
      );
    }
  }

  final PushProviderTokenBinding providerToken;
  final PushServerRegistration registration;
  final String? cloudId;

  @override
  PushEffectKind get kind => PushEffectKind.registerGateway;

  Uri get uri => context.gateway.devicesUri;

  Map<String, String> get identityFields {
    final fields = <String, String>{
      'deviceIdentifier': registration.deviceIdentifier.value,
      'deviceIdentifierSignature': registration.deviceIdentifierSignature.value,
      'userPublicKey': registration.userPublicKey.pem,
    };
    final recoveryCloudId = cloudId;
    if (recoveryCloudId != null) {
      fields['cloudId'] = recoveryCloudId;
    }
    return fields;
  }

  @override
  bool bindingEquals(PushEffect other) =>
      other is RegisterPushWithGatewayEffect &&
      context.bindingEquals(other.context) &&
      providerToken.bindingEquals(other.providerToken) &&
      registration.bindingEquals(other.registration) &&
      cloudId == other.cloudId;
}

final class UnregisterPushFromNextcloudEffect extends PushEffect {
  const UnregisterPushFromNextcloudEffect({required super.context});

  @override
  PushEffectKind get kind => PushEffectKind.unregisterNextcloud;

  Uri get uri => _nextcloudPushUri(context);

  @override
  bool bindingEquals(PushEffect other) =>
      other is UnregisterPushFromNextcloudEffect &&
      context.bindingEquals(other.context);
}

final class UnregisterPushFromGatewayEffect extends PushEffect {
  UnregisterPushFromGatewayEffect({
    required super.context,
    required this.registration,
  }) {
    if (context.registrationRevision < 1) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushState,
        r'$.effect.unregisterGateway',
      );
    }
  }

  final PushServerRegistration registration;

  @override
  PushEffectKind get kind => PushEffectKind.unregisterGateway;

  Map<String, String> get identityQueryParameters => <String, String>{
    'deviceIdentifier': registration.deviceIdentifier.value,
    'deviceIdentifierSignature': registration.deviceIdentifierSignature.value,
    'userPublicKey': registration.userPublicKey.pem,
  };

  Uri get uri => context.gateway.devicesUri.replace(
    queryParameters: identityQueryParameters,
  );

  @override
  bool bindingEquals(PushEffect other) =>
      other is UnregisterPushFromGatewayEffect &&
      context.bindingEquals(other.context) &&
      registration.bindingEquals(other.registration);
}

final class DestroyPushDeviceKeyEffect extends PushEffect {
  DestroyPushDeviceKeyEffect({required super.context, required this.key}) {
    if (context.keyGeneration != key.generation) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushState,
        r'$.effect.destroyDeviceKey',
      );
    }
  }

  final PushDeviceKeyBinding key;

  @override
  PushEffectKind get kind => PushEffectKind.destroyDeviceKey;

  @override
  bool bindingEquals(PushEffect other) =>
      other is DestroyPushDeviceKeyEffect &&
      context.bindingEquals(other.context) &&
      key.bindingEquals(other.key);
}

sealed class PushEffectCompletion {
  const PushEffectCompletion({
    required this.effect,
    required this.classification,
  });

  final PushEffect effect;
  final PushCompletionClass classification;

  @override
  String toString() =>
      'PushEffectCompletion(${classification.name}, <redacted>)';
}

final class PushDeviceKeyCompletion extends PushEffectCompletion {
  const PushDeviceKeyCompletion.success({
    required EnsurePushDeviceKeyEffect effect,
    required PushDeviceKeyBinding this.key,
  }) : super(effect: effect, classification: PushCompletionClass.success);

  PushDeviceKeyCompletion.failure({
    required EnsurePushDeviceKeyEffect effect,
    required PushCompletionClass classification,
  }) : key = null,
       super(effect: effect, classification: classification) {
    if (classification == PushCompletionClass.success ||
        classification == PushCompletionClass.conflict) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushState,
        r'$.completion.classification',
      );
    }
  }

  final PushDeviceKeyBinding? key;

  @override
  EnsurePushDeviceKeyEffect get effect =>
      super.effect as EnsurePushDeviceKeyEffect;
}

final class PushNextcloudRegistrationCompletion extends PushEffectCompletion {
  const PushNextcloudRegistrationCompletion.success({
    required RegisterPushWithNextcloudEffect effect,
    required PushServerRegistration this.registration,
  }) : super(effect: effect, classification: PushCompletionClass.success);

  const PushNextcloudRegistrationCompletion.transientFailure({
    required RegisterPushWithNextcloudEffect effect,
  }) : registration = null,
       super(
         effect: effect,
         classification: PushCompletionClass.transientFailure,
       );

  const PushNextcloudRegistrationCompletion.reauthenticationRequired({
    required RegisterPushWithNextcloudEffect effect,
  }) : registration = null,
       super(
         effect: effect,
         classification: PushCompletionClass.reauthenticationRequired,
       );

  const PushNextcloudRegistrationCompletion.rejected({
    required RegisterPushWithNextcloudEffect effect,
  }) : registration = null,
       super(effect: effect, classification: PushCompletionClass.rejected);

  final PushServerRegistration? registration;

  @override
  RegisterPushWithNextcloudEffect get effect =>
      super.effect as RegisterPushWithNextcloudEffect;
}

final class PushGatewayRegistrationCompletion extends PushEffectCompletion {
  const PushGatewayRegistrationCompletion.success({
    required RegisterPushWithGatewayEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.success);

  const PushGatewayRegistrationCompletion.conflict({
    required RegisterPushWithGatewayEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.conflict);

  const PushGatewayRegistrationCompletion.transientFailure({
    required RegisterPushWithGatewayEffect effect,
  }) : super(
         effect: effect,
         classification: PushCompletionClass.transientFailure,
       );

  const PushGatewayRegistrationCompletion.reauthenticationRequired({
    required RegisterPushWithGatewayEffect effect,
  }) : super(
         effect: effect,
         classification: PushCompletionClass.reauthenticationRequired,
       );

  const PushGatewayRegistrationCompletion.rejected({
    required RegisterPushWithGatewayEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.rejected);

  @override
  RegisterPushWithGatewayEffect get effect =>
      super.effect as RegisterPushWithGatewayEffect;
}

final class PushNextcloudUnregistrationCompletion extends PushEffectCompletion {
  const PushNextcloudUnregistrationCompletion.success({
    required UnregisterPushFromNextcloudEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.success);

  const PushNextcloudUnregistrationCompletion.transientFailure({
    required UnregisterPushFromNextcloudEffect effect,
  }) : super(
         effect: effect,
         classification: PushCompletionClass.transientFailure,
       );

  const PushNextcloudUnregistrationCompletion.reauthenticationRequired({
    required UnregisterPushFromNextcloudEffect effect,
  }) : super(
         effect: effect,
         classification: PushCompletionClass.reauthenticationRequired,
       );

  const PushNextcloudUnregistrationCompletion.rejected({
    required UnregisterPushFromNextcloudEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.rejected);

  @override
  UnregisterPushFromNextcloudEffect get effect =>
      super.effect as UnregisterPushFromNextcloudEffect;
}

final class PushGatewayUnregistrationCompletion extends PushEffectCompletion {
  const PushGatewayUnregistrationCompletion.success({
    required UnregisterPushFromGatewayEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.success);

  const PushGatewayUnregistrationCompletion.transientFailure({
    required UnregisterPushFromGatewayEffect effect,
  }) : super(
         effect: effect,
         classification: PushCompletionClass.transientFailure,
       );

  const PushGatewayUnregistrationCompletion.rejected({
    required UnregisterPushFromGatewayEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.rejected);

  @override
  UnregisterPushFromGatewayEffect get effect =>
      super.effect as UnregisterPushFromGatewayEffect;
}

final class PushDeviceKeyDestructionCompletion extends PushEffectCompletion {
  const PushDeviceKeyDestructionCompletion.success({
    required DestroyPushDeviceKeyEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.success);

  const PushDeviceKeyDestructionCompletion.transientFailure({
    required DestroyPushDeviceKeyEffect effect,
  }) : super(
         effect: effect,
         classification: PushCompletionClass.transientFailure,
       );

  const PushDeviceKeyDestructionCompletion.rejected({
    required DestroyPushDeviceKeyEffect effect,
  }) : super(effect: effect, classification: PushCompletionClass.rejected);

  @override
  DestroyPushDeviceKeyEffect get effect =>
      super.effect as DestroyPushDeviceKeyEffect;
}

Uri _nextcloudPushUri(PushEffectContext context) {
  final prefix = context.server.basePath;
  return context.server.uri.replace(
    path: '$prefix/ocs/v2.php/apps/notifications/api/v2/push',
    queryParameters: const <String, String>{'format': 'json'},
  );
}
