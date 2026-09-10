@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';

import 'desktop_app_support.dart';

/// Sharing a real screen, and then a real window, out of a real call.
///
/// The widget suite covers the picker, the engine call and the button; what it
/// cannot do is ask the platform for the sources that actually exist on this
/// machine and hand one of their identifiers to libwebrtc. That last step is
/// where the defect this item started from lived: `getDisplayMedia` used to be
/// asked for "video: true" and looked up source "0" in an empty list.
///
/// The picture itself is confirmed on the OTHER client, by a person or a phone
/// looking at the call; nothing here can see it, because a Flutter window on
/// Windows is not visible to any screen capture this machine can perform.
///
/// Run on demand with `NKS_CALL_ROOM` naming a room the other client is in:
/// `flutter test integration_test/desktop_screen_share_test.dart -d windows`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final roomToken = Platform.environment['NKS_CALL_ROOM'];
  final journal = DesktopJournal(Platform.environment['NKS_CALL_JOURNAL']);
  final joinWait = Duration(
    seconds: int.tryParse(Platform.environment['NKS_JOIN_WAIT'] ?? '') ?? 45,
  );

  testWidgets('a call shares a chosen screen and then a chosen window', (
    tester,
  ) async {
    expect(roomToken, isNotNull, reason: 'set NKS_CALL_ROOM');
    journal.note('start');

    await tester.pumpWidget(const ProviderScope(child: NextcloudTalkApp()));
    await settle(tester, const Duration(seconds: 5));

    final tile = find.byKey(Key('conversation-tile-$roomToken'));
    await waitFor(tester, tile, what: 'the conversation tile');
    await tester.tap(tile);

    final startCall = find.byKey(const Key('start-call-audio'));
    await waitFor(tester, startCall, what: 'the audio call button');
    await tester.tap(startCall);

    final callScreen = find.byKey(const Key('call-screen'));
    await waitFor(
      tester,
      callScreen,
      what: 'the call screen',
      timeout: const Duration(seconds: 60),
    );
    journal.note('joined');

    // Time for the other client to answer, so the share has an audience.
    await settle(tester, joinWait);
    journal.note('waited for the other side');

    await _share(tester, journal, pickLast: false, stopFirst: false);
    await settle(tester, const Duration(seconds: 60));
    journal.note('screen shared, holding');

    // The same control stops a running share, so a second choice needs two
    // presses: one to stop, one to ask again. Learned from a run where the
    // second press found no picker at all.
    await _share(tester, journal, pickLast: true, stopFirst: true);
    await settle(tester, const Duration(seconds: 60));
    journal.note('window shared, holding');

    final leave = find.byKey(const Key('call-screen-leave'));
    await waitFor(tester, leave, what: 'the leave button');
    await tester.tap(leave);
    await waitUntilGone(tester, callScreen, what: 'the call screen');
    await settle(tester, const Duration(seconds: 15));
    journal.note('left');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Opens the picker and shares one source, writing down which one it chose so
/// what the other client sees can be checked against a name rather than a
/// guess.
Future<void> _share(
  WidgetTester tester,
  DesktopJournal journal, {
  required bool pickLast,
  required bool stopFirst,
}) async {
  final button = find.byKey(const Key('call-screen-share-screen'));
  if (stopFirst) {
    await tester.tap(button);
    await settle(tester, const Duration(seconds: 4));
    journal.note('stopped the running share');
  }
  await tester.tap(button);
  await settle(tester, const Duration(seconds: 2));

  // `Key('call-screen-source-confirm')` IS a ValueKey<String> that starts the
  // same way, so a prefix match alone offers the confirm button as if it were a
  // monitor - which is exactly what one run then "shared".
  const controls = {'confirm', 'retry', 'loading', 'error'};
  final sources = find.byWidgetPredicate((widget) {
    final key = widget.key;
    if (key is! ValueKey<String>) {
      return false;
    }
    const prefix = 'call-screen-source-';
    if (!key.value.startsWith(prefix)) {
      return false;
    }
    return !controls.contains(key.value.substring(prefix.length));
  });
  await waitFor(
    tester,
    sources,
    what: 'the screen sources',
    timeout: const Duration(seconds: 30),
  );
  final found = sources.evaluate().toList();
  journal.note('picker offered ${found.length} sources');
  expect(
    found,
    isNotEmpty,
    reason: 'the platform offered nothing to share, which is the old defect',
  );

  // NEVER "just take the last window". The first run of this did, and the
  // machine's last window was somebody's open mailbox, which would have gone
  // down the wire to everyone in the call. A window is chosen by name, and the
  // name is this application's own.
  var chosen = 0;
  if (pickLast) {
    chosen = -1;
    for (var index = 0; index < found.length; index++) {
      final label = find
          .descendant(of: sources.at(index), matching: find.byType(Text))
          .evaluate()
          .map((element) => (element.widget as Text).data)
          .whereType<String>()
          .join(' ');
      if (label.contains('NKS Talk')) {
        chosen = index;
        break;
      }
    }
    expect(
      chosen,
      isNot(-1),
      reason: 'no window of this application was offered to share',
    );
  }
  final key = (found[chosen].widget.key! as ValueKey<String>).value;
  // The name is what the other client's picture has to match.
  final labels = find
      .descendant(of: sources.at(chosen), matching: find.byType(Text))
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .toList();
  journal.note('choosing $key named ${labels.join(" / ")}');
  await tester.tap(sources.at(chosen));
  await settle(tester, const Duration(seconds: 1));

  final confirm = find.byKey(const Key('call-screen-source-confirm'));
  await waitFor(tester, confirm, what: 'the confirm button');
  await tester.tap(confirm);
  await settle(tester, const Duration(seconds: 5));
  journal.note('shared $key');
}
