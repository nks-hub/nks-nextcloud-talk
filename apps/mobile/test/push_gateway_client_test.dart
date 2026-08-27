import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/features/push/push_gateway_client.dart';
import 'package:talk_protocol/talk_protocol.dart';

const _testPublicKeyPem = '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiPMzCLqz/W6ZnlHdur8C
CowBrN/LGyU1a81Fy0l1oC+uyQ6kd9gVh70slnd98D6BBP0+GU79Gi9OvPr8jR4v
7jomOzi8nnGoD3KFoo4RhdqsguYtrZDLpikogTQwn//Ei6/pd1jFUTtux4/3kND9
8rHmQTFt3aURqKHrf1DzMVytPY8jnyMhOpmH+xIo7ZBS4CTwRJQK6N5ebVgVhYST
xYkyksZCb51sddmFDkBZVR0R8miGlHupV62EeEGlPPTAQhqAFnKD4J/wkLKV5g8k
UkQBz7AyOy/2ikLYRQHDQH1wG+GU7TrhO5oD551IFaXIeTOJ1yzhwOL2Mw5ElqVE
WwIDAQAB
-----END PUBLIC KEY-----
''';

const _testDeviceIdentifier =
    'bXWepTro9S2ClxxrEDuD0z1MsOeYqQ6LLSJTG9I+AwcRhlKTAA/INyB0OVVG+bCyxkKOfBbbcsI/ohBLPPF9Kg==';
const _testDeviceSignature =
    'RvSvJf36i5Pu/hmnX+XoEUTojUH4FVL3sSVA+0Yxj2r2zyi7ldGJ3UciBD4MLk8Z+7lkfsAh5Jenhyol0hc8MigeZFpMbR1ER+jfJfqm4lsI7kszv2oDv5dbvxbqpDkH1pKiVSA4I+ewHqYaWUzacogF77B0czL2JVB2IucRciTJLcPXJR8rHZDLvrKZR1ApRipSDYGZIeMtE/irwiCRPC/T/XG7Jn+D+++0E6drwdHkYNHSr6EyzMtuaTOdS+vqpCQ/qF5wCo2lMmP5SvF1RK8Jvru+rAntKoQSZXlGeSM2tKP+zYpDSvdjsw3CUa0bdiotNwm0shDKg+lxKYRSLA==';

PushEffectContext _context() => PushEffectContext.forAuthority(
  effectId: PushEffectId.parse('effect-1'),
  authority: PushRegistrationAuthority(
    accountId: AccountId.parse('acc-1'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
    credentialGeneration: 1,
    capabilityGeneration: 1,
    cloudId: 'tester@cloud.example.invalid',
    supportsPushV2: true,
  ),
  providerTokenGeneration: 1,
  keyGeneration: 1,
  registrationRevision: 1,
);

PushServerRegistration _registration() => PushServerRegistration(
  deviceIdentifier: PushDeviceIdentifier.parse(_testDeviceIdentifier),
  deviceIdentifierSignature: PushDeviceSignature.parse(_testDeviceSignature),
  userPublicKey: PushRsaPublicKey.parse(_testPublicKeyPem),
);

void main() {
  test('registers with pushToken alongside the identity fields', () async {
    late http.BaseRequest seen;
    final client = PushGatewayClient(
      client: MockClient((request) async {
        seen = request;
        return http.Response('', 200);
      }),
    );
    addTearDown(client.close);

    final effect = RegisterPushWithGatewayEffect(
      context: _context(),
      providerToken: PushProviderTokenBinding(
        handle: PushTokenHandle.parse('token-1'),
        sha512: 'a' * 128,
        generation: 1,
      ),
      registration: _registration(),
      cloudId: null,
    );

    final completion = await client.register(effect, rawPushToken: 'deadbeef');

    expect(seen.method, 'POST');
    expect(seen.url.path, '/devices');
    final fields = (seen as http.Request).bodyFields;
    expect(fields['pushToken'], 'deadbeef');
    expect(fields['deviceIdentifier'], _testDeviceIdentifier);
    expect(fields['deviceIdentifierSignature'], _testDeviceSignature);
    expect(fields['userPublicKey'], _testPublicKeyPem);
    expect(completion.classification, PushCompletionClass.success);
  });

  test('a 409 is a conflict, not a rejection', () async {
    final client = PushGatewayClient(
      client: MockClient((request) async => http.Response('', 409)),
    );
    addTearDown(client.close);

    final effect = RegisterPushWithGatewayEffect(
      context: _context(),
      providerToken: PushProviderTokenBinding(
        handle: PushTokenHandle.parse('token-1'),
        sha512: 'a' * 128,
        generation: 1,
      ),
      registration: _registration(),
      cloudId: null,
    );

    final completion = await client.register(effect, rawPushToken: 'deadbeef');

    expect(completion.classification, PushCompletionClass.conflict);
  });

  test('unregisters with DELETE and the identity in the query string', () async {
    late http.BaseRequest seen;
    final client = PushGatewayClient(
      client: MockClient((request) async {
        seen = request;
        return http.Response('', 202);
      }),
    );
    addTearDown(client.close);

    final effect = UnregisterPushFromGatewayEffect(
      context: _context(),
      registration: _registration(),
    );

    final completion = await client.unregister(effect);

    expect(seen.method, 'DELETE');
    expect(
      seen.url.queryParameters['deviceIdentifier'],
      _testDeviceIdentifier,
    );
    expect(completion.classification, PushCompletionClass.success);
  });
}
