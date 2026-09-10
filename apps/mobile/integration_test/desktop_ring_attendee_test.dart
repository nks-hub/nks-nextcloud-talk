@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';

import 'desktop_app_support.dart';

/// Rings one absent participant from a real call, so a second device can be
/// watched for what it does about it.
///
/// The service and its tests already prove the request is sent and refused in
/// the right places. What no test can show is the other end: whether a phone
/// that is a member of the room, not in the call, is told to ring at all. This
/// drives the same control a person would - the participant sheet behind the
/// chat's call banner - and then holds the call open long enough to look at
/// the device.
///
/// `NKS_CALL_ROOM` names the room, `NKS_RING_ATTENDEE` the participant to ring.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final roomToken = Platform.environment['NKS_CALL_ROOM'];
  final attendee = Platform.environment['NKS_RING_ATTENDEE'];
  final journal = DesktopJournal(Platform.environment['NKS_CALL_JOURNAL']);

  testWidgets('an absent participant can be rung from a joined call', (
    tester,
  ) async {
    expect(roomToken, isNotNull, reason: 'set NKS_CALL_ROOM');
    expect(attendee, isNotNull, reason: 'set NKS_RING_ATTENDEE');
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

    // The ring lives in the participant sheet, and the sheet opens from the
    // chat's own call banner - so the call VIEW has to go away first while the
    // call itself stays up.
    final navigator = Navigator.of(tester.element(callScreen));
    navigator.pop();
    await settle(tester, const Duration(seconds: 2));

    final banner = find.byKey(const Key('call-banner-participants'));
    await waitFor(tester, banner, what: 'the call banner');
    await tester.tap(banner);
    await settle(tester, const Duration(seconds: 2));
    journal.note('participant sheet open');

    final ring = find.byKey(Key('call-ring-button-$attendee'));
    await waitFor(
      tester,
      ring,
      what: 'the ring button for attendee $attendee',
      timeout: const Duration(seconds: 20),
    );
    await tester.tap(ring);
    await settle(tester, const Duration(seconds: 3));
    journal.note('rang $attendee');

    // Long enough to look at the other device.
    await settle(tester, const Duration(seconds: 45));
    journal.note('held after ringing');

    // The same control joins and leaves; in a joined call it leaves.
    await tester.tap(find.byKey(const Key('call-banner-join')));
    await settle(tester, const Duration(seconds: 15));
    journal.note('left');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
