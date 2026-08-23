import 'package:talk_protocol/talk_protocol.dart';

final pushAccountA = AccountId.parse('push-account-a');
final pushAccountB = AccountId.parse('push-account-b');

const pushPublicKeyA = '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiPMzCLqz/W6ZnlHdur8C
CowBrN/LGyU1a81Fy0l1oC+uyQ6kd9gVh70slnd98D6BBP0+GU79Gi9OvPr8jR4v
7jomOzi8nnGoD3KFoo4RhdqsguYtrZDLpikogTQwn//Ei6/pd1jFUTtux4/3kND9
8rHmQTFt3aURqKHrf1DzMVytPY8jnyMhOpmH+xIo7ZBS4CTwRJQK6N5ebVgVhYST
xYkyksZCb51sddmFDkBZVR0R8miGlHupV62EeEGlPPTAQhqAFnKD4J/wkLKV5g8k
UkQBz7AyOy/2ikLYRQHDQH1wG+GU7TrhO5oD551IFaXIeTOJ1yzhwOL2Mw5ElqVE
WwIDAQAB
-----END PUBLIC KEY-----
''';

const pushPublicKeyB = '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1eXvwcJxNNRUh138YjvN
NB87i9Qp/w9UJJdJbTurUekt2L8EU8EpXUUaVrPpicOF7VkN2mQ6LQrThMLfxLyz
uNkxpziUvXTXxb0FgH6mKmI8Zo8Gz22kFb+Pyc96uDl/sEWoIUuB7UPlQgPfIP0w
0+YPHIK4uUM7S3O4xaYxHg0qjr8eLm0yfKBpWUh9mp7Ybqx6aBbdUor+EAgTnTj/
b+Ft8iJqHxEpCouCJG412v4vezgCBq06p3jrdwve78oIwdXpT6XCw6Yyoea59K/S
liGrTJcu0ICe2elYC1PeYaHb5kMnbQJ1MWY6wuEP/djIvDHFS2HP61Tq10dilO0F
bwIDAQAB
-----END PUBLIC KEY-----
''';

const pushDeviceIdentifier =
    'bXWepTro9S2ClxxrEDuD0z1MsOeYqQ6LLSJTG9I+AwcRhlKTAA/INyB0OVVG+bCyxkKOfBbbcsI/ohBLPPF9Kg==';
const pushDeviceSignature =
    'RvSvJf36i5Pu/hmnX+XoEUTojUH4FVL3sSVA+0Yxj2r2zyi7ldGJ3UciBD4MLk8Z+7lkfsAh5Jenhyol0hc8MigeZFpMbR1ER+jfJfqm4lsI7kszv2oDv5dbvxbqpDkH1pKiVSA4I+ewHqYaWUzacogF77B0czL2JVB2IucRciTJLcPXJR8rHZDLvrKZR1ApRipSDYGZIeMtE/irwiCRPC/T/XG7Jn+D+++0E6drwdHkYNHSr6EyzMtuaTOdS+vqpCQ/qF5wCo2lMmP5SvF1RK8Jvru+rAntKoQSZXlGeSM2tKP+zYpDSvdjsw3CUa0bdiotNwm0shDKg+lxKYRSLA==';

PushRegistrationAuthority pushAuthority(
  AccountId accountId, {
  String server = 'https://cloud-a.example.invalid',
  String cloudId = 'demo@cloud-a.example.invalid',
  int credentialGeneration = 1,
  int capabilityGeneration = 1,
  bool supportsPushV2 = true,
}) => PushRegistrationAuthority(
  accountId: accountId,
  server: ServerBase.parse(server),
  gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
  credentialGeneration: credentialGeneration,
  capabilityGeneration: capabilityGeneration,
  cloudId: cloudId,
  supportsPushV2: supportsPushV2,
);

PushProviderTokenBinding pushProviderToken({int generation = 1}) =>
    PushProviderTokenBinding(
      handle: PushTokenHandle.parse('provider-token-$generation'),
      sha512: generation.toRadixString(16).padLeft(128, '0'),
      generation: generation,
    );

