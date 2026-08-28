import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/core/app_version.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
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

RegisterPushWithNextcloudEffect _registerEffect(ServerBase server) {
  final context = PushEffectContext.forAuthority(
    effectId: PushEffectId.parse('effect-1'),
    authority: PushRegistrationAuthority(
      accountId: AccountId.parse('acc-1'),
      server: server,
      gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
      credentialGeneration: 1,
      capabilityGeneration: 1,
      cloudId: 'tester@${server.uri.host}',
      supportsPushV2: true,
    ),
    providerTokenGeneration: 1,
    keyGeneration: 1,
    registrationRevision: 0,
  );
  return RegisterPushWithNextcloudEffect(
    context: context,
    providerToken: PushProviderTokenBinding(
      handle: PushTokenHandle.parse('token-1'),
      sha512: 'a' * 128,
      generation: 1,
    ),
    key: PushDeviceKeyBinding(
      handle: PushKeyHandle.parse('key-1'),
      publicKey: PushRsaPublicKey.parse(_testPublicKeyPem),
      generation: 1,
    ),
  );
}

UnregisterPushFromNextcloudEffect _unregisterEffect(ServerBase server) {
  final context = PushEffectContext.forAuthority(
    effectId: PushEffectId.parse('effect-2'),
    authority: PushRegistrationAuthority(
      accountId: AccountId.parse('acc-1'),
      server: server,
      gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
      credentialGeneration: 1,
      capabilityGeneration: 1,
      cloudId: 'tester@${server.uri.host}',
      supportsPushV2: true,
    ),
    providerTokenGeneration: 1,
    keyGeneration: 1,
    registrationRevision: 1,
  );
  return UnregisterPushFromNextcloudEffect(context: context);
}

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');

  test('registers with the OCS push v2 route and decodes success', () async {
    late http.BaseRequest seen;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        seen = request;
        return http.Response(
          '{"ocs":{"meta":{"status":"ok","statuscode":200},"data":'
          '{"publicKey":${_jsonString(_testPublicKeyPem)},'
          '"deviceIdentifier":"$_testDeviceIdentifier",'
          '"signature":"$_testDeviceSignature"}}}',
          200,
        );
      }),
    );
    addTearDown(api.close);

    final completion = await api.registerPushWithNextcloud(
      effect: _registerEffect(server),
      loginName: 'tester',
      appPassword: 'secret',
    );

    expect(seen.method, 'POST');
    expect(seen.url.path, '/ocs/v2.php/apps/notifications/api/v2/push');
    expect(
      (seen as http.Request).bodyFields,
      containsPair('pushTokenHash', 'a' * 128),
    );
    expect(completion.classification, PushCompletionClass.success);
    expect(completion.registration, isNotNull);
  });

  test('a 401 asks for reauthentication instead of throwing', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response('', 401)),
    );
    addTearDown(api.close);

    final completion = await api.registerPushWithNextcloud(
      effect: _registerEffect(server),
      loginName: 'tester',
      appPassword: 'secret',
    );

    expect(
      completion.classification,
      PushCompletionClass.reauthenticationRequired,
    );
  });

  test('a 503 is transient, not a rejection', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response('', 503)),
    );
    addTearDown(api.close);

    final completion = await api.registerPushWithNextcloud(
      effect: _registerEffect(server),
      loginName: 'tester',
      appPassword: 'secret',
    );

    expect(completion.classification, PushCompletionClass.transientFailure);
  });

  test('unregisters with DELETE and accepts 202', () async {
    late http.BaseRequest seen;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        seen = request;
        return http.Response('', 202);
      }),
    );
    addTearDown(api.close);

    final completion = await api.unregisterPushFromNextcloud(
      effect: _unregisterEffect(server),
      loginName: 'tester',
      appPassword: 'secret',
    );

    expect(seen.method, 'DELETE');
    expect(seen.headers['User-Agent'], matches(_talkClientUserAgent));
    expect(completion.classification, PushCompletionClass.success);
  });

  test('the registration announces itself as a Talk client', () async {
    late http.BaseRequest seen;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        seen = request;
        return http.Response('', 503);
      }),
    );
    addTearDown(api.close);

    await api.registerPushWithNextcloud(
      effect: _registerEffect(server),
      loginName: 'tester',
      appPassword: 'secret',
    );

    // Nextcloud stores `apptype` purely from this header (PushController
    // against IRequest.USER_AGENT_TALK_*). Without a match the account is
    // registered as `unknown` and Push.filterProxyDeviceList drops it as soon
    // as the same account has an official Talk device.
    expect(seen.headers['User-Agent'], matches(_talkClientUserAgent));
    expect(pushRegistrationUserAgent, endsWith(' v$appVersionName'));
    expect(pushRegistrationUserAgent, isNot(contains(loginFlowUserAgent)));
  });
}

/// Mirrors `IRequest::USER_AGENT_TALK_ANDROID`, `_IOS` and `_DESKTOP`, so the
/// header keeps matching whichever platform the suite happens to run on.
final RegExp _talkClientUserAgent = RegExp(
  r'^Mozilla/5\.0 \((?:Android|iOS|Macintosh|Windows|Linux)\) '
  r'Nextcloud-Talk v[^ ]+$',
);

String _jsonString(String value) =>
    '"${value.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
