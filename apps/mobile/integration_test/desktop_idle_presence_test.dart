@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/chat_room_signaling.dart';

import 'desktop_app_support.dart';

/// A forgotten window stops telling the room somebody is there.
///
/// The rule is two minutes without keyboard, pointer, touch or scroll, and the
/// widget suite can only advance a fake clock past it. What it cannot show is
/// the part the report was about: a window nobody touches, on a desktop, where
/// frames keep being drawn, messages keep arriving and the mouse sits still on
/// top of the window - all things that could renew the deadline by accident.
/// So this waits out the real two minutes with the real timer, while the other
/// account watches the room and posts into it halfway through.
///
/// Run on demand:
/// `flutter test integration_test/desktop_idle_presence_test.dart -d windows`
/// with `NKS_CALL_ROOM` naming the conversation to open.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final roomToken = Platform.environment['NKS_CALL_ROOM'];
  final journal = DesktopJournal(Platform.environment['NKS_CALL_JOURNAL']);

  testWidgets('an untouched window releases the room presence', (tester) async {
    expect(roomToken, isNotNull, reason: 'set NKS_CALL_ROOM');
    journal.note('start');

    await tester.pumpWidget(const ProviderScope(child: NextcloudTalkApp()));
    await settle(tester, const Duration(seconds: 5));

    final tile = find.byKey(Key('conversation-tile-$roomToken'));
    await waitFor(tester, tile, what: 'the conversation tile');
    await tester.tap(tile);

    final composer = find.byKey(const Key('chat-composer'));
    await waitFor(tester, composer, what: 'the composer');
    await settle(tester, const Duration(seconds: 3));

    final container = ProviderScope.containerOf(tester.element(composer));
    final visible = container.read(chatRoomVisibilityProvider);
    expect(
      visible.values,
      isNotEmpty,
      reason: 'the room should be the visible one',
    );
    final key = visible.values.first;
    expect(key.roomToken, roomToken);

    // The tap that opened the room counts as interaction, so the deadline
    // starts here.
    expect(container.read(windowActiveProvider), isTrue);
    expect(container.read(chatRoomSessionWantedProvider(key)), isTrue);
    journal.note('presence held');

    // Nothing but frames for longer than the rule allows. No pointer, no key,
    // no scroll - and, from outside, a message posted into this very room.
    await settle(tester, const Duration(seconds: 150));

    expect(
      container.read(windowActiveProvider),
      isFalse,
      reason: 'an untouched window is not active after two minutes',
    );
    expect(
      container.read(chatRoomVisibilityProvider).values,
      isNotEmpty,
      reason: 'the chat is still on screen; only the activity ran out',
    );
    expect(
      container.read(chatRoomSessionWantedProvider(key)),
      isFalse,
      reason: 'the room session should have been released',
    );
    journal.note('presence released');

    // Real input brings it back.
    await tester.tap(composer);
    await settle(tester, const Duration(seconds: 5));
    expect(container.read(windowActiveProvider), isTrue);
    expect(container.read(chatRoomSessionWantedProvider(key)), isTrue);
    journal.note('presence back');

    await settle(tester, const Duration(seconds: 10));
    journal.note('done');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
