import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/push/apple_push_channel.dart';

/// Keeping the notification extension supplied with room names is cheap only
/// if it is done when the names change. Each call writes them to the keychain,
/// and this provider used to make that call on every emission of the
/// conversation stream — which is every sync — and, worse, registered a fresh
/// set of listeners every time the account list emitted, so the writes
/// multiplied for as long as the app stayed open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('nks/apple-push-test');
  late List<Map<Object?, Object?>> written;

  setUp(() {
    written = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'recordConversationNames') {
            final arguments = call.arguments as Map<Object?, Object?>;
            written.add(arguments);
            return (arguments['rooms']! as List<Object?>)
                .cast<Map<Object?, Object?>>()
                .where((room) => room['name'] != '')
                .length;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  StoredAccount account(String id) => StoredAccount(
    id: id,
    serverUrl: 'https://talk.example.com',
    loginName: 'someone',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '[]',
    selected: true,
    createdAtMillis: 0,
  );

  CachedConversation room(
    String token,
    String displayName, {
    String accountId = 'account-a',
  }) => CachedConversation(
    accountId: accountId,
    token: token,
    displayName: displayName,
    description: '',
    lastActivity: 0,
    unreadMessages: 0,
    favorite: false,
    isArchived: false,
    readOnly: 0,
    roomType: 2,
    roomName: token,
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    rawJson: '{}',
  );

  ({
    ProviderContainer container,
    void Function(String, List<CachedConversation>) emit,
  })
  harness({required List<StoredAccount> accounts}) {
    final rooms = <String, StreamController<List<CachedConversation>>>{
      for (final account in accounts)
        account.id: StreamController<List<CachedConversation>>.broadcast(),
    };
    final container = ProviderContainer(
      overrides: [
        applePushCoordinatorProvider.overrideWithValue(
          ApplePushCoordinator(channel: channel),
        ),
        accountsProvider.overrideWith((ref) => Stream.value(accounts)),
        conversationsProvider.overrideWith((ref, id) => rooms[id]!.stream),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() async {
      for (final controller in rooms.values) {
        await controller.close();
      }
    });
    return (
      container: container,
      emit: (accountId, value) => rooms[accountId]!.add(value),
    );
  }

  test('the same names are not written to the keychain twice', () async {
    final probe = harness(accounts: [account('account-a')]);
    probe.container.read(accountsProvider);
    await probe.container.read(accountsProvider.future);
    probe.container.read(appleConversationIdentityProvider);

    probe.emit('account-a', [room('one', 'Pimpula')]);
    await Future<void>.delayed(Duration.zero);
    probe.emit('account-a', [room('one', 'Pimpula')]);
    await Future<void>.delayed(Duration.zero);
    probe.emit('account-a', [room('one', 'Pimpula')]);
    await Future<void>.delayed(Duration.zero);

    expect(
      written,
      hasLength(1),
      reason: 'a sync that changed no name must write nothing',
    );
  });

  test('a renamed room is written, because it is a change', () async {
    final probe = harness(accounts: [account('account-a')]);
    await probe.container.read(accountsProvider.future);
    probe.container.read(appleConversationIdentityProvider);

    probe.emit('account-a', [room('one', 'Pimpula')]);
    await Future<void>.delayed(Duration.zero);
    probe.emit('account-a', [room('one', 'Pimpula a hosté')]);
    await Future<void>.delayed(Duration.zero);

    expect(written, hasLength(2));
    expect(written.last['rooms'], <Object?>[
      <String, String>{'token': 'one', 'name': 'Pimpula a hosté'},
    ]);
  });

  test('a room that disappears is removed from the keychain', () async {
    final probe = harness(accounts: [account('account-a')]);
    await probe.container.read(accountsProvider.future);
    probe.container.read(appleConversationIdentityProvider);

    probe.emit('account-a', [room('one', 'Pimpula'), room('two', 'Vývoj')]);
    await Future<void>.delayed(Duration.zero);
    probe.emit('account-a', [room('two', 'Vývoj')]);
    await Future<void>.delayed(Duration.zero);

    expect(written, hasLength(2));
    expect(written.last['rooms'], <Object?>[
      <String, String>{'token': 'one', 'name': ''},
    ]);
  });

  test('the same token stays separate for two accounts', () async {
    final probe = harness(
      accounts: [account('account-a'), account('account-b')],
    );
    await probe.container.read(accountsProvider.future);
    probe.container.read(appleConversationIdentityProvider);

    probe.emit('account-a', [room('shared', 'On A', accountId: 'account-a')]);
    probe.emit('account-b', [room('shared', 'On B', accountId: 'account-b')]);
    await Future<void>.delayed(Duration.zero);

    expect(written, hasLength(2));
    expect(
      {
        for (final call in written)
          call['accountId']: (call['rooms']! as List<Object?>).single,
      },
      {
        'account-a': <String, String>{'token': 'shared', 'name': 'On A'},
        'account-b': <String, String>{'token': 'shared', 'name': 'On B'},
      },
    );
  });

  test(
    'a failed keychain write is retried by the next unchanged sync',
    () async {
      var attempt = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'recordConversationNames') {
              return null;
            }
            written.add(call.arguments as Map<Object?, Object?>);
            if (attempt++ == 0) {
              throw PlatformException(code: 'keychain');
            }
            return 1;
          });
      final probe = harness(accounts: [account('account-a')]);
      await probe.container.read(accountsProvider.future);
      probe.container.read(appleConversationIdentityProvider);

      probe.emit('account-a', [room('one', 'Pimpula')]);
      await Future<void>.delayed(Duration.zero);
      probe.emit('account-a', [room('one', 'Pimpula')]);
      await Future<void>.delayed(Duration.zero);

      expect(written, hasLength(2));
    },
  );

  test('a partial keychain batch is retried in full', () async {
    var attempt = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'recordConversationNames') {
            return null;
          }
          written.add(call.arguments as Map<Object?, Object?>);
          return attempt++ == 0 ? 1 : 2;
        });
    final probe = harness(accounts: [account('account-a')]);
    await probe.container.read(accountsProvider.future);
    probe.container.read(appleConversationIdentityProvider);

    final rooms = [room('one', 'Pimpula'), room('two', 'Vývoj')];
    probe.emit('account-a', rooms);
    await Future<void>.delayed(Duration.zero);
    probe.emit('account-a', rooms);
    await Future<void>.delayed(Duration.zero);

    expect(written, hasLength(2));
    expect(written.first['rooms'], written.last['rooms']);
  });

  test(
    'a newer snapshot cleans names left uncertain by a partial batch',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'recordConversationNames') {
              return null;
            }
            written.add(call.arguments as Map<Object?, Object?>);
            return 1;
          });
      final probe = harness(accounts: [account('account-a')]);
      await probe.container.read(accountsProvider.future);
      probe.container.read(appleConversationIdentityProvider);

      probe.emit('account-a', [room('one', 'Pimpula'), room('two', 'Vývoj')]);
      await Future<void>.delayed(Duration.zero);
      probe.emit('account-a', [room('two', 'Vývoj')]);
      await Future<void>.delayed(Duration.zero);

      expect(written, hasLength(2));
      expect(
        written.last['rooms'],
        unorderedEquals(<Object?>[
          <String, String>{'token': 'one', 'name': ''},
          <String, String>{'token': 'two', 'name': 'Vývoj'},
        ]),
      );
    },
  );

  test('rapid room changes skip intermediate keychain snapshots', () async {
    final firstWrite = Completer<int>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'recordConversationNames') {
            return null;
          }
          written.add(call.arguments as Map<Object?, Object?>);
          if (written.length == 1) {
            firstStarted.complete();
            return firstWrite.future;
          }
          secondStarted.complete();
          return 1;
        });
    final probe = harness(accounts: [account('account-a')]);
    await probe.container.read(accountsProvider.future);
    probe.container.read(appleConversationIdentityProvider);

    probe.emit('account-a', [room('one', 'Original')]);
    await firstStarted.future;
    probe.emit('account-a', [room('one', 'Intermediate')]);
    probe.emit('account-a', [room('one', 'Final')]);
    firstWrite.complete(1);
    await secondStarted.future;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(written, hasLength(2));
    expect(written.last['rooms'], <Object?>[
      <String, String>{'token': 'one', 'name': 'Final'},
    ]);
  });
}
