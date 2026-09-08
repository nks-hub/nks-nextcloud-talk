import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_audio_interruptions.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_signaling_session.dart';
import 'package:talk_protocol/talk_protocol.dart';

part 'call_media_session_screen_test.part.dart';
part 'call_media_session_controls_test.part.dart';
part 'call_media_session_support_test.part.dart';
part 'call_media_session_membership_test.part.dart';

/// The mesh offerer role is decided by the ordered pair of session ids, so the
/// fixtures deliberately sit on both sides of `alice`.
const _local = 'zulu-session';
const _remote = 'alice-session';

void main() => _MediaSessionTests().register();

final class _MediaSessionTests {
  late _FakeEngine engine;
  late StreamController<CallSignalingUpdate> updates;
  late List<SignalingPeerMessage> sent;
  late List<HpbControlMessage> controls;

  void register() {
    setUp(() {
      engine = _FakeEngine();
      updates = StreamController<CallSignalingUpdate>.broadcast(sync: true);
      sent = <SignalingPeerMessage>[];
      controls = <HpbControlMessage>[];
    });

    tearDown(() => updates.close());

    _registerCore();
    _registerScreenSharing();
    _registerControls();
    _registerRecovery();
    _registerMembership();
  }

  CallMediaSession session(
    CallSignalingUpdate initial, {
    bool withControl = false,
    Duration renegotiationHold = const Duration(seconds: 45),
    void Function()? onSignalingRebuilt,
  }) => CallMediaSession(
    initial: initial,
    renegotiationHold: renegotiationHold,
    onSignalingRebuilt: onSignalingRebuilt,
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

  void _registerCore() {
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

    test(
      'a required renegotiation drops the peers instead of pretending',
      () async {
        // What it must NOT do is keep media running against a session the lane has
        // already declared unreliable. It used to end the call outright; it now
        // waits for the new one (see the reconnect tests below), but the peers go
        // either way — that half was always right.
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
        expect(media.state.phase, CallMediaPhase.preparing);
      },
    );

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
        expect(
          media.state.raisedHands,
          0,
          reason: 'our own hand is not counted',
        );
        // A raised hand is a signalling message only: a live capture never saw
        // one on Talk's status data channel, alongside a reaction.
        expect(
          engine.connections.single.sentStatus.map((frame) => frame.type),
          isNot(contains('raiseHand')),
        );

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
        expect(
          media.state.reaction,
          isNull,
          reason: 'our own is for the others',
        );

        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            messages: [
              _message(_remote, 'reaction', <String, Object?>{
                'reaction': '🎉',
              }),
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
  }

  void _registerRecovery() {
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
        final interruptions =
            StreamController<CallAudioInterruption>.broadcast();
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
        final interruptions =
            StreamController<CallAudioInterruption>.broadcast();
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
        expect(
          media.state.muted,
          isTrue,
          reason: 'the control shows the choice',
        );

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
    test(
      'a reconnect waits for the new session instead of ending the call',
      () async {
        // Measured live on 6 September 2026: eighteen seconds of airplane mode in
        // an MCU call ended it outright — "the connection to the call server
        // dropped, so the audio stopped" and a Join button where the call had been. The flag is set
        // while the lane refuses to carry SDP; what follows it is a full hello
        // with a new room epoch, which is exactly the rebuild the flag asks for.
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

        expect(
          media.state.phase,
          CallMediaPhase.preparing,
          reason: 'the call is connecting again, not over',
        );
        expect(media.state.error, isNull);
        expect(engine.connections.single.closed, isTrue);

        // The fresh authority: a new epoch, the flag cleared.
        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            roomEpoch: 2,
          ),
        );
        await pumpEventQueue();

        expect(
          engine.connections,
          hasLength(2),
          reason: 'the peer is rebuilt against the new session',
        );
        expect(media.state.error, isNull);
      },
    );

    test('a reconnect that never completes still ends the call', () async {
      // The wait is bounded on purpose: signalling that does not come back
      // means the call really is gone, and saying otherwise would be a lie
      // told with a spinner.
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
        renegotiationHold: const Duration(milliseconds: 30),
      );
      addTearDown(media.dispose);
      await media.start();

      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          renegotiationRequired: true,
        ),
      );
      await pumpEventQueue();
      expect(media.state.phase, CallMediaPhase.preparing);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();

      expect(media.state.phase, CallMediaPhase.failed);
      expect(media.state.error, CallMediaError.signalingLost);
    });

    test(
      'a rebuilt session tells the caller, so the call can be re-announced',
      () async {
        // Read off the wire on 6 September 2026 and then fixed there: after a
        // reconnect both sides are told `room/leave` and `room/join` for the
        // changed signalling session, and nothing else. Being in the ROOM is not
        // being in the CALL — that travels in `participants/update`, which the
        // server sends when Talk reports a change of its own. A pure signalling
        // reconnect changes nothing there, so without this hook neither side
        // learns the other stayed in the call and no media is ever rebuilt
        // between them.
        var rebuilds = 0;
        final media = session(
          _update(localPeerId: _local, participants: [_participant(_remote)]),
          onSignalingRebuilt: () => rebuilds++,
        );
        addTearDown(media.dispose);
        await media.start();
        expect(
          rebuilds,
          1,
          reason: 'first HPB admission also needs membership',
        );

        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            roomEpoch: 2,
          ),
        );
        await pumpEventQueue();
        expect(rebuilds, 2);

        // The same epoch again is an ordinary update, not a reconnect: announcing
        // on every one of them would put a request on the server for each poll.
        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            roomEpoch: 2,
          ),
        );
        await pumpEventQueue();
        expect(rebuilds, 2);
      },
    );
  }
}
