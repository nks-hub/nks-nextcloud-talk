import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_participants_sheet.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';

import 'test_support.dart';

const CallRoomKey _key = (accountId: 'account-a', roomToken: 'rooma123');

final class _FrozenJoinController extends CallJoinController {
  _FrozenJoinController(this.frozen);

  final CallJoinState frozen;

  @override
  CallJoinState build(CallRoomKey arg) => frozen;
}

final class _FakeLocalVideo implements CallLocalVideo {
  @override
  Widget buildPreview(BuildContext context) =>
      const ColoredBox(key: Key('fake-local-video'), color: Colors.blue);

  @override
  Future<void> dispose() async {}
}

final class _FakeRemoteVideo implements CallRemoteVideo {
  @override
  String? get videoTrackId => null;

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: Key('fake-remote-video'), color: Colors.green);

  @override
  Future<void> dispose() async {}
}

CallPeerState _peer({
  required String peerId,
  required String actorId,
  bool connected = true,
  bool handRaised = false,
  bool audioMuted = false,
  DateTime? since,
  CallRemoteVideo? video,
}) => CallPeerState(
  peerId: peerId,
  actorType: 'users',
  actorId: actorId,
  connected: connected,
  handRaised: handRaised,
  audioMuted: audioMuted,
  since: since ?? DateTime.now(),
  video: video,
);

CallJoinState _joined({
  required List<CallPeerState> participants,
  bool muted = false,
  CallLocalVideo? localVideo,
}) => CallJoinState(
  phase: CallJoinPhase.joined,
  media: CallMediaState(
    phase: CallMediaPhase.connected,
    connectedPeers: participants.where((p) => p.connected).length,
    peers: participants.length,
    muted: muted,
    localVideo: localVideo,
    participants: participants,
  ),
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required CallJoinState state,
  Map<String, String> names = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        callJoinControllerProvider.overrideWith(
          () => _FrozenJoinController(state),
        ),
        callParticipantNamesProvider.overrideWith((ref, key) async => names),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCallParticipantsSheet(context, _key),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every participant appears with the caller counted in', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      state: _joined(
        muted: true,
        participants: [
          _peer(peerId: 'peer-a', actorId: 'alice', audioMuted: true),
          _peer(
            peerId: 'peer-b',
            actorId: 'bob',
            connected: false,
            handRaised: true,
          ),
        ],
      ),
      names: {'actor:users:alice': 'Alice Example'},
    );

    expect(find.text('In the call (3)'), findsOneWidget);
    expect(find.byKey(const Key('call-participant-self')), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Muted'), findsAtLeastNWidgets(1));
    // Alice has a display name from the room; Bob falls back to the actor id.
    expect(find.text('Alice Example'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('Audio connected'), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byIcon(Icons.front_hand_rounded), findsOneWidget);
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
  });

  testWidgets(
    'a peer stuck connecting past the timeout reads as not responding',
    (tester) async {
      await _pumpSheet(
        tester,
        state: _joined(
          participants: [
            _peer(
              peerId: 'peer-a',
              actorId: 'alice',
              connected: false,
              since: DateTime.now().subtract(const Duration(seconds: 30)),
            ),
          ],
        ),
      );

      expect(find.text('Not responding'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
    },
  );

  testWidgets('this side\'s own camera preview shows above the peer list', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      state: _joined(participants: const [], localVideo: _FakeLocalVideo()),
    );

    expect(
      find.byKey(const Key('call-participant-self-video')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fake-local-video')), findsOneWidget);
  });

  testWidgets('a peer sharing video or a screen shows it under their tile', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      state: _joined(
        participants: [
          _peer(peerId: 'peer-a', actorId: 'alice', video: _FakeRemoteVideo()),
        ],
      ),
    );

    expect(
      find.byKey(const Key('call-participant-video-peer-a')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fake-remote-video')), findsOneWidget);
  });
}
