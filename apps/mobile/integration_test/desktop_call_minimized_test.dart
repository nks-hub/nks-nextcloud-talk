@TestOn('windows')
library;

import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';

import 'desktop_app_support.dart';
import 'desktop_call_fixture.dart';

/// A real call, started from the real desktop client against the real server,
/// held while the operating system minimizes the window.
///
/// The widget suite can only assert that `chatRoomSessionWantedProvider` keeps
/// wanting a session; nothing in it opens a microphone, talks to a signalling
/// server or asks Windows to minimize anything. This does all three: it boots
/// the shipped app, joins a call
/// over the network, and then calls `ShowWindow(SW_MINIMIZE)` through user32 —
/// the same thing the title bar's minimize button does — before checking that
/// the call is still up. The seat on the server is watched from outside, by a
/// second account polling the call endpoint, because a client that believes it
/// is in a call while the server has dropped its seat is exactly the failure
/// this is looking for.
///
/// It is not part of the ordinary suite: it needs a signed-in account, a
/// microphone and a reachable server, so it is run on demand with
/// `flutter test integration_test/desktop_call_minimized_test.dart -d windows`
/// and the room token in `NKS_CALL_ROOM`. `NKS_CALL_ACCESS_FILE` selects a
/// dedicated account with an in-memory database and temporary file storage.
/// Missing capture hardware fails the preflight; it is not a completed call test.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final roomToken = Platform.environment['NKS_CALL_ROOM'];
  final journal = DesktopJournal(Platform.environment['NKS_CALL_JOURNAL']);

  testWidgets(
    'a joined call survives the window being minimized',
    (tester) async {
      expect(
        roomToken,
        isNotNull,
        reason: 'set NKS_CALL_ROOM to the room this account should call',
      );
      journal.note('start');
      final audioInputs = await rtc.Helper.enumerateDevices('audioinput');
      journal.note('native audio inputs ${audioInputs.length}');
      expect(
        audioInputs,
        isNotEmpty,
        reason: 'A real capture device is required for the duplex call test.',
      );

      final fixture = await DesktopCallFixture.openFromEnvironment();
      final stats = DesktopCallStats()..start();
      addTearDown(() async {
        showWindow(minimize: false);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await fixture?.dispose();
        stats.dispose();
      });
      await tester.pumpWidget(
        fixture == null
            ? const ProviderScope(child: NextcloudTalkApp())
            : UncontrolledProviderScope(
                container: fixture.container,
                child: const NextcloudTalkApp(),
              ),
      );
      await settle(tester, const Duration(seconds: 5));

      final tile = find.byKey(Key('conversation-tile-$roomToken'));
      await waitFor(tester, tile, what: 'the conversation tile');
      journal.note('list ready');

      await tester.tap(tile);
      await settle(tester, const Duration(seconds: 3));

      final startCall = find.byKey(const Key('start-call-audio'));
      await waitFor(tester, startCall, what: 'the audio call button');
      journal.note('room open');

      await tester.tap(startCall);
      final callScreen = find.byKey(const Key('call-screen'));
      await waitFor(
        tester,
        callScreen,
        what: 'the call screen',
        timeout: const Duration(seconds: 60),
      );
      final container =
          fixture?.container ??
          ProviderScope.containerOf(
            tester.element(find.byType(NextcloudTalkApp)),
          );
      final account = await container.read(selectedAccountProvider.future);
      expect(account, isNotNull);
      final key = (accountId: account!.id, roomToken: roomToken!);
      await waitUntil(
        tester,
        () =>
            container.read(callJoinControllerProvider(key)).phase ==
            CallJoinPhase.joined,
        what: 'the confirmed call join',
        timeout: const Duration(seconds: 60),
      );
      addTearDown(() async {
        await container.read(callJoinControllerProvider(key).notifier).leave();
      });
      journal.note('joined');

      var before = (sent: 0, received: 0);
      final mediaDeadline = DateTime.now().add(const Duration(minutes: 2));
      while (DateTime.now().isBefore(mediaDeadline)) {
        before = await stats.audioCounters();
        if (before.sent > 0 && before.received > 0) break;
        await settle(tester, const Duration(seconds: 1));
      }
      journal.note(
        'native audio diagnostics ${jsonEncode(await stats.diagnostics())}',
      );
      expect(
        before.sent,
        greaterThan(0),
        reason: 'no outgoing audio reached RTP',
      );
      expect(
        before.received,
        greaterThan(0),
        reason: 'no incoming audio reached RTP',
      );
      journal.note(
        'audio before minimize sent=${before.sent} received=${before.received}',
      );

      // Hold the joined call while the window is out of sight for long enough
      // that a client dropping its seat on hide would have done it: the server
      // forgets a participant that stops pinging for well under a minute.
      showWindow(minimize: true);
      await holdWithoutFrames(tester, const Duration(seconds: 2));
      expect(isIconic(), isTrue, reason: 'the window did not minimize');
      journal.note('minimized');

      await holdWithoutFrames(tester, const Duration(seconds: 75));
      expect(isIconic(), isTrue, reason: 'the window came back on its own');
      journal.note('held minimized');
      final after = await stats.audioCounters();
      journal.note(
        'audio after minimize sent=${after.sent} received=${after.received}',
      );
      expect(after.sent, greaterThan(before.sent));
      expect(after.received, greaterThan(before.received));

      showWindow(minimize: false);
      await settle(tester, const Duration(seconds: 3));
      expect(isIconic(), isFalse);
      expect(
        callScreen,
        findsOneWidget,
        reason: 'the call screen was gone after the window was restored',
      );
      journal.note('restored');

      await settle(tester, const Duration(seconds: 10));
      expect(callScreen, findsOneWidget);
      journal.note('still joined after restore');

      final leave = find.byKey(const Key('call-screen-leave'));
      await waitFor(tester, leave, what: 'the leave button');
      await tester.tap(leave);
      await waitUntilGone(tester, callScreen, what: 'the call screen');
      // Leaving hands the signalling lane its own shutdown, which ends in a
      // database write. The tree - and with it the database - is disposed the
      // moment this test returns, so returning too early turns that write into
      // "Channel was closed before receiving a response" AFTER the test passed.
      await settle(tester, const Duration(seconds: 15));
      journal.note('left');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
