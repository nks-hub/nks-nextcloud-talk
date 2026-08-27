import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/push/apple_push_device_key_store.dart';
import 'package:nextcloudtalk/features/push/apple_push_registration_coordinator.dart';
import 'package:nextcloudtalk/features/push/push_gateway_client.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

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

/// In-memory stand-in for the Keychain: one RSA key per handle, generated
/// once and reused. No real RSA math — the fixed PEM above is valid enough
/// for [PushRsaPublicKey.parse] to accept, which is all the coordinator
/// checks.
final class _FakeDeviceKeyStore implements PushDeviceKeyStore {
  final Set<String> ensured = {};
  final Set<String> destroyed = {};
  bool failNext = false;

  @override
  Future<String> ensureKey(String handle) async {
    if (failNext) {
      failNext = false;
      throw StateError('key generation failed');
    }
    ensured.add(handle);
    return _testPublicKeyPem;
  }

  @override
  Future<void> destroyKey(String handle) async {
    destroyed.add(handle);
  }
}

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault credentials;
  late PushGatewayOrigin gateway;

  setUp(() {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    credentials = MemoryCredentialVault();
    gateway = PushGatewayOrigin.parse('https://push.example.invalid');
  });

  tearDown(() => database.close());

  Future<void> seedAccount(String accountId) async {
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'tester',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    credentials.values[accountId] = 'app-password';
  }

  http.Response capabilitiesResponse() => http.Response(
    _jsonEncode(capabilitiesJson(notificationPushFeatures: const ['devices'])),
    200,
  );

  http.Response nextcloudRegisterResponse() => http.Response(
    '{"ocs":{"meta":{"status":"ok","statuscode":200},"data":'
    '{"publicKey":${_jsonString(_testPublicKeyPem)},'
    '"deviceIdentifier":"$_testDeviceIdentifier",'
    '"signature":"$_testDeviceSignature"}}}',
    200,
  );

  test('follow drives key generation through gateway registration', () async {
    await seedAccount('account-a');
    final keyStore = _FakeDeviceKeyStore();
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.contains('/capabilities')) {
          return capabilitiesResponse();
        }
        if (request.url.path.endsWith('/push')) {
          return nextcloudRegisterResponse();
        }
        return http.Response('unexpected: ${request.url}', 404);
      }),
    );
    addTearDown(api.close);
    final gatewayRequests = <http.BaseRequest>[];
    final coordinator = ApplePushRegistrationCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: api,
      keyStore: keyStore,
      gateway: gateway,
      pushEnvironment: 'production',
      gatewayClient: PushGatewayClient(
        client: MockClient((request) async {
          gatewayRequests.add(request);
          return http.Response('', 200);
        }),
      ),
    );
    addTearDown(coordinator.dispose);

    coordinator.installToken('deadbeef');
    await coordinator.follow('account-a');

    expect(keyStore.ensured, isNotEmpty);
    expect(gatewayRequests, hasLength(1));
    expect(gatewayRequests.single.method, 'POST');
    final fields = (gatewayRequests.single as http.Request).bodyFields;
    expect(fields['pushToken'], 'deadbeef');
    expect(fields['pushEnvironment'], 'production');
  });

  test('a server without push v2 registers nothing', () async {
    await seedAccount('account-a');
    final keyStore = _FakeDeviceKeyStore();
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.contains('/capabilities')) {
          return http.Response(_jsonEncode(capabilitiesJson()), 200);
        }
        return http.Response('unexpected: ${request.url}', 404);
      }),
    );
    addTearDown(api.close);
    final coordinator = ApplePushRegistrationCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: api,
      keyStore: keyStore,
      gateway: gateway,
    );
    addTearDown(coordinator.dispose);

    coordinator.installToken('deadbeef');
    await coordinator.follow('account-a');

    expect(keyStore.ensured, isEmpty);
  });

  test('unfollow destroys the device key and unregisters', () async {
    await seedAccount('account-a');
    final keyStore = _FakeDeviceKeyStore();
    final requestedMethods = <String>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requestedMethods.add('${request.method} ${request.url.path}');
        if (request.url.path.contains('/capabilities')) {
          return capabilitiesResponse();
        }
        if (request.url.path.endsWith('/push')) {
          if (request.method == 'DELETE') {
            return http.Response('', 200);
          }
          return nextcloudRegisterResponse();
        }
        return http.Response('unexpected: ${request.url}', 404);
      }),
    );
    addTearDown(api.close);
    final coordinator = ApplePushRegistrationCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: api,
      keyStore: keyStore,
      gateway: gateway,
      gatewayClient: PushGatewayClient(
        client: MockClient((request) async {
          if (request.method == 'DELETE') {
            return http.Response('', 202);
          }
          return http.Response('', 200);
        }),
      ),
    );
    addTearDown(coordinator.dispose);

    coordinator.installToken('deadbeef');
    await coordinator.follow('account-a');
    expect(keyStore.destroyed, isEmpty);

    await coordinator.unfollow('account-a');

    expect(keyStore.destroyed, isNotEmpty);
    expect(
      requestedMethods,
      contains('DELETE /ocs/v2.php/apps/notifications/api/v2/push'),
    );
  });

  test('a transient key failure is retried instead of abandoned', () async {
    await seedAccount('account-a');
    final keyStore = _FakeDeviceKeyStore()..failNext = true;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.contains('/capabilities')) {
          return capabilitiesResponse();
        }
        if (request.url.path.endsWith('/push')) {
          return nextcloudRegisterResponse();
        }
        return http.Response('unexpected: ${request.url}', 404);
      }),
    );
    addTearDown(api.close);
    var retried = false;
    final coordinator = ApplePushRegistrationCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: api,
      keyStore: keyStore,
      gateway: gateway,
      gatewayClient: PushGatewayClient(
        client: MockClient((request) async => http.Response('', 200)),
      ),
      firstRetry: const Duration(milliseconds: 1),
      maximumRetry: const Duration(milliseconds: 5),
      delay: (duration) async {
        retried = true;
      },
    );
    addTearDown(coordinator.dispose);

    coordinator.installToken('deadbeef');
    await coordinator.follow('account-a');
    // The retry timer's own drain runs asynchronously after `_delay`
    // resolves; give the event loop a turn to let it finish.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(retried, isTrue);
    expect(keyStore.ensured, isNotEmpty);
  });

  test(
    'dispose waits for an in-flight drain before closing the gateway client',
    () async {
      await seedAccount('account-a');
      final keyStore = _FakeDeviceKeyStore();
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.contains('/capabilities')) {
            return capabilitiesResponse();
          }
          if (request.url.path.endsWith('/push')) {
            if (request.method == 'DELETE') {
              return http.Response('', 200);
            }
            return nextcloudRegisterResponse();
          }
          return http.Response('unexpected: ${request.url}', 404);
        }),
      );
      addTearDown(api.close);

      final gatewayGate = Completer<void>();
      var gatewayRequestSeen = false;
      final coordinator = ApplePushRegistrationCoordinator(
        accounts: accounts,
        credentials: credentials,
        api: api,
        keyStore: keyStore,
        gateway: gateway,
        gatewayClient: PushGatewayClient(
          client: MockClient((request) async {
            if (request.method == 'DELETE') {
              gatewayRequestSeen = true;
              await gatewayGate.future;
            }
            return http.Response('', 200);
          }),
        ),
      );

      coordinator.installToken('deadbeef');
      await coordinator.follow('account-a');

      final unfollowFuture = coordinator.unfollow('account-a');
      // Let the unregister effect reach the now-blocked gateway DELETE call.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(gatewayRequestSeen, isTrue);

      var disposeCompleted = false;
      final disposeFuture = coordinator.dispose().then(
        (_) => disposeCompleted = true,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        disposeCompleted,
        isFalse,
        reason: 'dispose must wait for the in-flight drain',
      );

      gatewayGate.complete();
      await unfollowFuture;
      await disposeFuture;
      expect(disposeCompleted, isTrue);
    },
  );
}

String _jsonEncode(Map<String, Object?> value) {
  final buffer = StringBuffer();
  void write(Object? node) {
    switch (node) {
      case Map<String, Object?> map:
        buffer.write('{');
        var first = true;
        for (final entry in map.entries) {
          if (!first) buffer.write(',');
          first = false;
          buffer.write(_jsonString(entry.key));
          buffer.write(':');
          write(entry.value);
        }
        buffer.write('}');
      case List<Object?> list:
        buffer.write('[');
        var first = true;
        for (final item in list) {
          if (!first) buffer.write(',');
          first = false;
          write(item);
        }
        buffer.write(']');
      case String s:
        buffer.write(_jsonString(s));
      case bool b:
        buffer.write(b);
      case num n:
        buffer.write(n);
      case null:
        buffer.write('null');
      default:
        throw ArgumentError('Unsupported JSON node: $node');
    }
  }

  write(value);
  return buffer.toString();
}

String _jsonString(String value) =>
    '"${value.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
