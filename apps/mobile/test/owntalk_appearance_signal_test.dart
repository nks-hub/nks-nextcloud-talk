import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_extensions_service.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const _key = (accountId: 'account-a', roomToken: ownTalkTestToken);
const _otherAccount = (accountId: 'account-b', roomToken: ownTalkTestToken);
const _otherRoom = (accountId: 'account-a', roomToken: 'roomb456');
const _notice = 'The look changed';
const _window = Duration(milliseconds: 120);
const _silentTalk = ['chat-reference-id', 'silent-send'];

final _refProvider = Provider<Ref>((ref) => ref);

OwnTalkRoomSettingsSignal _signal(
  int revision, {
  String token = ownTalkTestToken,
}) => parseOwnTalkRoomSettingsFrame(
  'owntalk_room_settings {"token":"$token","revision":$revision}',
)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory directory;
  late FakeOwnTalkServer server;
  late OwnTalkSettingsStore store;
  late ProviderContainer container;

  ProviderContainer open() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(
        MemoryCredentialVault()
          ..values['account-a'] = 'fixture-password'
          ..values['account-b'] = 'other-password',
      ),
      nextcloudApiProvider.overrideWithValue(
        HttpNextcloudApi(client: server.client),
      ),
      ownTalkSettingsStoreProvider.overrideWith((ref) => store),
      // Only the explicit refreshes below may reach the server.
      ownTalkSettingsPollIntervalProvider.overrideWithValue(
        const Duration(minutes: 5),
      ),
      ownTalkAppearanceNoticeWindowProvider.overrideWithValue(_window),
      appLifecycleResumeEventsProvider.overrideWithValue(
        const Stream<void>.empty(),
      ),
    ],
  );

  OwnTalkRoomController controller([OwnTalkRoomKey key = _key]) =>
      container.read(ownTalkRoomExtrasProvider(key).notifier);

  OwnTalkRoomExtras shown([OwnTalkRoomKey key = _key]) =>
      container.read(ownTalkRoomExtrasProvider(key));

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not reached');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  ProviderSubscription<OwnTalkRoomExtras> watch([
    OwnTalkRoomKey key = _key,
  ]) => container.listen(
    ownTalkRoomExtrasProvider(key),
    (_, _) {},
    fireImmediately: true,
  );

  Future<void> watched() async {
    watch();
    await until(() => shown().settings != null);
  }

  Future<void> pastWindow() =>
      Future<void>.delayed(_window * 3 + const Duration(milliseconds: 60));

  int requestsFor(String loginName) {
    final expected =
        'Basic ${base64Encode(utf8.encode('$loginName:${loginName == 'fixture-user' ? 'fixture-password' : 'other-password'}'))}';
    return server.settingsRequests
        .where((r) => r.headers['Authorization'] == expected)
        .length;
  }

  Future<OwnTalkSettingsUpdateResult> saveColor(
    String color, {
    String? announcement = _notice,
  }) => controller().save({
    OwnTalkSettingField.chatAccentColor: color,
  }, announcement: announcement);

  setUp(() async {
    database = openTestDatabase();
    final accounts = AccountRepository(database);
    for (final (id, login) in [
      ('account-a', 'fixture-user'),
      ('account-b', 'other-user'),
    ]) {
      await accounts.upsertAccount(
        accountId: id,
        serverUrl: 'https://cloud.example.invalid',
        loginName: login,
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.utc(2026, 1, 1),
      );
    }
    directory = await Directory.systemTemp.createTemp('owntalk-signal-');
    store = OwnTalkSettingsStore.forTesting(directory);
    server = FakeOwnTalkServer()..talkFeatures = _silentTalk;
    container = open();
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  group('settings signal routing', () {
    test('a newer revision re-reads only the controller of that account '
        'and room', () async {
      watch();
      watch(_otherAccount);
      watch(_otherRoom);
      await until(() => shown().settings != null);
      await until(() => shown(_otherAccount).settings != null);
      await until(
        () => server.requests.any((r) => r.url.path.contains('/roomb456/')),
      );
      final readsA = requestsFor('fixture-user');
      final readsB = requestsFor('other-user');
      final readsOtherRoom = server.requests
          .where((r) => r.url.path.contains('/roomb456/'))
          .length;

      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      deliverOwnTalkRoomSettingsSignal(
        container.read(_refProvider),
        'account-a',
        _signal(1),
      );
      await until(() => shown().settings!.revision == 1);

      expect(
        shown().valueOf(OwnTalkSettingField.chatBackgroundColor),
        '#1E3A5F',
      );
      expect(requestsFor('fixture-user'), readsA + 1);
      expect(requestsFor('other-user'), readsB);
      expect(shown(_otherAccount).settings!.revision, 0);
      expect(
        server.requests.where((r) => r.url.path.contains('/roomb456/')).length,
        readsOtherRoom,
      );
    });

    test('a revision that is not newer than the shown one is skipped', () async {
      await watched();
      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      await controller().refresh();
      expect(shown().settings!.revision, 1);
      final reads = server.settingsRequests.length;

      for (final revision in [0, 1]) {
        deliverOwnTalkRoomSettingsSignal(
          container.read(_refProvider),
          'account-a',
          _signal(revision),
        );
      }
      await controller().refresh();
      // Only the explicit refresh above went out.
      expect(server.settingsRequests.length, reads + 1);
    });

    test('a signal for a room nobody watches creates nothing and asks '
        'nothing', () async {
      deliverOwnTalkRoomSettingsSignal(
        container.read(_refProvider),
        'account-a',
        _signal(4),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(container.exists(ownTalkRoomExtrasProvider(_key)), isFalse);
      expect(server.requests, isEmpty);
    });

    test('acting on a signal never sends a chat message', () async {
      await watched();
      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      deliverOwnTalkRoomSettingsSignal(
        container.read(_refProvider),
        'account-a',
        _signal(1),
      );
      await until(() => shown().settings!.revision == 1);
      await pastWindow();
      expect(server.chatPosts, isEmpty);
    });
  });

  group('silent notice after a write', () {
    test('a save posts one silent message carrying the revision', () async {
      await watched();
      final result = await saveColor('#FFFFFF');
      expect(result, isA<OwnTalkSettingsSaved>());
      expect(server.chatPosts, isEmpty, reason: 'held back for the window');

      await until(() => server.chatPosts.isNotEmpty);
      await pastWindow();
      expect(server.chatPosts, hasLength(1));
      final post = server.chatPosts.single;
      expect(post.bodyFields, {
        'message': _notice,
        'referenceId': 'owntalk-appearance-1',
        'silent': 'true',
      });
      expect(post.headers['Authorization'], startsWith('Basic '));
    });

    test('a burst of writes yields one message with the last revision', () async {
      await watched();
      await saveColor('#111111');
      await saveColor('#222222');
      await controller().save({
        OwnTalkSettingField.bubbleOwnColor: '#333333',
      }, announcement: _notice);
      expect(shown().settings!.revision, 3);

      await until(() => server.chatPosts.isNotEmpty);
      await pastWindow();
      expect(server.chatPosts, hasLength(1));
      expect(
        server.chatPosts.single.bodyFields['referenceId'],
        'owntalk-appearance-3',
      );

      // The next write opens a new window and so a new message.
      await saveColor('#444444');
      await until(() => server.chatPosts.length == 2);
      expect(
        server.chatPosts.last.bodyFields['referenceId'],
        'owntalk-appearance-4',
      );
    });

    test('a photo upload announces too', () async {
      await watched();
      final result = await controller().uploadImage(
        bytes: ownTalkTestJpeg(),
        contentType: 'image/jpeg',
        announcement: _notice,
      );
      expect(result, isA<OwnTalkSettingsSaved>());
      await until(() => server.chatPosts.isNotEmpty);
      expect(
        server.chatPosts.single.bodyFields['referenceId'],
        'owntalk-appearance-1',
      );
    });

    test('a write without announcement text stays quiet', () async {
      await watched();
      await saveColor('#FFFFFF', announcement: null);
      await pastWindow();
      expect(server.chatPosts, isEmpty);
    });

    test('a refused save sends nothing', () async {
      await watched();
      server.canEdit = false;
      final result = await saveColor('#FFFFFF');
      expect(result, isA<OwnTalkSettingsUpdateFailure>());
      await pastWindow();
      expect(server.chatPosts, isEmpty);
    });

    test('a failed save sends nothing', () async {
      await watched();
      server.failSettingsWith = 503;
      final result = await saveColor('#FFFFFF');
      expect(result, isA<OwnTalkSettingsUpdateFailure>());
      await pastWindow();
      expect(server.chatPosts, isEmpty);
    });

    test('a conflict sends nothing, even one that holds the wanted '
        'values', () async {
      await watched();
      server.beforePatch = () =>
          server.setExternally({'chat.accentColor': '#FFFFFF'});
      final result = await saveColor('#FFFFFF');
      expect(result, isA<OwnTalkSettingsConflict>());
      expect(
        (result as OwnTalkSettingsConflict).current[OwnTalkSettingField
            .chatAccentColor],
        '#FFFFFF',
      );
      await pastWindow();
      expect(server.chatPosts, isEmpty);
    });

    test('without the extension capability nothing is written or sent', () async {
      server.capability = null;
      watch();
      await until(() => server.requests.isNotEmpty);
      await expectLater(
        saveColor('#FFFFFF'),
        throwsA(isA<OwnTalkExtensionsException>()),
      );
      await pastWindow();
      expect(server.chatPosts, isEmpty);
      expect(server.settingsRequests, isEmpty);
    });

    test('without Talk silent-send the save works and no message goes out, '
        'so nobody is notified', () async {
      server.talkFeatures = const ['chat-reference-id'];
      await watched();
      final result = await saveColor('#FFFFFF');
      expect(result, isA<OwnTalkSettingsSaved>());
      await pastWindow();
      expect(server.chatPosts, isEmpty);
    });

    test('a failing message post never breaks the save and is not '
        'retried', () async {
      await watched();
      server.failChatWith = 500;
      final result = await saveColor('#FFFFFF');
      expect(result, isA<OwnTalkSettingsSaved>());
      await until(() => server.chatPosts.isNotEmpty);
      await pastWindow();
      expect(server.chatPosts, hasLength(1));
      expect(shown().settings!.revision, 1);
    });

    test('the notice outlives the controller that queued it', () async {
      final subscription = watch();
      await until(() => shown().settings != null);
      await saveColor('#FFFFFF');
      subscription.close();
      await Future<void>.delayed(Duration.zero);
      expect(container.exists(ownTalkRoomExtrasProvider(_key)), isFalse);

      await until(() => server.chatPosts.isNotEmpty);
      expect(
        server.chatPosts.single.bodyFields['referenceId'],
        'owntalk-appearance-1',
      );
    });
  });

  group('announcing messages', () {
    ({int messageId, String referenceId}) message(int id, String reference) =>
        (messageId: id, referenceId: reference);

    test('only a marker newer than what was seen counts', () {
      final watch = OwnTalkAppearanceMarkerWatch();
      expect(
        watch.fresh([message(10, 'a'), message(11, 'owntalk-appearance-2')]),
        isEmpty,
        reason: 'the first list only sets the baseline',
      );
      expect(
        watch.fresh([
          message(10, 'a'),
          message(11, 'owntalk-appearance-2'),
          message(12, 'plain'),
        ]),
        isEmpty,
      );
      expect(
        watch.fresh([
          message(5, 'owntalk-appearance-9'),
          message(11, 'owntalk-appearance-2'),
          message(12, 'plain'),
          message(13, 'owntalk-appearance-3'),
        ]),
        ['owntalk-appearance-3'],
        reason: 'older history is not news',
      );
      expect(
        watch.fresh([message(13, 'owntalk-appearance-3')]),
        isEmpty,
        reason: 'seen once, reported once',
      );
    });

    test('a marker makes the controller re-read when the revision is newer',
        () async {
      await watched();
      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      await controller().refreshForAppearanceMarkers([
        'owntalk-appearance-1',
      ]);
      expect(shown().settings!.revision, 1);
    });

    test('a marker at or below the shown revision asks nothing', () async {
      await watched();
      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      await controller().refresh();
      final reads = server.settingsRequests.length;
      await controller().refreshForAppearanceMarkers([
        'owntalk-appearance-1',
        'owntalk-appearance-0',
      ]);
      expect(server.settingsRequests.length, reads);
    });

    test('a marker with an unreadable revision still re-reads', () async {
      await watched();
      final reads = server.settingsRequests.length;
      await controller().refreshForAppearanceMarkers(['owntalk-appearance-x']);
      expect(server.settingsRequests.length, reads + 1);
    });

    test('re-reading for a marker never sends a message, so two clients '
        'cannot ping-pong', () async {
      await watched();
      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      await controller().refreshForAppearanceMarkers([
        'owntalk-appearance-1',
        'owntalk-appearance-zz',
      ]);
      await pastWindow();
      expect(server.chatPosts, isEmpty);
    });
  });
}
