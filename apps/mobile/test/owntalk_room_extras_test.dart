import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const _key = (accountId: 'account-a', roomToken: ownTalkTestToken);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory directory;
  late StreamController<void> resumes;
  late FakeOwnTalkServer server;
  late OwnTalkSettingsStore store;
  late ProviderContainer container;

  ProviderContainer open({
    Duration interval = const Duration(milliseconds: 80),
    Duration capabilityTtl = const Duration(minutes: 5),
  }) => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(
        MemoryCredentialVault()..values['account-a'] = 'fixture-password',
      ),
      nextcloudApiProvider.overrideWithValue(
        HttpNextcloudApi(
          client: server.client,
          capabilityCacheTtl: capabilityTtl,
        ),
      ),
      ownTalkSettingsStoreProvider.overrideWith((ref) => store),
      ownTalkSettingsPollIntervalProvider.overrideWithValue(interval),
      appLifecycleResumeEventsProvider.overrideWithValue(resumes.stream),
    ],
  );

  OwnTalkRoomController controller() =>
      container.read(ownTalkRoomExtrasProvider(_key).notifier);

  OwnTalkRoomExtras shown() => container.read(ownTalkRoomExtrasProvider(_key));

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not reached');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void watch() => container.listen(
    ownTalkRoomExtrasProvider(_key),
    (_, _) {},
    fireImmediately: true,
  );

  OwnTalkRoomSettings documentWith(Map<String, String?> changes) =>
      OwnTalkRoomSettings.fromJson(
        (FakeOwnTalkServer()..setExternally(changes)).document(),
      );

  setUp(() async {
    database = openTestDatabase();
    await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    directory = await Directory.systemTemp.createTemp('owntalk-store-');
    store = OwnTalkSettingsStore.forTesting(directory);
    resumes = StreamController<void>.broadcast(sync: true);
    server = FakeOwnTalkServer();
    container = open();
  });

  tearDown(() async {
    container.dispose();
    await resumes.close();
    await database.close();
    // A poll that was in flight when the container went away may still be
    // writing its cache file.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('fetches, caches and revalidates with If-None-Match', () async {
    server.setExternally({'chat.backgroundColor': '#1E3A5F'});
    watch();
    await until(() => shown().settings != null);

    expect(shown().available, isTrue);
    expect(shown().valueOf(OwnTalkSettingField.chatBackgroundColor), '#1E3A5F');
    expect(server.settingsRequests.first.method, 'GET');
    expect(server.settingsRequests.first.headers['If-None-Match'], isNull);
    expect(
      (await store.read(_key))?[OwnTalkSettingField.chatBackgroundColor],
      '#1E3A5F',
    );

    await controller().refresh();
    expect(server.settingsRequests.last.headers['If-None-Match'], '"r1-e1"');
    expect(shown().settings!.revision, 1);
  });

  test('revalidates with the ETag the server sent, so a role change behind '
      'the same revision reaches the screen', () async {
    // Only the explicit refreshes below may reach the server: a timed poll
    // in between would send the newer ETag first on a slow machine.
    container.dispose();
    container = open(interval: const Duration(minutes: 5));
    watch();
    await until(() => shown().settings != null);
    expect(shown().canEdit, isTrue);

    server.canEdit = false;
    await controller().refresh();
    expect(server.settingsRequests.last.headers['If-None-Match'], '"r0-e1"');
    expect(shown().settings!.revision, 0);
    expect(shown().canEdit, isFalse);

    server.canEdit = true;
    await controller().refresh();
    expect(server.settingsRequests.last.headers['If-None-Match'], '"r0-e0"');
    expect(shown().canEdit, isTrue);
  });

  test('sends the ETag opaquely and sends none when the header was missing '
      'or garbled', () async {
    container.dispose();
    container = open(interval: const Duration(minutes: 5));
    server.omitEtag = true;
    watch();
    await until(() => shown().settings != null);
    await controller().refresh();
    expect(server.settingsRequests.last.headers['If-None-Match'], isNull);

    server.omitEtag = false;
    await controller().refresh();
    await controller().refresh();
    expect(server.settingsRequests.last.headers['If-None-Match'], '"r0-e1"');
  });

  test('the ETag is cached with the document and old entries without one '
      'send no If-None-Match', () async {
    server.setExternally({'chat.backgroundColor': '#1E3A5F'});
    watch();
    await until(() => shown().settings != null);
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    container = open();
    watch();
    await until(() => server.settingsRequests.length > 1);
    expect(server.settingsRequests.last.headers['If-None-Match'], '"r1-e1"');
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    await store.write(_key, documentWith({'chat.backgroundColor': '#1E3A5F'}));
    final before = server.settingsRequests.length;
    container = open();
    watch();
    await until(() => server.settingsRequests.length > before);
    expect(server.settingsRequests[before].headers['If-None-Match'], isNull);
  });

  test('after a refused save the next read goes out without If-None-Match '
      'and shows the lost edit right', () async {
    watch();
    await until(() => shown().settings != null);
    server.canEdit = false;

    final result = await controller().save({
      OwnTalkSettingField.chatAccentColor: '#FFFFFF',
    });
    expect(
      (result as OwnTalkSettingsUpdateFailure).kind,
      OwnTalkExtensionsFailureKind.forbidden,
    );
    await until(() => !shown().canEdit);
    final reads = server.settingsRequests.where((r) => r.method == 'GET');
    expect(reads.last.headers['If-None-Match'], isNull);
  });

  test('a save adopts the ETag of the saved document', () async {
    watch();
    await until(() => shown().settings != null);
    await controller().save({OwnTalkSettingField.bubbleOwnColor: '#2F6FEB'});
    await controller().refresh();
    expect(server.settingsRequests.last.headers['If-None-Match'], '"r1-e1"');
  });

  test('401 stops polling', () async {
    watch();
    await until(() => shown().settings != null);
    server.failSettingsWith = 401;
    await controller().refresh();
    final count = server.settingsRequests.length;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(server.settingsRequests.length, count);
    expect(shown().settings, isNotNull);
  });

  test('a 401 on the capability read stops polling too', () async {
    container.dispose();
    container = open(capabilityTtl: Duration.zero);
    watch();
    await until(() => shown().settings != null);
    server.failCapabilitiesWith = 401;
    await controller().refresh();
    final count = server.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(server.requests.length, count);
  });

  test('429 backs off, honouring Retry-After', () async {
    watch();
    await until(() => shown().settings != null);
    server
      ..failSettingsWith = 429
      ..failHeaders = {'retry-after': '1'};
    await controller().refresh();
    final count = server.settingsRequests.length;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(server.settingsRequests.length, count);
    server.failSettingsWith = null;
    await until(() => server.settingsRequests.length > count);
    expect(shown().settings, isNotNull);
  });

  test('429 without Retry-After doubles the interval', () async {
    watch();
    await until(() => shown().settings != null);
    server.failSettingsWith = 429;
    await controller().refresh();
    final count = server.settingsRequests.length;
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    // 80 ms flat would be about a dozen requests; doubling gives two or three.
    expect(server.settingsRequests.length - count, lessThanOrEqualTo(4));
    expect(server.settingsRequests.length - count, greaterThanOrEqualTo(1));
  });

  test('a cache read that finishes late never replaces a newer state', () async {
    await store.write(_key, documentWith({'chat.backgroundColor': '#111111'}));
    server.setExternally({'chat.backgroundColor': '#222222'});
    server.setExternally({'chat.backgroundColor': '#333333'});
    final gate = Completer<OwnTalkSettingsStore>();
    container.dispose();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(
          MemoryCredentialVault()..values['account-a'] = 'fixture-password',
        ),
        nextcloudApiProvider.overrideWithValue(
          HttpNextcloudApi(client: server.client),
        ),
        ownTalkSettingsStoreProvider.overrideWith((ref) => gate.future),
        ownTalkSettingsPollIntervalProvider.overrideWithValue(
          const Duration(hours: 1),
        ),
        appLifecycleResumeEventsProvider.overrideWithValue(resumes.stream),
      ],
    );
    watch();
    resumes.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    gate.complete(store);
    await until(
      () =>
          shown().valueOf(OwnTalkSettingField.chatBackgroundColor) == '#333333',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      shown().valueOf(OwnTalkSettingField.chatBackgroundColor),
      '#333333',
    );
    expect(shown().settings!.revision, 2);
  });

  test('polls while watched and picks up another user change', () async {
    watch();
    await until(() => shown().available);
    server.setExternally({'bubble.ownColor': '#2F6FEB'});
    await until(
      () => shown().valueOf(OwnTalkSettingField.bubbleOwnColor) == '#2F6FEB',
    );
  });

  test('a resume event refreshes immediately', () async {
    container.dispose();
    container = open(interval: const Duration(hours: 1));
    watch();
    await until(() => shown().available);
    server.setExternally({'composer.quickEmoji': '\u{1F44D}'});
    resumes.add(null);
    await until(
      () =>
          shown().valueOf(OwnTalkSettingField.composerQuickEmoji) ==
          '\u{1F44D}',
    );
  });

  test('without the capability no extension endpoint is requested and the '
      'cache of the account is dropped', () async {
    await store.write(_key, documentWith({'chat.backgroundColor': '#112233'}));
    server.capability = null;
    watch();
    await until(() => server.requests.isNotEmpty);
    await controller().refresh();

    expect(server.settingsRequests, isEmpty);
    expect(shown().available, isFalse);
    expect(shown().settings, isNull);
    expect(await store.read(_key), isNull);
  });

  test('an unknown api version means off', () async {
    server.capability = {...ownTalkCapabilityJson(), 'api': 2};
    watch();
    await controller().refresh();
    expect(server.settingsRequests, isEmpty);
    expect(shown().available, isFalse);
  });

  test('404 shows nothing and forgets the cached document', () async {
    server.setExternally({'chat.backgroundColor': '#1E3A5F'});
    watch();
    await until(() => shown().settings != null);

    server.failSettingsWith = 404;
    await controller().refresh();
    expect(shown().settings, isNull);
    expect(shown().available, isTrue);
    expect(await store.read(_key), isNull);
  });

  test('503 keeps the cache and retries later', () async {
    server.setExternally({'chat.backgroundColor': '#1E3A5F'});
    watch();
    await until(() => shown().settings != null);

    server.failSettingsWith = 503;
    await controller().refresh();
    expect(shown().valueOf(OwnTalkSettingField.chatBackgroundColor), '#1E3A5F');

    final before = server.settingsRequests.length;
    server.failSettingsWith = null;
    await until(() => server.settingsRequests.length > before + 1);
    expect(shown().settings!.revision, 1);
  });

  test(
    'a cold start shows the cached document while the network is down',
    () async {
      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      watch();
      await until(() => shown().settings != null);
      container.dispose();

      server.failSettingsWith = 503;
      container = open();
      watch();
      await until(() => shown().settings != null);
      expect(
        shown().valueOf(OwnTalkSettingField.chatBackgroundColor),
        '#1E3A5F',
      );
    },
  );

  test('save sends If-Match and adopts the saved document', () async {
    watch();
    await until(() => shown().available);

    final result = await controller().save({
      OwnTalkSettingField.bubbleOwnColor: '#2f6feb',
    });
    expect(result, isA<OwnTalkSettingsSaved>());
    final patch = server.settingsRequests.last;
    expect(patch.method, 'PATCH');
    expect(patch.headers['If-Match'], '"r0"');
    expect(shown().valueOf(OwnTalkSettingField.bubbleOwnColor), '#2F6FEB');
    expect(shown().settings!.revision, 1);
  });

  test('save reports a conflict with the server document and can be '
      're-applied on the new revision', () async {
    watch();
    await until(() => shown().available);
    server.beforePatch = () =>
        server.setExternally({'bubble.ownColor': '#00FF00'});

    final conflict =
        await controller().save({OwnTalkSettingField.bubbleOwnColor: '#FF0000'})
            as OwnTalkSettingsConflict;
    expect(conflict.conflictingFields, [OwnTalkSettingField.bubbleOwnColor]);
    expect(conflict.current[OwnTalkSettingField.bubbleOwnColor], '#00FF00');
    expect(shown().valueOf(OwnTalkSettingField.bubbleOwnColor), '#00FF00');

    final retry = await controller().save({
      OwnTalkSettingField.bubbleOwnColor: '#FF0000',
    });
    expect(retry, isA<OwnTalkSettingsSaved>());
    expect(server.settingsRequests.last.headers['If-Match'], '"r1"');
    expect(shown().valueOf(OwnTalkSettingField.bubbleOwnColor), '#FF0000');
  });

  test('save checks against the revision the edit started from, not a '
      'newer one a poll brought in meanwhile', () async {
    watch();
    await until(() => shown().available);
    final startedFrom = shown().settings!.revision;
    server.setExternally({'chat.backgroundColor': '#3B1F4A'});
    await controller().refresh();
    await until(() => shown().settings!.revision > startedFrom);

    final result = await controller().save({
      OwnTalkSettingField.chatBackgroundColor: '#0B4F3A',
    }, baseRevision: startedFrom);
    expect(result, isA<OwnTalkSettingsConflict>());
    expect(
      server.settingsRequests.last.headers['If-Match'],
      '"r$startedFrom"',
    );
    expect(shown().valueOf(OwnTalkSettingField.chatBackgroundColor), '#3B1F4A');
  });

  test('save without edit rights surfaces the server refusal', () async {
    server.canEdit = false;
    watch();
    await until(() => shown().available);
    expect(shown().canEdit, isFalse);
    final result = await controller().save({
      OwnTalkSettingField.chatAccentColor: '#FFFFFF',
    });
    expect(
      (result as OwnTalkSettingsUpdateFailure).kind,
      OwnTalkExtensionsFailureKind.forbidden,
    );
  });

  test('features the server dropped are not applied', () async {
    server.setExternally({
      'bubble.ownColor': '#2F6FEB',
      'chat.backgroundColor': '#1E3A5F',
    });
    server.capability = ownTalkCapabilityJson(features: ['appearance.colors']);
    watch();
    await until(() => shown().settings != null);
    expect(shown().valueOf(OwnTalkSettingField.chatBackgroundColor), '#1E3A5F');
    expect(shown().valueOf(OwnTalkSettingField.bubbleOwnColor), isNull);
  });

  group('store', () {
    test('keeps accounts apart and removes one account only', () async {
      const keyB = (accountId: 'account-b', roomToken: ownTalkTestToken);
      await store.write(
        _key,
        documentWith({'chat.backgroundColor': '#111111'}),
      );
      await store.write(
        keyB,
        documentWith({'chat.backgroundColor': '#222222'}),
      );
      expect(
        (await store.read(_key))![OwnTalkSettingField.chatBackgroundColor],
        '#111111',
      );
      expect(
        (await store.read(keyB))![OwnTalkSettingField.chatBackgroundColor],
        '#222222',
      );
      await store.removeAccount('account-a');
      expect(await store.read(_key), isNull);
      expect(await store.read(keyB), isNotNull);
    });

    test('a corrupt file reads as empty and is overwritten', () async {
      final doc = documentWith({'chat.backgroundColor': '#111111'});
      await store.write(_key, doc);
      for (final file in directory.listSync().whereType<File>()) {
        file.writeAsStringSync('{not json');
      }
      expect(await store.read(_key), isNull);
      await store.write(_key, doc);
      expect(await store.read(_key), isNotNull);
    });
  });
}
