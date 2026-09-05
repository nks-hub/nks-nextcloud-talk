import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_audio_interruptions.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_signaling_session.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// The mesh offerer role is decided by the ordered pair of session ids, so the
/// fixtures deliberately sit on both sides of `alice`.
const _local = 'zulu-session';
const _remote = 'alice-session';

void main() {
  late _FakeEngine engine;
  late StreamController<CallSignalingUpdate> updates;
  late List<SignalingPeerMessage> sent;
  late List<HpbControlMessage> controls;

  setUp(() {
    engine = _FakeEngine();
    updates = StreamController<CallSignalingUpdate>.broadcast(sync: true);
    sent = <SignalingPeerMessage>[];
    controls = <HpbControlMessage>[];
  });

  tearDown(() => updates.close());

  CallMediaSession session(
    CallSignalingUpdate initial, {
    bool withControl = false,
  }) => CallMediaSession(
    initial: initial,
    updates: updates.stream,
    sendMessage: (message) async {
      sent.add(message);
      return true;
    },
    sendControl: withControl
        ? (control) async {
            controls.add(control);
            return true;
          }
        : null,
    engine: engine,
  );

  test(
    'the higher session id offers, takes the answer and trades ICE',
    () async {
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
      );
      addTearDown(media.dispose);
      await media.start();

      expect(engine.microphoneOpens, 1);
      expect(engine.connections, hasLength(1));
      final connection = engine.connections.single;
      expect(connection.createdOffers, 1);
      expect(connection.localDescriptions.single.type, 'offer');

      final offer = sent.singleWhere((message) => message.type == 'offer');
      expect(offer.type, 'offer');
      expect(offer.roomType, 'video');
      expect(offer.recipient?.value, _remote);
      expect(offer.payload?.wire['type'], 'offer');
      expect(offer.payload?.wire['sdp'], 'sdp-offer-1');

      // A candidate that overtakes the answer must not be dropped.
      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(_remote, 'candidate', <String, Object?>{
              'candidate': <String, Object?>{
                'candidate': 'candidate:early',
                'sdpMid': 'audio',
                'sdpMLineIndex': 0,
              },
            }),
          ],
        ),
      );
      await pumpEventQueue();
      expect(connection.remoteCandidates, isEmpty);

      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(_remote, 'answer', <String, Object?>{
              'type': 'answer',
              'sdp': 'sdp-answer-remote',
            }),
          ],
        ),
      );
      await pumpEventQueue();
      expect(connection.remoteDescriptions.single.type, 'answer');
      expect(connection.remoteDescriptions.single.sdp, 'sdp-answer-remote');
      expect(
        connection.remoteCandidates.map((candidate) => candidate.candidate),
        ['candidate:early'],
      );

      // A local candidate leaves as its own signalling message.
      connection.emitIceCandidate(
        const CallIceCandidate(
          candidate: 'candidate:local',
          sdpMid: 'audio',
          sdpMLineIndex: 0,
        ),
      );
      await pumpEventQueue();
      final candidate = sent.last;
      expect(candidate.type, 'candidate');
      expect(candidate.recipient?.value, _remote);
      final wire =
          candidate.payload?.wire['candidate']! as Map<String, Object?>;
      expect(wire['candidate'], 'candidate:local');
      expect(wire['sdpMid'], 'audio');
      expect(wire['sdpMLineIndex'], 0);

      connection.emitConnectionState(CallMediaConnectionState.connected);
      await pumpEventQueue();
      expect(media.state.phase, CallMediaPhase.connected);
      expect(media.state.connectedPeers, 1);
    },
  );

  test('the lower session id waits for the offer and answers it', () async {
    // Reversed roles: this client is `alice`, the peer is `zulu`.
    final media = session(
      _update(localPeerId: _remote, participants: [_participant(_local)]),
    );
    addTearDown(media.dispose);
    await media.start();

    expect(engine.connections, hasLength(1));
    expect(engine.connections.single.createdOffers, 0);
    expect(
      sent.where((message) => message.type == 'offer'),
      isEmpty,
      reason: 'the other side owns the offer',
    );

    updates.add(
      _update(
        localPeerId: _remote,
        participants: [_participant(_local)],
        messages: [
          _message(_local, 'offer', <String, Object?>{
            'type': 'offer',
            'sdp': 'sdp-offer-remote',
          }),
        ],
      ),
    );
    await pumpEventQueue();

    final connection = engine.connections.single;
    expect(connection.remoteDescriptions.single.sdp, 'sdp-offer-remote');
    expect(connection.createdAnswers, 1);
    final answer = sent.singleWhere((message) => message.type == 'answer');
    expect(answer.payload?.wire['sdp'], 'sdp-answer-1');
  });

  test('losing the signalling session closes the peer connection', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    expect(engine.connections.single.closed, isFalse);

    await updates.close();
    await pumpEventQueue();

    expect(engine.connections.single.closed, isTrue);
    expect(engine.audio.single.disposed, isTrue);
    expect(media.state.phase, CallMediaPhase.failed);
    expect(media.state.error, CallMediaError.signalingLost);
  });

  test('a peer that leaves the call loses its connection', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    expect(engine.connections, hasLength(1));

    updates.add(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote, inCall: 0)],
      ),
    );
    await pumpEventQueue();

    expect(engine.connections.single.closed, isTrue);
    expect(media.state.peers, 0);
  });

  test('an MCU room is refused without asking for the microphone', () async {
    final media = session(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        topology: SignalingTopology.externalMcu,
      ),
    );
    addTearDown(media.dispose);
    await media.start();

    expect(engine.microphoneOpens, 0);
    expect(engine.connections, isEmpty);
    expect(media.state.error, CallMediaError.topologyUnsupported);
  });

  test('a refused microphone stops before any peer connection', () async {
    engine.microphoneError = CallMediaError.microphonePermissionDenied;
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();

    expect(engine.connections, isEmpty);
    expect(
      sent.where(
        (message) => message.type != 'mute' && message.type != 'unmute',
      ),
      isEmpty,
    );
    expect(media.state.phase, CallMediaPhase.failed);
    expect(media.state.error, CallMediaError.microphonePermissionDenied);
  });

  test('signalling that is not ready yet builds nothing', () async {
    final media = session(
      _update(
        localPeerId: null,
        participants: [_participant(_remote)],
        phase: SignalingAccountPhase.fetchingSettings,
        roomConfirmed: false,
      ),
    );
    addTearDown(media.dispose);
    await media.start();

    expect(engine.connections, isEmpty);
    expect(media.state.phase, CallMediaPhase.preparing);
  });

  test('a required renegotiation stops media instead of pretending', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    expect(engine.connections, hasLength(1));

    updates.add(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        renegotiationRequired: true,
      ),
    );
    await pumpEventQueue();

    expect(engine.connections.single.closed, isTrue);
    expect(media.state.error, CallMediaError.signalingLost);
  });

  // Measured on 5 September 2026: with a connected call, an incoming telephone
  // call made Android report AUDIOFOCUS_LOSS_TRANSIENT and the WebRTC audio
  // carried on — the microphone kept capturing while the phone rang and the
  // other participants kept hearing the room. The call now hands the
  // microphone back for the length of the interruption and takes it again
  // afterwards, without closing the track: closing it would force a
  // renegotiation with every peer for something that lasts seconds.
  test('the speaker control reaches the audio route and the state', () async {
    final media = CallMediaSession(
      initial: _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
      ),
      updates: updates.stream,
      sendMessage: (message) async {
        sent.add(message);
        return true;
      },
      engine: engine,
    );
    addTearDown(media.dispose);
    await media.start();
    final audio = engine.audio.single;
    expect(
      media.state.speakerphone,
      isFalse,
      reason: 'a call starts on the earpiece',
    );
    expect(
      audio.speakerphoneCalls,
      <bool>[false],
      reason: 'the route is set at the start, not left to the plugin',
    );

    await media.setSpeakerphone(true);
    expect(audio.speakerphone, isTrue);
    expect(media.state.speakerphone, isTrue);

    await media.setSpeakerphone(false);
    expect(audio.speakerphone, isFalse);
    expect(media.state.speakerphone, isFalse);
  });

  // The wire form is the web client's: one `raiseHand` message per peer with
  // `{state, timestamp}`, and a hand is a fact about a peer that leaves with it.
  test(
    'raising a hand tells every peer and a remote hand is counted',
    () async {
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
      );
      addTearDown(media.dispose);
      await media.start();
      sent.clear();

      await media.setHandRaised(true);
      final raise = sent.single;
      expect(raise.type, 'raiseHand');
      expect(raise.recipient?.value, _remote);
      expect(raise.payload?.wire['state'], isTrue);
      expect(raise.payload?.wire['timestamp'], isA<int>());
      expect(media.state.handRaised, isTrue);
      expect(media.state.raisedHands, 0, reason: 'our own hand is not counted');

      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(_remote, 'raiseHand', <String, Object?>{
              'state': true,
              'timestamp': 1,
            }),
          ],
        ),
      );
      await pumpEventQueue();
      expect(media.state.raisedHands, 1);

      await media.setHandRaised(false);
      expect(sent.last.payload?.wire['state'], isFalse);
      expect(media.state.handRaised, isFalse);

      // The remote participant leaves the call: the hand goes with them.
      updates.add(_update(localPeerId: _local, participants: []));
      await pumpEventQueue();
      expect(media.state.raisedHands, 0);
    },
  );

  // A reaction is a gesture: sent to every peer, shown for a moment when it
  // arrives, and gone again without anyone having to dismiss it.
  test(
    'a reaction reaches every peer and an incoming one shows briefly',
    () async {
      final media = CallMediaSession(
        initial: _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
        ),
        updates: updates.stream,
        sendMessage: (message) async {
          sent.add(message);
          return true;
        },
        engine: engine,
        reactionDisplay: const Duration(milliseconds: 20),
      );
      addTearDown(media.dispose);
      await media.start();
      sent.clear();

      await media.sendReaction('👍');
      expect(sent.single.type, 'reaction');
      expect(sent.single.recipient?.value, _remote);
      expect(sent.single.payload?.wire['reaction'], '👍');
      expect(media.state.reaction, isNull, reason: 'our own is for the others');

      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(_remote, 'reaction', <String, Object?>{'reaction': '🎉'}),
          ],
        ),
      );
      await pumpEventQueue();
      expect(media.state.reaction?.emoji, '🎉');
      expect(media.state.reaction?.peerId, _remote);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(media.state.reaction, isNull, reason: 'it clears on its own');
    },
  );

  test('a failed transport is offered again with an ICE restart', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    final connection = engine.connections.single;
    connection.emitConnectionState(CallMediaConnectionState.connected);
    await pumpEventQueue();
    final sid = sent.firstWhere((message) => message.type == 'offer').sid;
    expect(connection.iceRestarts, 0);

    connection.emitConnectionState(CallMediaConnectionState.failed);
    await pumpEventQueue();
    // One restart on the SAME connection and sid — the web client answers a
    // re-offer, a fresh sid would have opened a second connection there.
    expect(connection.iceRestarts, 1);
    expect(engine.connections, hasLength(1));
    final offers = sent.where((message) => message.type == 'offer').toList();
    expect(offers, hasLength(2));
    expect(offers.last.sid, sid);
    expect(media.state.participants.single.connected, isFalse);

    // Staying failed is not a new failure; recovering and failing again is.
    connection.emitConnectionState(CallMediaConnectionState.failed);
    await pumpEventQueue();
    expect(connection.iceRestarts, 1);
    connection.emitConnectionState(CallMediaConnectionState.connecting);
    connection.emitConnectionState(CallMediaConnectionState.failed);
    await pumpEventQueue();
    expect(connection.iceRestarts, 2);
  });

  test('sharing this screen opens a send-only connection per peer', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    expect(engine.connections, hasLength(1));

    await media.setScreenSharing(true);
    await pumpEventQueue();
    expect(engine.screens, hasLength(1));
    expect(media.state.screenSharing, isTrue);
    // A second connection to the same peer, carrying the screen and no
    // microphone, offered under its own room type and sid.
    expect(engine.connections, hasLength(2));
    final share = engine.connections.last;
    expect(share.audio, isNull);
    expect(share.video, same(engine.screens.single));
    final offer = sent.lastWhere((message) => message.type == 'offer');
    expect(offer.roomType, 'screen');
    expect(offer.sid, isNotNull);
    expect(offer.sid, isNot(sent.first.sid));
    // Whose screen it is — without this the web takes the offer as a request
    // to share ITS screen and draws nothing.
    expect(offer.broadcaster, _local);
    expect(sent.first.broadcaster, isNull);

    // The answer comes back on that sid and settles the share, not the call.
    updates.add(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        messages: [
          _message(
            _remote,
            'answer',
            <String, Object?>{'type': 'answer', 'sdp': 'share-answer'},
            sid: offer.sid,
            roomType: 'screen',
          ),
        ],
      ),
    );
    await pumpEventQueue();
    expect(share.remoteDescriptions.single.sdp, 'share-answer');

    await media.setScreenSharing(false);
    await pumpEventQueue();
    // The web client's own goodbye: no payload, on the share's room type.
    final goodbye = sent.lastWhere(
      (message) => message.type == 'unshareScreen',
    );
    expect(goodbye.roomType, 'screen');
    expect(goodbye.payload, isNull);
    expect(share.closed, isTrue);
    expect(engine.screens.single.disposed, isTrue);
    expect(media.state.screenSharing, isFalse);
    expect(engine.connections.first.closed, isFalse);
  });

  test('a screen that will not open leaves the call alone', () async {
    engine.screenError = CallMediaError.screenSharePermissionDenied;
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();

    await media.setScreenSharing(true);
    await pumpEventQueue();
    expect(media.state.screenSharing, isFalse);
    expect(engine.connections, hasLength(1));
    expect(media.state.phase, isNot(CallMediaPhase.failed));
  });

  test(
    'the outputs the platform lists are offered and one can be picked',
    () async {
      const speaker = CallAudioRoute(
        id: 'speaker',
        label: 'Speaker',
        kind: CallAudioRouteKind.speaker,
      );
      const earpiece = CallAudioRoute(
        id: 'earpiece',
        label: 'Earpiece',
        kind: CallAudioRouteKind.earpiece,
      );
      const headset = CallAudioRoute(
        id: 'bluetooth',
        label: 'WH-1000',
        kind: CallAudioRouteKind.bluetooth,
      );
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
      );
      addTearDown(media.dispose);
      await media.start();
      final audio = engine.audio.single;
      expect(media.state.audioRoutes, isEmpty);

      // A headset connects: the platform says "devices changed" and the list
      // is asked for again.
      audio.availableRoutes = const [speaker, earpiece, headset];
      audio.routeChangeController.add(null);
      await pumpEventQueue();
      expect(media.state.audioRoutes.map((route) => route.id), [
        'speaker',
        'earpiece',
        'bluetooth',
      ]);
      expect(media.state.audioRoute, isNull);

      await media.selectAudioRoute(headset);
      await pumpEventQueue();
      expect(audio.selectedRoutes.single.id, 'bluetooth');
      expect(media.state.audioRoute?.id, 'bluetooth');
      expect(media.state.speakerphone, isFalse);

      // Picking the loudspeaker through the list is the same as the toggle.
      await media.selectAudioRoute(speaker);
      await pumpEventQueue();
      expect(media.state.speakerphone, isTrue);

      // The headset goes away: the pick is forgotten, nothing else changes.
      await media.selectAudioRoute(headset);
      audio.availableRoutes = const [speaker, earpiece];
      audio.routeChangeController.add(null);
      await pumpEventQueue();
      expect(media.state.audioRoutes, hasLength(2));
      expect(media.state.audioRoute, isNull);
    },
  );

  test(
    'through an MCU this side publishes once and subscribes per participant',
    () async {
      final media = session(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          topology: SignalingTopology.externalMcu,
        ),
        withControl: true,
      );
      addTearDown(media.dispose);
      await media.start();

      // One publisher: the microphone on a send-only connection, offered to
      // this side's OWN session id, and no connection to the participant yet.
      expect(engine.connections, hasLength(1));
      final publisher = engine.connections.single;
      expect(publisher.audio, isNotNull);
      expect(publisher.sendOnly, isTrue);
      final offer = sent.singleWhere((message) => message.type == 'offer');
      expect(offer.recipient?.value, _local);
      expect(offer.roomType, 'video');
      final publisherSid = offer.sid;
      expect(publisherSid, isNotNull);
      // The participant is asked for through the server, not offered to.
      expect(controls, hasLength(1));
      expect(controls.single.recipient?.value, _remote);
      expect(controls.single.data.wire, {
        'type': 'requestoffer',
        'roomType': 'video',
      });
      expect(media.state.participants.single.connected, isFalse);

      // The server answers the publisher from this side's own session id.
      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          topology: SignalingTopology.externalMcu,
          messages: [
            _message(_local, 'answer', <String, Object?>{
              'type': 'answer',
              'sdp': 'mcu-answer',
            }, sid: publisherSid),
          ],
        ),
      );
      await pumpEventQueue();
      expect(publisher.remoteDescriptions.single.sdp, 'mcu-answer');

      // The MCU offers the participant's stream from THEIR session id: a
      // listening connection of its own, answered back to them.
      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          topology: SignalingTopology.externalMcu,
          messages: [
            _message(_remote, 'offer', <String, Object?>{
              'type': 'offer',
              'sdp': 'remote-publisher',
            }, sid: 'mcu-remote'),
          ],
        ),
      );
      await pumpEventQueue();
      expect(engine.connections, hasLength(2));
      final subscriber = engine.connections.last;
      expect(subscriber.audio, isNull);
      expect(subscriber.remoteDescriptions.single.sdp, 'remote-publisher');
      final answer = sent.lastWhere((message) => message.type == 'answer');
      expect(answer.recipient?.value, _remote);
      expect(answer.sid, 'mcu-remote');

      subscriber.emitConnectionState(CallMediaConnectionState.connected);
      await pumpEventQueue();
      expect(media.state.participants.single.connected, isTrue);
      expect(media.state.phase, CallMediaPhase.connected);
    },
  );

  test('an MCU without a control channel is still refused', () async {
    final media = session(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        topology: SignalingTopology.externalMcu,
      ),
    );
    addTearDown(media.dispose);
    await media.start();
    expect(media.state.phase, CallMediaPhase.failed);
    expect(media.state.error, CallMediaError.topologyUnsupported);
    expect(engine.microphoneOpens, 0);
  });

  test('a shared screen is a second, receive-only connection', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    expect(engine.connections, hasLength(1));

    updates.add(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        messages: [
          _message(
            _remote,
            'offer',
            <String, Object?>{'type': 'offer', 'sdp': 'screen-offer'},
            sid: 'screen-sid',
            roomType: 'screen',
          ),
          _message(
            _remote,
            'candidate',
            <String, Object?>{
              'candidate': <String, Object?>{
                'candidate': 'candidate:screen',
                'sdpMid': '0',
                'sdpMLineIndex': 0,
              },
            },
            sid: 'screen-sid',
            roomType: 'screen',
          ),
        ],
      ),
    );
    await pumpEventQueue();
    expect(engine.connections, hasLength(2));
    final screen = engine.connections.last;
    // Nothing of ours travels on it, and it stays out of the call's own
    // connection.
    expect(screen.audio, isNull);
    expect(engine.connections.first.remoteDescriptions, isEmpty);
    expect(screen.remoteDescriptions.single.sdp, 'screen-offer');
    expect(screen.remoteCandidates.single.candidate, 'candidate:screen');
    final answer = sent.lastWhere((message) => message.type == 'answer');
    expect(answer.roomType, 'screen');
    expect(answer.sid, 'screen-sid');

    final video = _FakeRemoteVideo();
    screen.onRemoteVideo(video);
    await pumpEventQueue();
    expect(media.state.participants.single.screen, same(video));
    expect(media.state.participants.single.video, isNull);

    updates.add(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        messages: [_message(_remote, 'unshareScreen', <String, Object?>{})],
      ),
    );
    await pumpEventQueue();
    expect(media.state.participants.single.screen, isNull);
    expect(screen.closed, isTrue);
    expect(video.disposed, isTrue);
    expect(engine.connections.first.closed, isFalse);
  });

  test('the state lists every peer with its connection and hand', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    expect(media.state.participants.map((peer) => peer.peerId), [_remote]);
    expect(media.state.participants.single.connected, isFalse);

    engine.connections.single.onConnectionState(
      CallMediaConnectionState.connected,
    );
    await pumpEventQueue();
    expect(media.state.participants.single.connected, isTrue);

    updates.add(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        messages: [
          _message(_remote, 'raiseHand', <String, Object?>{
            'state': true,
            'timestamp': 1,
          }),
        ],
      ),
    );
    await pumpEventQueue();
    expect(media.state.participants.single.handRaised, isTrue);

    updates.add(_update(localPeerId: _local, participants: []));
    await pumpEventQueue();
    expect(media.state.participants, isEmpty);
  });

  // Every connection offers to receive video; a peer that sends it shows up
  // as a renderer on their entry and is disposed with the peer.
  test('a remote video is exposed per peer and disposed with it', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    final connection = engine.connections.single;

    final video = _FakeRemoteVideo();
    connection.onRemoteVideo(video);
    await pumpEventQueue();
    expect(media.state.participants.single.video, same(video));

    final replacement = _FakeRemoteVideo();
    connection.onRemoteVideo(replacement);
    await pumpEventQueue();
    expect(video.disposed, isTrue, reason: 'the old renderer is released');
    expect(media.state.participants.single.video, same(replacement));

    updates.add(_update(localPeerId: _local, participants: []));
    await pumpEventQueue();
    expect(replacement.disposed, isTrue, reason: 'gone with the peer');
    expect(media.state.participants, isEmpty);
  });

  // A track added after the first negotiation is not on the wire until the
  // peer answers again, so the camera swaps the track and offers anew — on
  // every connection, both ways.
  test(
    'turning the camera on renegotiates with every peer and off again',
    () async {
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
      );
      addTearDown(media.dispose);
      await media.start();
      final connection = engine.connections.single;
      expect(sent.where((message) => message.type == 'offer'), hasLength(1));
      expect(media.state.cameraOn, isFalse);
      // The first offer is answered, as in a live call; only then is a
      // renegotiation offer allowed out (the glare guard).
      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(_remote, 'answer', <String, Object?>{
              'type': 'answer',
              'sdp': 'sdp-answer-remote',
            }),
          ],
        ),
      );
      await pumpEventQueue();
      expect(connection.remoteDescriptions, hasLength(1));

      await media.setCameraEnabled(true);
      final camera = engine.cameras.single;
      expect(connection.localVideos, [same(camera)]);
      expect(sent.where((message) => message.type == 'offer'), hasLength(2));
      expect(media.state.cameraOn, isTrue);
      expect(media.state.localVideo, same(camera));

      // The renegotiation offer is still unanswered: a second toggle must not
      // pile a third offer on it, but the track still goes.
      await media.setCameraEnabled(false);
      expect(connection.localVideos.last, isNull);
      expect(sent.where((message) => message.type == 'offer'), hasLength(2));
      expect(camera.disposed, isTrue);
      expect(media.state.cameraOn, isFalse);
    },
  );

  test('a camera that cannot be opened leaves the call audio-only', () async {
    engine.cameraError = CallMediaError.cameraPermissionDenied;
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    await media.setCameraEnabled(true);
    expect(media.state.cameraOn, isFalse);
    expect(media.state.phase, isNot(CallMediaPhase.failed));
    expect(sent.where((message) => message.type == 'offer'), hasLength(1));
  });

  // The web client shows a peer as muted and camera-off until told otherwise,
  // so this side announces both on arrival and on every change.
  test('the media state is announced to peers as mute and unmute', () async {
    final media = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(media.dispose);
    await media.start();
    List<String> announced() => [
      for (final message in sent)
        if (message.type == 'mute' || message.type == 'unmute')
          '${message.type} ${message.payload?.wire['name']}',
    ];
    expect(announced(), ['unmute audio', 'mute video']);

    await media.setMicrophoneMuted(true);
    expect(announced().sublist(announced().length - 2), [
      'mute audio',
      'mute video',
    ]);

    updates.add(
      _update(
        localPeerId: _local,
        participants: [_participant(_remote)],
        messages: [
          _message(_remote, 'answer', <String, Object?>{
            'type': 'answer',
            'sdp': 'sdp-answer-remote',
          }),
        ],
      ),
    );
    await pumpEventQueue();
    await media.setCameraEnabled(true);
    expect(announced().sublist(announced().length - 2), [
      'mute audio',
      'unmute video',
    ]);
  });

  // The web client keys a peer connection by `sid`; a message with a foreign
  // or missing one opens a new connection or is dropped.
  test('every message to a peer carries the sid of its connection', () async {
    // The remote offers first (its id sorts lower): its sid is adopted.
    final media = session(
      _update(localPeerId: _remote, participants: [_participant(_local)]),
    );
    addTearDown(media.dispose);
    await media.start();
    sent.clear();
    updates.add(
      _update(
        localPeerId: _remote,
        participants: [_participant(_local)],
        messages: [
          _message(_local, 'offer', <String, Object?>{
            'type': 'offer',
            'sdp': 'sdp-offer-1',
          }, sid: 'web-sid-42'),
        ],
      ),
    );
    await pumpEventQueue();
    expect(sent.map((message) => message.type), contains('answer'));
    expect(sent.map((message) => message.sid).toSet(), {'web-sid-42'});

    // This side offers first: it names a sid and keeps using it.
    sent.clear();
    final offering = session(
      _update(localPeerId: _local, participants: [_participant(_remote)]),
    );
    addTearDown(offering.dispose);
    await offering.start();
    final sids = sent.map((message) => message.sid).toSet();
    expect(sids, hasLength(1));
    expect(sids.single, isNotNull);
    expect(sids.single, isNotEmpty);
  });

  // A peer that offers to us while our camera is on gets it in the answer,
  // not at the next toggle.
  test('an incoming offer is answered with the camera already on', () async {
    final media = session(_update(localPeerId: _remote, participants: []));
    addTearDown(media.dispose);
    await media.start();
    await media.setCameraEnabled(true);
    final camera = engine.cameras.single;

    updates.add(
      _update(
        localPeerId: _remote,
        participants: [_participant(_local)],
        messages: [
          _message(_local, 'offer', <String, Object?>{
            'type': 'offer',
            'sdp': 'sdp-offer-1',
          }, sid: 'web-sid-7'),
        ],
      ),
    );
    await pumpEventQueue();
    final connection = engine.connections.single;
    expect(connection.localVideos, [same(camera)]);
    expect(connection.createdAnswers, 1);
  });

  test(
    "a peer's mute and unmute of its microphone show on its entry",
    () async {
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
      );
      addTearDown(media.dispose);
      await media.start();
      expect(media.state.participants.single.audioMuted, isFalse);
      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(_remote, 'mute', <String, Object?>{'name': 'audio'}),
          ],
        ),
      );
      await pumpEventQueue();
      expect(media.state.participants.single.audioMuted, isTrue);
      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(_remote, 'unmute', <String, Object?>{'name': 'audio'}),
          ],
        ),
      );
      await pumpEventQueue();
      expect(media.state.participants.single.audioMuted, isFalse);
    },
  );

  test(
    'an interruption mutes the microphone and giving it back unmutes',
    () async {
      final interruptions = StreamController<CallAudioInterruption>.broadcast();
      addTearDown(interruptions.close);
      final media = CallMediaSession(
        initial: _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
        ),
        updates: updates.stream,
        sendMessage: (message) async {
          sent.add(message);
          return true;
        },
        engine: engine,
        interruptions: _FakeInterruptions(interruptions.stream),
      );
      addTearDown(media.dispose);

      await media.start();
      final audio = engine.audio.single;
      expect(audio.muted, isFalse, reason: 'a call starts unmuted');

      interruptions.add(CallAudioInterruption.began);
      await pumpEventQueue();
      expect(audio.muted, isTrue, reason: 'the system took the audio away');
      expect(audio.disposed, isFalse, reason: 'the track has to survive it');

      interruptions.add(CallAudioInterruption.ended);
      await pumpEventQueue();
      expect(
        audio.muted,
        isFalse,
        reason: 'the audio belongs to the call again',
      );
      expect(audio.muteCalls, <bool>[true, false]);
    },
  );

  // The user's mute and the system's interruption both close the microphone,
  // and lifting one must not lift the other: a microphone the user closed
  // stays closed when the telephone call ends.
  test(
    'the end of an interruption does not unmute a user-muted microphone',
    () async {
      final interruptions = StreamController<CallAudioInterruption>.broadcast();
      addTearDown(interruptions.close);
      final media = CallMediaSession(
        initial: _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
        ),
        updates: updates.stream,
        sendMessage: (message) async {
          sent.add(message);
          return true;
        },
        engine: engine,
        interruptions: _FakeInterruptions(interruptions.stream),
      );
      addTearDown(media.dispose);
      await media.start();
      final audio = engine.audio.single;

      await media.setMicrophoneMuted(true);
      expect(audio.muted, isTrue);
      expect(media.state.muted, isTrue, reason: 'the control shows the choice');

      interruptions.add(CallAudioInterruption.began);
      await pumpEventQueue();
      interruptions.add(CallAudioInterruption.ended);
      await pumpEventQueue();
      expect(audio.muted, isTrue, reason: 'the user did not unmute');
      expect(media.state.muted, isTrue);

      await media.setMicrophoneMuted(false);
      expect(audio.muted, isFalse);
      expect(media.state.muted, isFalse);
    },
  );
}

