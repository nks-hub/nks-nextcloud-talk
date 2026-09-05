import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_participants_sheet.dart';
import 'package:nextcloudtalk/features/calls/call_picture_in_picture.dart';
import 'package:nextcloudtalk/features/calls/call_screen.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';

import 'test_support.dart';

const CallRoomKey _key = (accountId: 'account-a', roomToken: 'rooma123');

/// A joined call frozen in one state: two participants, one sending video and
/// muted, the other still connecting with a hand up.
final class _FrozenJoinController extends CallJoinController {
  _FrozenJoinController(this.frozen);

  final CallJoinState frozen;

  @override
  CallJoinState build(CallRoomKey arg) => frozen;
}

final class _FakeRemoteVideo implements CallRemoteVideo {
  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: Key('fake-remote-video'), color: Colors.green);

  @override
  Future<void> dispose() async {}
}

/// A platform whose window can be entered and left from the test.
final class _FakePictureInPicture implements CallPictureInPicture {
  final modes = StreamController<bool>.broadcast();
  final armed = <bool>[];

  @override
  Future<bool> setAvailable(bool available) async {
    armed.add(available);
    return true;
  }

  @override
  Stream<bool> get active => modes.stream;
}

CallJoinState _joined() => CallJoinState(
  phase: CallJoinPhase.joined,
  media: CallMediaState(
    phase: CallMediaPhase.connected,
    connectedPeers: 1,
    peers: 2,
    muted: true,
    raisedHands: 1,
    participants: [
      CallPeerState(
        peerId: 'peer-a',
        actorType: 'users',
        actorId: 'alice',
        connected: true,
        handRaised: false,
        since: DateTime(2026, 9, 5),
        video: _FakeRemoteVideo(),
        audioMuted: true,
      ),
      CallPeerState(
        peerId: 'peer-b',
        actorType: 'users',
        actorId: 'bob',
        connected: false,
        handRaised: true,
        since: DateTime(2026, 9, 5),
      ),
    ],
  ),
);

Future<_FakePictureInPicture> _pumpCallScreen(WidgetTester tester) async {
  // A phone-sized surface: on the default test window the third tile of
  // the grid is below the fold and is not built at all.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final pictureInPicture = _FakePictureInPicture();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        callJoinControllerProvider.overrideWith(
          () => _FrozenJoinController(_joined()),
        ),
        callParticipantNamesProvider.overrideWith(
          (ref, key) async => {'actor:users:alice': 'Alice Example'},
        ),
        callPictureInPictureProvider.overrideWithValue(pictureInPicture),
      ],
      child: localizedTestApp(home: const CallScreen(roomKey: _key)),
    ),
  );
  await tester.pumpAndSettle();
  return pictureInPicture;
}

void main() {
  testWidgets('the call screen shows one tile per participant and the controls', (
    tester,
  ) async {
    await _pumpCallScreen(tester);

    expect(find.byKey(const Key('call-screen')), findsOneWidget);
    expect(find.byKey(const Key('call-tile-self')), findsOneWidget);
    expect(find.byKey(const Key('call-tile-peer-a')), findsOneWidget);
    expect(find.byKey(const Key('call-tile-peer-b')), findsOneWidget);
    // The name comes from the room's participant list; the id is the fallback.
    expect(find.text('Alice Example'), findsOneWidget);
    expect(find.textContaining('bob'), findsOneWidget);
    // Alice sends video and is muted; Bob's hand is up and he is still connecting.
    expect(find.byKey(const Key('fake-remote-video')), findsOneWidget);
    expect(find.byIcon(Icons.mic_off_rounded), findsAtLeastNWidgets(2));
    expect(find.byIcon(Icons.front_hand_rounded), findsAtLeastNWidgets(1));
    expect(find.textContaining('Connecting'), findsOneWidget);
    // The same controls as the banner, under their own prefix, plus Leave.
    expect(find.byKey(const Key('call-screen-mute')), findsOneWidget);
    expect(find.byKey(const Key('call-screen-camera')), findsOneWidget);
    expect(find.byKey(const Key('call-screen-raise-hand')), findsOneWidget);
    expect(find.byKey(const Key('call-screen-react')), findsOneWidget);
    expect(find.byKey(const Key('call-screen-leave')), findsOneWidget);
  });

  testWidgets('in the small window only the tiles are drawn', (tester) async {
    final pictureInPicture = await _pumpCallScreen(tester);
    // The screen arms the window while it shows.
    expect(pictureInPicture.armed, [true]);

    pictureInPicture.modes.add(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-screen-pip')), findsOneWidget);
    expect(find.byKey(const Key('call-tile-self')), findsOneWidget);
    expect(find.byKey(const Key('call-tile-peer-a')), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(const Key('call-screen-mute')), findsNothing);
    expect(find.byKey(const Key('call-screen-leave')), findsNothing);

    pictureInPicture.modes.add(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-screen')), findsOneWidget);
    expect(find.byKey(const Key('call-screen-leave')), findsOneWidget);

    // Leaving the screen disarms it, so a conversation never shrinks.
    await tester.pumpWidget(const SizedBox());
    expect(pictureInPicture.armed, [true, false]);
  });
}
