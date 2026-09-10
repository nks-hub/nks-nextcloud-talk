@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';

import 'desktop_app_support.dart';

/// A call that fails to join, and then joins when asked again.
///
/// Every recorded call in this project succeeded the first time, so "a
/// successful retry after a failed admission" had never been shown against the
/// real signalling server. The failure here is induced from outside - the
/// operator blocks the server while the first attempt runs and lets it back
/// afterwards - because a failure that only a mock can produce proves nothing
/// about the lane this item is asking about.
///
/// Handshake: the test writes `<journal>.failed` when the first attempt has
/// visibly failed, and waits for `<journal>.unblocked` before trying again.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final roomToken = Platform.environment['NKS_CALL_ROOM'];
  final journalPath = Platform.environment['NKS_CALL_JOURNAL'];
  final journal = DesktopJournal(journalPath);
  final failedMark = File('${journalPath ?? "desktop-journal.txt"}.failed');
  final unblockedMark = File('${journalPath ?? "desktop-journal.txt"}.unblocked');

  testWidgets('a refused call joins when it is asked again', (tester) async {
    expect(roomToken, isNotNull, reason: 'set NKS_CALL_ROOM');
    if (failedMark.existsSync()) {
      failedMark.deleteSync();
    }
    journal.note('start');

    await tester.pumpWidget(const ProviderScope(child: NextcloudTalkApp()));
    await settle(tester, const Duration(seconds: 5));

    final tile = find.byKey(Key('conversation-tile-$roomToken'));
    await waitFor(tester, tile, what: 'the conversation tile');
    await tester.tap(tile);

    final startCall = find.byKey(const Key('start-call-audio'));
    await waitFor(tester, startCall, what: 'the audio call button');
    final callScreen = find.byKey(const Key('call-screen'));

    // First attempt, with the server unreachable.
    await tester.tap(startCall);
    journal.note('asked with the server blocked');
    await settle(tester, const Duration(seconds: 40));
    expect(
      callScreen,
      findsNothing,
      reason: 'a call cannot be joined while the server is unreachable',
    );
    journal.note('first attempt failed as expected');
    failedMark.writeAsStringSync('failed\n');

    // The operator gives the network back.
    await waitUntil(
      tester,
      unblockedMark.existsSync,
      what: 'the server to be reachable again',
      timeout: const Duration(minutes: 3),
    );
    journal.note('server is back');
    await settle(tester, const Duration(seconds: 5));

    // Second attempt: the same control, the same lane.
    await waitFor(tester, startCall, what: 'the audio call button again');
    await tester.tap(startCall);
    journal.note('asked again');
    await waitFor(
      tester,
      callScreen,
      what: 'the call screen on the retry',
      timeout: const Duration(seconds: 90),
    );
    journal.note('joined on the retry');

    await settle(tester, const Duration(seconds: 10));
    await tester.tap(find.byKey(const Key('call-screen-leave')));
    await waitUntilGone(tester, callScreen, what: 'the call screen');
    await settle(tester, const Duration(seconds: 15));
    journal.note('left');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