PushDeviceKeyBinding pushDeviceKey(
  AccountId accountId, {
  int generation = 1,
  String? publicKey,
}) => PushDeviceKeyBinding(
  handle: PushKeyHandle.parse('key-${accountId.value}-$generation'),
  publicKey: PushRsaPublicKey.parse(
    publicKey ?? (accountId == pushAccountA ? pushPublicKeyA : pushPublicKeyB),
  ),
  generation: generation,
);

PushServerRegistration pushServerRegistration({
  String userPublicKey = pushPublicKeyA,
}) => PushServerRegistration(
  deviceIdentifier: PushDeviceIdentifier.parse(pushDeviceIdentifier),
  deviceIdentifierSignature: PushDeviceSignature.parse(pushDeviceSignature),
  userPublicKey: PushRsaPublicKey.parse(userPublicKey),
);

PushEffectId pushEffectId(int value) =>
    PushEffectId.parse('push-effect-$value');

PushRuntimeSnapshot addPushAccountAndToken(
  PushRuntimeSnapshot snapshot,
  PushRegistrationAuthority authority, {
  PushProviderTokenBinding? token,
}) {
  snapshot = commitPushRuntime(snapshot, addPushAccount(snapshot, authority));
  final binding = token ?? pushProviderToken();
  if (snapshot.providerToken == null) {
    snapshot = commitPushRuntime(
      snapshot,
      installPushProviderToken(snapshot, binding),
    );
  }
  return snapshot;
}

RegisterPushWithNextcloudEffect pushNextcloudRegistrationEffect({
  required PushRegistrationAuthority authority,
  required PushProviderTokenBinding providerToken,
  required PushDeviceKeyBinding key,
  required PushEffectId effectId,
}) {
  var snapshot = addPushAccountAndToken(
    PushRuntimeSnapshot.empty(),
    authority,
    token: providerToken,
  );
  var planned = planNextPushEffect(snapshot, effectId: pushEffectId(900));
  snapshot = commitPushRuntime(snapshot, planned);
  snapshot = commitPushRuntime(
    snapshot,
    completePushEffect(
      snapshot,
      PushDeviceKeyCompletion.success(
        effect: planned.effect! as EnsurePushDeviceKeyEffect,
        key: key,
      ),
    ),
  );
  planned = planNextPushEffect(snapshot, effectId: effectId);
  return planned.effect! as RegisterPushWithNextcloudEffect;
}

PushRuntimeSnapshot completePushAccountRegistration(
  PushRuntimeSnapshot snapshot,
  PushRegistrationAuthority authority, {
  required PushDeviceKeyBinding key,
  PushServerRegistration? registration,
  int effectSeed = 1,
}) {
  var planned = planNextPushEffect(
    snapshot,
    effectId: pushEffectId(effectSeed),
  );
  snapshot = commitPushRuntime(snapshot, planned);
  final keyEffect = planned.effect! as EnsurePushDeviceKeyEffect;
  snapshot = commitPushRuntime(
    snapshot,
    completePushEffect(
      snapshot,
      PushDeviceKeyCompletion.success(effect: keyEffect, key: key),
    ),
  );

  planned = planNextPushEffect(
    snapshot,
    effectId: pushEffectId(effectSeed + 1),
  );
  snapshot = commitPushRuntime(snapshot, planned);
  final serverEffect = planned.effect! as RegisterPushWithNextcloudEffect;
  snapshot = commitPushRuntime(
    snapshot,
    completePushEffect(
      snapshot,
      PushNextcloudRegistrationCompletion.success(
        effect: serverEffect,
        registration: registration ?? pushServerRegistration(),
      ),
    ),
  );

  planned = planNextPushEffect(
    snapshot,
    effectId: pushEffectId(effectSeed + 2),
  );
  snapshot = commitPushRuntime(snapshot, planned);
  final gatewayEffect = planned.effect! as RegisterPushWithGatewayEffect;
  return commitPushRuntime(
    snapshot,
    completePushEffect(
      snapshot,
      PushGatewayRegistrationCompletion.success(effect: gatewayEffect),
    ),
  );
}