CallSignalingUpdate _update({
  required String? localPeerId,
  List<SignalingParticipant> participants = const [],
  List<SignalingPeerMessage> messages = const [],
  SignalingTopology topology = SignalingTopology.externalPeerToPeer,
  SignalingAccountPhase phase = SignalingAccountPhase.signalingReady,
  bool roomConfirmed = true,
  bool renegotiationRequired = false,
}) => CallSignalingUpdate(
  key: const (accountId: 'account-a', roomToken: 'rooma123'),
  outcome: SignalingRuntimeOutcome.unchanged,
  phase: phase,
  transport: SignalingTransportKind.externalHpb,
  topology: topology,
  participants: participants,
  roomConfirmed: roomConfirmed,
  federationInterrupted: false,
  renegotiationRequired: renegotiationRequired,
  messages: messages,
  controls: const <HpbControlMessage>[],
  chatRelay: null,
  roomEpoch: 1,
  chatRelaySupported: false,
  localPeerId: localPeerId == null ? null : SignalingPeerId.parse(localPeerId),
  iceServers: <IceServerConfiguration>[
    IceServerConfiguration(
      urls: const ['stun:stun.example.invalid:19302'],
      username: null,
      credential: null,
    ),
  ],
  failure: null,
);

SignalingParticipant _participant(String peerId, {int inCall = 7}) =>
    SignalingParticipant(
      peerId: SignalingPeerId.parse(peerId),
      nextcloudSessionId: null,
      userId: 'user-$peerId',
      inCall: inCall,
      permissions: 255,
      actorType: 'users',
      actorId: 'user-$peerId',
      federated: false,
      features: const <String>[],
    );

