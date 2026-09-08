import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/chat_room_signaling.dart';

const _room = (accountId: 'account-a', roomToken: 'rooma123');
const _otherAccount = (accountId: 'account-b', roomToken: 'rooma123');

void main() {
  test('closing one pane keeps the other visible owner of the same room', () {
    final container = ProviderContainer(
      overrides: [windowActiveProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);
    final visibility = container.read(chatRoomVisibilityProvider.notifier);
    final root = Object(), thread = Object();
    visibility.setVisible(root, _room);
    visibility.setVisible(thread, _room);
    visibility.setVisible(root, null);
    expect(container.read(chatRoomSessionWantedProvider(_room)), isTrue);
    visibility.setVisible(thread, null);
    expect(container.read(chatRoomSessionWantedProvider(_room)), isFalse);
  });

  test('moving a pane to another account cannot release another owner', () {
    final container = ProviderContainer(
      overrides: [windowActiveProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);
    final visibility = container.read(chatRoomVisibilityProvider.notifier);
    final root = Object(), thread = Object();
    visibility.setVisible(root, _room);
    visibility.setVisible(thread, _room);
    visibility.setVisible(thread, _otherAccount);
    expect(container.read(chatRoomSessionWantedProvider(_room)), isTrue);
    expect(
      container.read(chatRoomSessionWantedProvider(_otherAccount)),
      isTrue,
    );
    visibility.setVisible(root, null);
    expect(container.read(chatRoomSessionWantedProvider(_room)), isFalse);
    expect(
      container.read(chatRoomSessionWantedProvider(_otherAccount)),
      isTrue,
    );
  });

  test(
    'a visible pane needs active input unless its own room holds a call',
    () {
      final container = ProviderContainer(
        overrides: [windowActiveProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);
      final visibility = container.read(chatRoomVisibilityProvider.notifier);
      visibility.setVisible(Object(), _room);
      visibility.setVisible(Object(), _otherAccount);
      expect(container.read(chatRoomSessionWantedProvider(_room)), isFalse);
      container.read(callHeldRoomsProvider.notifier).state = {_otherAccount};
      expect(container.read(chatRoomSessionWantedProvider(_room)), isFalse);
      expect(
        container.read(chatRoomSessionWantedProvider(_otherAccount)),
        isTrue,
      );
      container.read(callHeldRoomsProvider.notifier).state = {};
      expect(
        container.read(chatRoomSessionWantedProvider(_otherAccount)),
        isFalse,
      );
    },
  );

  test('repeated visibility and removal of an unknown pane are no-ops', () {
    final visibility = ChatRoomVisibility();
    addTearDown(visibility.dispose);
    var changes = 0;
    visibility.addListener((_) => changes++, fireImmediately: false);
    final owner = Object();
    visibility.setVisible(owner, _room);
    visibility.setVisible(owner, _room);
    visibility.setVisible(Object(), null);
    expect(changes, 1);
    visibility.setVisible(owner, null);
    expect(changes, 2);
    expect(visibility.state, isEmpty);
  });

  test('late pane callbacks cannot write to a disposed visibility store', () {
    final visibility = ChatRoomVisibility();
    final owner = Object();
    visibility.setVisible(owner, _room);
    visibility.dispose();
    expect(() => visibility.setVisible(owner, null), returnsNormally);
    expect(() => visibility.setVisible(owner, _otherAccount), returnsNormally);
  });
}
