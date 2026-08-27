import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/push/apple_push_device_key_store.dart';
import 'package:nextcloudtalk/features/push/push_gateway_client.dart';
import 'package:nextcloudtalk/features/push/push_registration_coordinator.dart';
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

/// A representative FCM registration token: colon-separated, mixed case,
/// far longer than an APNs one and not hex. The transport must not care.
const _fcmToken =
    'dGVzdDpBUEE5MWJH:APA91bHqR7xk3Lm0-9QpZv2NcU8sYt1AeR4Wd6Fj_gK5'
    'MnB3xC7vTzYh2QoLpEs0JiRfNgUaXbVmDcT9WkYzHrPq4SsLuEoAiNvBxCmZgTdRkFeJyHwUq';

/// Real RSA-2048 public keys, one per account. They have to differ: the push
/// state machine rejects a device key that another account already holds, so
/// one account can never end up able to read another's notifications.
const _devicePublicKeyPems = <String>[
  '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqju/JpL0snkhRgNTEEiR
wb+zbt7dzf8cnF8AGNYFUD99+Lw0o7ELSzz2XADs8pecge1aORXwotsV4NxI7Zb5
aspYMoNvYYh8wUv1COjD4I4ati0J+g5x4ahrUhAGDv+3pej2BBpDW+EpSU3/BFpo
7Isxo5k5d2/Dw48rejJ9baAkF1dAjLNY9IFvQWla4Uq0yXvP0GrzM00B47EauK8Z
mLDiuM+x3XUWq1XI5p82RcSEiabZsUYoStln71s+rLIcgp/Rtq/NbXB/hNe/JhQ2
hyl7147JWxpId2iZm5D04+kODBvaRlGZZpAIAP1OuMI2UlCTCIEgOhmmpuE3nHVa
uwIDAQAB
-----END PUBLIC KEY-----
''',
  '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApvIn40Ro7vUXYWWBLqRM
/Vfy+OvV+WHaN1PiLgt9Ji3frNBh5NEoNk9fuOrwxk91GN3P5h0C7k9jYa7sXc5c
QRskxcHidbc8bG0nhsag5BOgZS4to5stBvcOgpcRgne6TkHGu2X55en8fl/8XOyD
haz6l0kEY4c/8H6Doje7jrYV7FAMaUsdKgCNg44X+R08oT/HU50eKlOEZ0ig6uXb
lbMt7kAU6Fm8vCzElVDSnKmJDNPsYdQrRYrmePPJcE2X0Ak2xXKkBLm6+T9poeC7
7KYM9IFQRR0zznGGfI6MYK+rTxQttVvhcF52Ehqdpznv8nvgYfHWNZ7NRgPhxZB0
AwIDAQAB
-----END PUBLIC KEY-----
''',
  '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyjYJylChBz/0lFB2iP5K
lwdH4XQPfAiT5BQUc6gaueuDwwblEX1g/jKrSzV0ulQATl8dkbhfoRBlM3U1ZA5U
KUXgTG/G90Rwr8qBjXjb3VboZ8VAObpFA2mCc7L5hBp7USrSB5gIySRMlhTn6pGF
KcxPXw+MNd+atL7AfgeDZBBcFyZaXfTXlvoog4SqdVykWuzE84A6hZdR8UUhooZd
eD0PociQRGX9yjAogoAcd2wxv4fyX2doVcqGYb2aigvjHdupu3o3iWAuMmnTKsgL
b3ZQBBIGBcrWcauVO2KLmzZuzVkBviA3b3cc4bb8psp9+yOaZ+Ym9Dgh9bfO0ffq
EQIDAQAB
-----END PUBLIC KEY-----
''',
];

final class _FakeDeviceKeyStore implements PushDeviceKeyStore {
  final List<String> ensured = [];
  final List<String> destroyed = [];
  final Map<String, String> _keys = {};
  String? fixedKey;

  @override
  Future<String> ensureKey(String handle) async {
    ensured.add(handle);
    return _keys.putIfAbsent(
      handle,
      () => fixedKey ?? _devicePublicKeyPems[_keys.length],
    );
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
    gateway = PushGatewayOrigin.parse('https://nks-talk-notify.example.invalid');
  });

  tearDown(() => database.close());

  Future<void> seedAccount(String accountId) async {
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'tester-$accountId',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    credentials.values[accountId] = 'app-password';
  }

  http.Response nextcloudRegisterResponse() => http.Response(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{'status': 'ok', 'statuscode': 200},
        'data': <String, Object?>{
          'publicKey': _testPublicKeyPem,
          'deviceIdentifier': _testDeviceIdentifier,
          'signature': _testDeviceSignature,
        },
      },
    }),
    200,
  );

  ({
    HttpNextcloudApi api,
    List<http.Request> nextcloudRequests,
    List<http.Request> gatewayRequests,
    PushGatewayClient gatewayClient,
  })
  wire() {
    final nextcloudRequests = <http.Request>[];
    final gatewayRequests = <http.Request>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        nextcloudRequests.add(request);
        if (request.url.path.contains('/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                notificationPushFeatures: const <String>['devices'],
              ),
            ),
            200,
          );
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
    final gatewayClient = PushGatewayClient(
      client: MockClient((request) async {
        gatewayRequests.add(request);
        return http.Response('', request.method == 'DELETE' ? 202 : 200);
      }),
    );
    return (
      api: api,
      nextcloudRequests: nextcloudRequests,
      gatewayRequests: gatewayRequests,
      gatewayClient: gatewayClient,
    );
  }

  PushRegistrationCoordinator build(
    ({
      HttpNextcloudApi api,
      List<http.Request> nextcloudRequests,
      List<http.Request> gatewayRequests,
      PushGatewayClient gatewayClient,
    })
    wired,
    PushDeviceKeyStore keyStore,
  ) {
    addTearDown(wired.api.close);
    final coordinator = PushRegistrationCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: wired.api,
      keyStore: keyStore,
      gateway: gateway,
      tokenHandlePrefix: 'fcm-token',
      gatewayClient: wired.gatewayClient,
    );
    addTearDown(coordinator.dispose);
    return coordinator;
  }

  test('an FCM token registers with Nextcloud and with the proxy', () async {
    await seedAccount('account-a');
    final keyStore = _FakeDeviceKeyStore();
    final wired = wire();
    final coordinator = build(wired, keyStore);

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');

    expect(keyStore.ensured, hasLength(1));
    expect(wired.gatewayRequests, hasLength(1));
    expect(wired.gatewayRequests.single.method, 'POST');
    expect(wired.gatewayRequests.single.bodyFields['pushToken'], _fcmToken);
  });

  test('pushTokenHash is the lowercase SHA-512 hex Nextcloud demands', () async {
    await seedAccount('account-a');
    final wired = wire();
    final coordinator = build(wired, _FakeDeviceKeyStore());

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');

    final registration = wired.nextcloudRequests.singleWhere(
      (request) => request.method == 'POST' && request.url.path.endsWith('/push'),
    );
    final hash = registration.bodyFields['pushTokenHash'];
    // PushController::registerDevice rejects anything else outright.
    expect(hash, matches(RegExp(r'^[a-f0-9]{128}$')));
    expect(
      hash,
      crypto.sha512.convert(utf8.encode(_fcmToken)).toString(),
    );
  });

  test('proxyServer is sent verbatim, with no trailing slash', () async {
    await seedAccount('account-a');
    final wired = wire();
    final coordinator = build(wired, _FakeDeviceKeyStore());

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');

    final registration = wired.nextcloudRequests.singleWhere(
      (request) => request.method == 'POST' && request.url.path.endsWith('/push'),
    );
    expect(
      registration.bodyFields['proxyServer'],
      'https://nks-talk-notify.example.invalid',
    );
  });

  test('without a provider token nothing at all is planned', () async {
    await seedAccount('account-a');
    final keyStore = _FakeDeviceKeyStore();
    final wired = wire();
    final coordinator = build(wired, keyStore);

    await coordinator.follow('account-a');

    // Not even the device key: `planNextPushEffect` returns empty-handed
    // while `snapshot.providerToken` is null. This is why the proxy transport
    // is inert until FCM hands a token over.
    expect(keyStore.ensured, isEmpty);
    expect(
      wired.nextcloudRequests.where((request) => request.method == 'POST'),
      isEmpty,
    );
    expect(wired.gatewayRequests, isEmpty);
  });

  test('unfollowAll clears every account it registered', () async {
    await seedAccount('account-a');
    await seedAccount('account-b');
    final keyStore = _FakeDeviceKeyStore();
    final wired = wire();
    final coordinator = build(wired, keyStore);

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');
    await coordinator.follow('account-b');
    expect(keyStore.destroyed, isEmpty);

    await coordinator.unfollowAll();

    expect(keyStore.destroyed.toSet(), keyStore.ensured.toSet());
    expect(
      wired.nextcloudRequests
          .where((request) => request.method == 'DELETE')
          .length,
      2,
    );
    expect(
      wired.gatewayRequests.where((request) => request.method == 'DELETE').length,
      2,
    );
    expect(coordinator.isSettled, isTrue);
  });

  test('each account gets its own device key', () async {
    await seedAccount('account-a');
    await seedAccount('account-b');
    final keyStore = _FakeDeviceKeyStore();
    final wired = wire();
    final coordinator = build(wired, keyStore);

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');
    await coordinator.follow('account-b');

    expect(keyStore.ensured, hasLength(2));
    expect(keyStore.ensured.toSet(), hasLength(2));
  });

  test('re-following an unchanged account costs no server request', () async {
    await seedAccount('account-a');
    final wired = wire();
    final coordinator = build(wired, _FakeDeviceKeyStore());

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');
    // The account row is rewritten after every sync, so the list stream
    // re-emits and the provider follows again. That must stay free.
    await coordinator.follow('account-a');
    await coordinator.follow('account-a');

    expect(
      wired.nextcloudRequests.where(
        (request) => request.url.path.contains('/capabilities'),
      ),
      hasLength(1),
    );
  });

  test('a changed login re-reads capabilities', () async {
    await seedAccount('account-a');
    final wired = wire();
    final coordinator = build(wired, _FakeDeviceKeyStore());

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'someone-else',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    await coordinator.follow('account-a');

    expect(
      wired.nextcloudRequests.where(
        (request) => request.url.path.contains('/capabilities'),
      ),
      hasLength(2),
    );
  });

  test('unregistering keeps the device identity out of the URL', () async {
    await seedAccount('account-a');
    final wired = wire();
    final coordinator = build(wired, _FakeDeviceKeyStore());

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');
    await coordinator.unfollow('account-a');

    final delete = wired.gatewayRequests.singleWhere(
      (request) => request.method == 'DELETE',
    );
    // Every proxy on the way logs the request line. The identifier and its
    // signature are what a device proves itself with, so they go in the body.
    expect(delete.url.query, isEmpty);
    expect(delete.url.toString(), isNot(contains('deviceIdentifier')));
    expect(delete.bodyFields['deviceIdentifier'], _testDeviceIdentifier);
    expect(
      delete.bodyFields['deviceIdentifierSignature'],
      _testDeviceSignature,
    );
    expect(delete.bodyFields['userPublicKey'], isNotEmpty);
  });

  test('a device key shared with another account is refused', () async {
    await seedAccount('account-a');
    await seedAccount('account-b');
    final keyStore = _FakeDeviceKeyStore()
      ..fixedKey = _devicePublicKeyPems.first;
    final wired = wire();
    final coordinator = build(wired, keyStore);

    coordinator.installToken(_fcmToken);
    await coordinator.follow('account-a');
    await coordinator.follow('account-b');

    // The second account offered the first account's key. Registering it
    // would let one account decrypt the other's notifications, so the state
    // machine refuses and only the first account is registered.
    expect(
      wired.nextcloudRequests.where(
        (request) =>
            request.method == 'POST' && request.url.path.endsWith('/push'),
      ),
      hasLength(1),
    );
    expect(wired.gatewayRequests, hasLength(1));
  });
}
