import 'dart:async';

import 'package:flutter/foundation.dart';
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
  _FakeRemoteVideo({this.videoTrackId});

  @override
  final String? videoTrackId;

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

  final windowTracks = <String?>[];

  @override
  Future<bool> setAvailable(bool available) async {
    armed.add(available);
    return true;
  }

  @override
  Future<void> setVideoTrack(String? trackId) async =>
      windowTracks.add(trackId);

  @override
  Stream<bool> get active => modes.stream;

}

CallJoinState _joined({
  CallPublishingRights publishing = const CallPublishingRights(),
  String? videoTrackId,
  String? screenTrackId,
  bool canManageRecording = false,
}) => CallJoinState(
  phase: CallJoinPhase.joined,
  publishing: publishing,
  canManageRecording: canManageRecording,
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
        video: _FakeRemoteVideo(videoTrackId: videoTrackId),
        audioMuted: true,
      ),
      CallPeerState(
        peerId: 'peer-b',
        actorType: 'users',
        actorId: 'bob',
        connected: false,
        handRaised: true,
        since: DateTime(2026, 9, 5),
        screen: screenTrackId == null
            ? null
            : _FakeRemoteVideo(videoTrackId: screenTrackId),
      ),
    ],
  ),
);

Future<_FakePictureInPicture> _pumpCallScreen(
  WidgetTester tester, {
  double devicePixelRatio = 1,
  CallPublishingRights publishing = const CallPublishingRights(),
  String? videoTrackId,
  String? screenTrackId,
  bool canManageRecording = false,
}) async {
  // A phone-sized surface: on the default test window the third tile of
  // the grid is below the fold and is not built at all.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);
  final pictureInPicture = _FakePictureInPicture();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        callJoinControllerProvider.overrideWith(
          () => _FrozenJoinController(
            _joined(
              publishing: publishing,
              videoTrackId: videoTrackId,
              screenTrackId: screenTrackId,
              canManageRecording: canManageRecording,
            ),
          ),
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

  testWidgets('the controls fit a real phone, not just a test window', (
    tester,
  ) async {
    // The case above runs at a device pixel ratio of 1, so those 1080 pixels
    // are 1080 LOGICAL points and everything fits with room to spare. A phone
    // of the same pixel width is about 411 points across, and there the six
    // round controls plus a labelled Leave button did not fit: the row simply
    // clipped and the red button ran off the right edge reading "Leave c".
    // Seen on the emulator on 5 September 2026, invisible to every test
    // because of the ratio.
    await _pumpCallScreen(tester, devicePixelRatio: 2.625);

    expect(
      tester.takeException(),
      isNull,
      reason: 'the control bar must not overflow its width',
    );
    // Everything is still there and still reachable, on one line or two.
    for (final key in const <String>[
      'call-screen-mute',
      'call-screen-camera',
      'call-screen-raise-hand',
      'call-screen-react',
      'call-screen-leave',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
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

  testWidgets('a control that the server would refuse is not offered', (
    tester,
  ) async {
    // A moderator can take publishing away (Talk's `publish-video` and
    // `publish-screen`). Offering the buttons anyway is a promise the client
    // cannot keep: the camera really opens on this device and the screen
    // share really walks the user through the system's recording consent,
    // both for media the server will not carry.
    await _pumpCallScreen(
      tester,
      publishing: const CallPublishingRights(video: false, screen: false),
    );

    expect(find.byKey(const Key('call-screen-camera')), findsNothing);
    expect(find.byKey(const Key('call-screen-share-screen')), findsNothing);
    expect(
      find.byKey(const Key('call-screen-mute')),
      findsOneWidget,
      reason: 'audio was not taken away, so the microphone stays',
    );
    expect(find.byKey(const Key('call-screen-leave')), findsOneWidget);
  });

  testWidgets('every control fits across a phone, recording and all', (
    tester,
  ) async {
    // MEASURED ON A PHYSICAL 1080x2220 PHONE, 7 September 2026: the control
    // strip ran 23 physical pixels off the right edge — a debug build drew the
    // yellow-and-black bar over it, a release build simply cut it off. Adding
    // the recording button took the row from six controls to seven, and a Row
    // clips rather than breaks; it is a Wrap now.
    // WHAT THIS TEST DOES AND DOES NOT PROVE: it pins that seven controls and
    // a leave button lay out without overflowing at 411 dp. It is NOT where
    // the reported 23 pixels came from — that was the BANNER's row, which had
    // no test at all and is pinned now by `the joined banner controls fit
    // across a phone` in `call_banner_test.dart`. This screen wraps and always
    // did; the banner did not.
    // The pump helper sets the surface itself, so the density goes through it:
    // 1080 physical pixels at 2.625 is the 411 dp the phone actually reports.
    // Passing the size here instead would be silently overwritten, and the
    // test would pass at 1080 logical pixels where everything fits.
    await _pumpCallScreen(
      tester,
      devicePixelRatio: 2.625,
      publishing: const CallPublishingRights(video: true, screen: true),
      canManageRecording: true,
    );

    expect(find.byKey(const Key('call-screen-share-screen')), findsOneWidget);
    expect(find.byKey(const Key('call-screen-leave')), findsOneWidget);
    // `takeException` is how an overflow reaches a test: `RenderFlex` reports
    // it through the error reporter rather than by throwing at the call site.
    expect(
      tester.takeException(),
      isNull,
      reason: 'nothing may run off the edge of the phone',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the desktops are offered the screen share too', (tester) async {
    // FOUND BY READING THE CODE AGAINST THE CALL MATRIX, 7 September 2026: the
    // button was gated to Android and iOS, so on Windows and macOS it was not
    // drawn at all — four cells of the matrix could not be filled, and the
    // matrix said the gap was the rig's. It is not: `openScreen` goes through
    // `getDisplayMedia`, which the engine offers on every platform it runs
    // on, and `requestScreenConsent` already handles the macOS prompt.
    // What still gates the button is the server's `publish-screen`, which is
    // the right gate and is covered by the test above.
    for (final platform in const [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await _pumpCallScreen(tester);
      expect(
        find.byKey(const Key('call-screen-share-screen')),
        findsOneWidget,
        reason: '$platform can capture a screen',
      );
      // A desktop has one audio output to speak of, so the phone's
      // speaker/earpiece toggle stays away.
      expect(find.byKey(const Key('call-screen-speaker')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the window is told which video to draw', (tester) async {
    final platform = await _pumpCallScreen(tester, videoTrackId: 'track-cam');
    expect(platform.windowTracks, ['track-cam']);
  });

  testWidgets('a shared screen goes into the window before a camera', (
    tester,
  ) async {
    final platform = await _pumpCallScreen(
      tester,
      videoTrackId: 'track-cam',
      screenTrackId: 'track-screen',
    );
    expect(
      platform.windowTracks,
      ['track-screen'],
      reason: 'a shared screen is what the small window is opened for',
    );
  });

  testWidgets('a call with no video names no track', (tester) async {
    final platform = await _pumpCallScreen(tester);
    expect(
      platform.windowTracks,
      isEmpty,
      reason: 'no video to draw is not a change worth a platform call',
    );
  });
}
