import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/conversation_avatar_repository.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount accountA;
  var now = DateTime.utc(2026, 8, 23, 12);

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault();
    accountA = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-a',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    vault.values['account-a'] = 'fixture-password-a';
  });

  tearDown(() => database.close());

  test('only a loaded versioned avatar outlives its last listener', () async {
    var fail = false;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        if (fail) {
          return http.Response('', 500);
        }
        return _imageResponse(
          body: [1, 2, 3],
          headers: const {'x-nc-iscustomavatar': '1'},
        );
      }),
    );
    addTearDown(api.close);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);
    const room = 'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v1';

    Future<bool> keptAfterUse(String path, {required bool versioned}) async {
      final provider = conversationAvatarProvider(
        ConversationAvatarProviderKey(
          account: accountA,
          uri: Uri.parse('$room/$path'),
          versioned: versioned,
        ),
      );
      final subscription = container.listen(provider, (_, _) {});
      try {
        await container.read(provider.future);
      } on Object {
        // The failing case is asked about below like the others.
      }
      subscription.close();
      await pumpEventQueue();
      return container.exists(provider);
    }

    expect(
      await keptAfterUse('room/room-a/avatar?avatarVersion=5', versioned: true),
      isTrue,
    );
    expect(await keptAfterUse('room/room-b/avatar', versioned: false), isFalse);
    fail = true;
    expect(
      await keptAfterUse('room/room-c/avatar?avatarVersion=1', versioned: true),
      isFalse,
    );
  });

  test(
    'a versioned avatar is fetched once and then treated as immutable',
    () async {
      var requests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((_) async {
          requests++;
          return _imageResponse(
            body: [1, 2, 3],
            headers: const {'x-nc-iscustomavatar': '0'},
          );
        }),
      );
      addTearDown(api.close);
      final repository = ConversationAvatarRepository(
        database: database,
        credentials: vault,
        api: api,
        clock: () => now,
      );
      final uri = Uri.parse(
        'https://cloud.example.invalid/'
        'ocs/v2.php/apps/spreed/api/v1/room/room-a/avatar?avatarVersion=5',
      );

      final first = await repository.load(
        account: accountA,
        uri: uri,
        versioned: true,
      );
      now = now.add(const Duration(days: 365));
      final second = await repository.load(
        account: accountA,
        uri: uri,
        versioned: true,
      );

      expect(requests, 1);
      expect(first?.body, [1, 2, 3]);
      expect(first?.isCustomAvatar, isFalse);
      expect(second?.body, [1, 2, 3]);
      expect(second?.isCustomAvatar, isFalse);
    },
  );

  test('concurrent loads share one network request', () async {
    var requests = 0;
    final release = Completer<void>();
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        requests++;
        await release.future;
        return _imageResponse(body: [10, 11, 12]);
      }),
    );
    addTearDown(api.close);
    final repository = ConversationAvatarRepository(
      database: database,
      credentials: vault,
      api: api,
      clock: () => now,
    );
    final uri = Uri.parse(
      'https://cloud.example.invalid/'
      'ocs/v2.php/apps/spreed/api/v1/room/room-a/avatar?avatarVersion=9',
    );

    final first = repository.load(account: accountA, uri: uri, versioned: true);
    final second = repository.load(
      account: accountA,
      uri: uri,
      versioned: true,
    );
    await pumpEventQueue();

    expect(requests, 1);
    release.complete();
    final results = await Future.wait([first, second]);
    expect(results[0]?.body, [10, 11, 12]);
    expect(results[1]?.body, [10, 11, 12]);
    expect(
      await database.select(database.conversationAvatars).get(),
      hasLength(1),
    );
  });

  test('a failed shared load does not block a retry', () async {
    var requests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        requests++;
        if (requests == 1) {
          return http.Response('', 500);
        }
        return _imageResponse(body: [13, 14, 15]);
      }),
    );
    addTearDown(api.close);
    final repository = ConversationAvatarRepository(
      database: database,
      credentials: vault,
      api: api,
      clock: () => now,
    );
    final uri = Uri.parse(
      'https://cloud.example.invalid/'
      'ocs/v2.php/apps/spreed/api/v1/room/room-a/avatar?avatarVersion=10',
    );

    final first = repository.load(account: accountA, uri: uri, versioned: true);
    final second = repository.load(
      account: accountA,
      uri: uri,
      versioned: true,
    );
    await expectLater(
      Future.wait([first, second]),
      throwsA(isA<NextcloudApiException>()),
    );
    expect(requests, 1);
    final retried = await repository.load(
      account: accountA,
      uri: uri,
      versioned: true,
    );

    expect(requests, 2);
    expect(retried?.body, [13, 14, 15]);
  });

  test('an expired unversioned avatar is conditionally revalidated', () async {
    final requests = <http.Request>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          return _imageResponse(
            body: [4, 5, 6],
            headers: const {
              'etag': '"avatar-a"',
              'cache-control': 'private, max-age=60',
            },
          );
        }
        return http.Response(
          '',
          304,
          headers: const {'cache-control': 'max-age=120'},
        );
      }),
    );
    addTearDown(api.close);
    final repository = ConversationAvatarRepository(
      database: database,
      credentials: vault,
      api: api,
      clock: () => now,
    );
    final uri = Uri.parse(
      'https://cloud.example.invalid/index.php/avatar/fixture-a/64',
    );

    await repository.load(account: accountA, uri: uri, versioned: false);
    now = now.add(const Duration(seconds: 61));
    final refreshed = await repository.load(
      account: accountA,
      uri: uri,
      versioned: false,
    );

    expect(requests, hasLength(2));
    expect(requests.last.headers['If-None-Match'], '"avatar-a"');
    expect(refreshed?.body, [4, 5, 6]);
    final cached = await database
        .select(database.conversationAvatars)
        .getSingle();
    expect(
      cached.expiresAtMillis,
      now.add(const Duration(seconds: 120)).millisecondsSinceEpoch,
    );
  });

  test('the same URL remains isolated between accounts', () async {
    final accountB = await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-b',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 2),
    );
    vault.values['account-b'] = 'fixture-password-b';
    var requests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        requests++;
        return _imageResponse(body: [requests]);
      }),
    );
    addTearDown(api.close);
    final repository = ConversationAvatarRepository(
      database: database,
      credentials: vault,
      api: api,
      clock: () => now,
    );
    final uri = Uri.parse(
      'https://cloud.example.invalid/'
      'ocs/v2.php/apps/spreed/api/v1/room/shared/avatar?avatarVersion=1',
    );

    final avatarA = await repository.load(
      account: accountA,
      uri: uri,
      versioned: true,
    );
    final avatarB = await repository.load(
      account: accountB,
      uri: uri,
      versioned: true,
    );

    expect(requests, 2);
    expect(avatarA?.body, [1]);
    expect(avatarB?.body, [2]);
    expect(
      await database.select(database.conversationAvatars).get(),
      hasLength(2),
    );
  });

  test('stale cached bytes remain available while offline', () async {
    var online = true;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        if (!online) {
          throw http.ClientException('synthetic offline');
        }
        return _imageResponse(
          body: [7, 8, 9],
          headers: const {'cache-control': 'max-age=0'},
        );
      }),
    );
    addTearDown(api.close);
    final repository = ConversationAvatarRepository(
      database: database,
      credentials: vault,
      api: api,
      clock: () => now,
    );
    final uri = Uri.parse(
      'https://cloud.example.invalid/index.php/avatar/fixture-a/64',
    );

    await repository.load(account: accountA, uri: uri, versioned: false);
    online = false;
    final stale = await repository.load(
      account: accountA,
      uri: uri,
      versioned: false,
    );

    expect(stale?.body, [7, 8, 9]);
  });
}

http.Response _imageResponse({
  required List<int> body,
  Map<String, String> headers = const {},
}) {
  return http.Response.bytes(
    body,
    200,
    headers: {'content-type': 'image/png', ...headers},
  );
}
