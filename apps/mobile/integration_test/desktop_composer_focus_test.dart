@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';

import 'desktop_app_support.dart';

/// Typing right after the window comes back, on a real Windows window.
///
/// The widget suite already holds the guards — a dialog, a search field, a
/// deliberate second editor and a conversation that cannot be posted to all
/// keep the composer's hands off the focus. What it cannot show is the part
/// the report was actually about: whether Windows tells the app anything at
/// all when a window is minimized and restored. `didChangeAppLifecycleState`
/// is what triggers the restore, so if the desktop embedder stayed quiet, all
/// thirty-two of those tests would still pass and the user would still have to
/// click into the box.
///
/// Run on demand:
/// `flutter test integration_test/desktop_composer_focus_test.dart -d windows`
/// with `NKS_CALL_ROOM` naming a conversation this account may post to.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final roomToken = Platform.environment['NKS_CALL_ROOM'];
  final journal = DesktopJournal(Platform.environment['NKS_CALL_JOURNAL']);

  testWidgets('the composer takes focus back when the window returns', (
    tester,
  ) async {
    expect(roomToken, isNotNull, reason: 'set NKS_CALL_ROOM');
    journal.note('start');

    // What Windows actually tells the app is the whole question here, so the
    // states are written down as they arrive.
    final lifecycle = <AppLifecycleState>[];
    final listener = AppLifecycleListener(
      onStateChange: (state) {
        lifecycle.add(state);
        journal.note('lifecycle $state');
      },
    );
    addTearDown(listener.dispose);

    await tester.pumpWidget(const ProviderScope(child: NextcloudTalkApp()));
    await settle(tester, const Duration(seconds: 5));

    final tile = find.byKey(Key('conversation-tile-$roomToken'));
    await waitFor(tester, tile, what: 'the conversation tile');
    await tester.tap(tile);

    final composer = find.byKey(const Key('chat-composer'));
    await waitFor(tester, composer, what: 'the composer');
    await settle(tester, const Duration(seconds: 2));
    journal.note('room open');

    // Start from somewhere the restore has to actually move the focus from.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, const Duration(seconds: 1));
    expect(
      _hasFocus(tester, composer),
      isFalse,
      reason: 'the composer should have let go of the focus',
    );
    journal.note('composer unfocused');

    showWindow(minimize: true);
    await holdWithoutFrames(tester, const Duration(seconds: 5));
    expect(isIconic(), isTrue, reason: 'the window did not minimize');
    journal.note('minimized');

    showWindow(minimize: false);
    journal.note('restore asked');
    await settle(tester, const Duration(seconds: 2));
    journal.note(
      'binding lifecycle=${WidgetsBinding.instance.lifecycleState} '
      'seen=$lifecycle',
    );
    await waitUntil(
      tester,
      () => _hasFocus(tester, composer),
      what: 'the composer to take the focus back',
      timeout: const Duration(seconds: 20),
    );
    expect(isIconic(), isFalse);
    journal.note('focus restored');

    // And it is a real editor, not just a focused node: typing arrives.
    await tester.enterText(composer, 'restored');
    await settle(tester, const Duration(seconds: 1));
    expect(
      tester.widget<TextField>(composer).controller?.text,
      'restored',
      reason: 'the restored focus did not accept typing',
    );
    journal.note('typed');

    // Leave no draft behind on a real account.
    await tester.enterText(composer, '');
    await settle(tester, const Duration(seconds: 3));
    journal.note('cleared');
  }, timeout: const Timeout(Duration(minutes: 4)));
}

bool _hasFocus(WidgetTester tester, Finder composer) =>
    tester.widget<TextField>(composer).focusNode?.hasFocus ?? false;
