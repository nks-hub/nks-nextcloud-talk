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
            written.add(call.arguments as Map<Object?, Object?>);
            return written.length;
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

  CachedConversation room(String token, String displayName) =>
      CachedConversation(
        accountId: 'account-a',
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

  ({ProviderContainer container, void Function(List<CachedConversation>) emit})
  harness({required List<StoredAccount> accounts}) {
    final rooms = StreamController<List<CachedConversation>>.broadcast();
    final container = ProviderContainer(
      overrides: [
        applePushCoordinatorProvider.overrideWithValue(
          ApplePushCoordinator(channel: channel),
        ),
        accountsProvider.overrideWith((ref) => Stream.value(accounts)),
        conversationsProvider.overrideWith((ref, id) => rooms.stream),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(rooms.close);
    return (container: container, emit: rooms.add);
  }

  test('the same names are not written to the keychain twice', () async {
    final probe = harness(accounts: [account('account-a')]);
    probe.container.read(accountsProvider);
    await probe.container.read(accountsProvider.future);
    probe.container.read(appleConversationIdentityProvider);

    probe.emit([room('one', 'Pimpula')]);
    await Future<void>.delayed(Duration.zero);
    probe.emit([room('one', 'Pimpula')]);
    await Future<void>.delayed(Duration.zero);
    probe.emit([room('one', 'Pimpula')]);
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

    probe.emit([room('one', 'Pimpula')]);
    await Future<void>.delayed(Duration.zero);
    probe.emit([room('one', 'Pimpula a hosté')]);
    await Future<void>.delayed(Duration.zero);

    expect(written, hasLength(2));
  });
}