SignalingPeerMessage _message(
  String sender,
  String type,
  Map<String, Object?> payload, {
  String? sid,
  String roomType = 'video',
}) => SignalingPeerMessage(
  type: type,
  roomType: roomType,
  sid: sid,
  recipient: SignalingPeerId.parse(_local),
  sender: SignalingPeerId.parse(sender),
  payload: SignalingOpaquePayload.fromJson(payload),
);

final class _FakeInterruptions implements CallAudioInterruptions {
  _FakeInterruptions(this.events);

  @override
  final Stream<CallAudioInterruption> events;
}

final class _FakeEngine implements CallMediaEngine {
  int microphoneOpens = 0;
  CallMediaError? microphoneError;
  final List<_FakeAudio> audio = <_FakeAudio>[];
  final List<_FakeConnection> connections = <_FakeConnection>[];

  @override
  Future<CallLocalAudio> openMicrophone() async {
    final error = microphoneError;
    if (error != null) {
      throw CallMediaException(error);
    }
    microphoneOpens++;
    final opened = _FakeAudio();
    audio.add(opened);
    return opened;
  }

  CallMediaError? cameraError;
  final List<_FakeVideo> cameras = <_FakeVideo>[];

  CallMediaError? screenError;
  final List<_FakeVideo> screens = <_FakeVideo>[];

  @override
  Future<CallLocalVideo> openCamera() async {
    final error = cameraError;
    if (error != null) {
      throw CallMediaException(error);
    }
    final opened = _FakeVideo();
    cameras.add(opened);
    return opened;
  }

  @override
  Future<bool> requestScreenConsent() async => true;

  @override
  Future<CallLocalVideo> openScreen() async {
    final error = screenError;
    if (error != null) {
      throw CallMediaException(error);
    }
    final opened = _FakeVideo();
    screens.add(opened);
    return opened;
  }

  @override
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio? audio,
    CallLocalVideo? video,
    bool sendOnly = false,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
  }) async {
    final connection = _FakeConnection(
      audio: audio,
      video: video,
      sendOnly: sendOnly,
      iceServers: iceServers,
      onIceCandidate: onIceCandidate,
      onConnectionState: onConnectionState,
      onRemoteVideo: onRemoteVideo,
      index: connections.length + 1,
    );
    connections.add(connection);
    return connection;
  }
}

final class _FakeVideo implements CallLocalVideo {
  bool disposed = false;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.shrink();

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeRemoteVideo implements CallRemoteVideo {
  bool disposed = false;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeAudio implements CallLocalAudio {
  bool disposed = false;
  bool muted = false;
  bool speakerphone = false;
  final List<bool> muteCalls = <bool>[];

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
    muteCalls.add(value);
  }

  final List<bool> speakerphoneCalls = <bool>[];

  @override
  Future<void> setSpeakerphone(bool on) async {
    speakerphone = on;
    speakerphoneCalls.add(on);
  }

  List<CallAudioRoute> availableRoutes = const <CallAudioRoute>[];
  final List<CallAudioRoute> selectedRoutes = <CallAudioRoute>[];
  final routeChangeController = StreamController<void>.broadcast();

  @override
  Future<List<CallAudioRoute>> routes() async => availableRoutes;

  @override
  Future<void> selectRoute(CallAudioRoute route) async =>
      selectedRoutes.add(route);

  @override
  Stream<void> get routeChanges => routeChangeController.stream;

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeConnection implements CallPeerConnection {
  _FakeConnection({
    required this.audio,
    required this.video,
    this.sendOnly = false,
    required this.iceServers,
    required this.onIceCandidate,
    required this.onConnectionState,
    required this.onRemoteVideo,
    required this.index,
  });

  final CallLocalAudio? audio;
  final CallLocalVideo? video;
  final bool sendOnly;
  final List<CallIceServer> iceServers;
  final void Function(CallIceCandidate candidate) onIceCandidate;
  final void Function(CallMediaConnectionState state) onConnectionState;
  final void Function(CallRemoteVideo? video) onRemoteVideo;
  final int index;

  int createdOffers = 0;
  int createdAnswers = 0;
  bool closed = false;
  final List<CallLocalVideo?> localVideos = <CallLocalVideo?>[];

  @override
  Future<void> setLocalVideo(CallLocalVideo? video) async =>
      localVideos.add(video);
  final List<CallSessionDescription> localDescriptions = [];
  final List<CallSessionDescription> remoteDescriptions = [];
  final List<CallIceCandidate> remoteCandidates = [];

  void emitIceCandidate(CallIceCandidate candidate) =>
      onIceCandidate(candidate);

  void emitConnectionState(CallMediaConnectionState state) =>
      onConnectionState(state);

  int iceRestarts = 0;

  @override
  Future<CallSessionDescription> createOffer({bool iceRestart = false}) async {
    createdOffers++;
    if (iceRestart) {
      iceRestarts++;
    }
    return (type: 'offer', sdp: 'sdp-offer-$index');
  }

  @override
  Future<CallSessionDescription> createAnswer() async {
    createdAnswers++;
    return (type: 'answer', sdp: 'sdp-answer-$index');
  }

  @override
  Future<void> setLocalDescription(CallSessionDescription description) async {
    localDescriptions.add(description);
  }

  @override
  Future<void> setRemoteDescription(CallSessionDescription description) async {
    remoteDescriptions.add(description);
  }

  @override
  Future<void> addIceCandidate(CallIceCandidate candidate) async {
    remoteCandidates.add(candidate);
  }

  @override
  Future<void> close() async => closed = true;
}
