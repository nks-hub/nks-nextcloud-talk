part of 'call_media_session_test.dart';

enum _McuScreenAnswerChange {
  resume,
  memberLeaves,
  roomChanges,
  leave,
  newOffer,
  unshare,
}

extension _McuScreenAnswerTests on _MediaSessionTests {
  void _registerMcuScreenAnswerRecovery() {
    for (final change in _McuScreenAnswerChange.values) {
      test('MCU incoming screen answer recovery: ${change.name}', () async {
        const other = 'other-session';
        const epoch = 7;
        const originalSid = 'original-screen';
        final participants = [_participant(_remote), _participant(other)];
        CallSignalingUpdate update({
          List<SignalingParticipant>? members,
          SignalingAccountPhase phase = SignalingAccountPhase.signalingReady,
          List<SignalingPeerMessage> messages = const [],
          int roomEpoch = epoch,
        }) => _update(
          localPeerId: _local,
          participants: members ?? participants,
          phase: phase,
          messages: messages,
          roomEpoch: roomEpoch,
          topology: SignalingTopology.externalMcu,
        );

        SignalingPeerMessage screenOffer(String sid) => _message(
          _remote,
          'offer',
          <String, Object?>{'type': 'offer', 'sdp': sid},
          sid: sid,
          roomType: 'screen',
        );

        final attempted = <({String? sid, Object? sdp, int epoch})>[];
        final media = session(
          update(),
          withControl: true,
          sendMessage: (message, {required expectedRoomEpoch}) async {
            if (message.type == 'answer' && message.roomType == 'screen') {
              attempted.add((
                sid: message.sid,
                sdp: message.payload?.wire['sdp'],
                epoch: expectedRoomEpoch,
              ));
              if (attempted.length == 1) {
                // The separate signaling lane disconnects while we answer.
                updates.add(
                  update(phase: SignalingAccountPhase.reconnectWaiting),
                );
                return false;
              }
            }
            sent.add(message);
            return true;
          },
        );
        addTearDown(media.dispose);
        await media.start();
        updates.add(
          update(
            messages: [
              for (final peerId in [_remote, other])
                _message(peerId, 'offer', <String, Object?>{
                  'type': 'offer',
                  'sdp': peerId,
                }, sid: '$peerId-video'),
            ],
          ),
        );
        await pumpEventQueue();
        expect(engine.connections, hasLength(3));
        final audioPeers = engine.connections.skip(1).toList();
        for (final peer in audioPeers) {
          peer.emitConnectionState(CallMediaConnectionState.connected);
        }
        updates.add(update(messages: [screenOffer(originalSid)]));
        await pumpEventQueue();

        expect(attempted, hasLength(1));
        final incomingScreen = engine.connections.last;
        final original = attempted.single;
        expect(original, (
          sid: originalSid,
          sdp: incomingScreen.localDescriptions.single.sdp,
          epoch: epoch,
        ));
        expect(incomingScreen.createdAnswers, 1);
        expect(incomingScreen.closed, isFalse);

        final resumed = switch (change) {
          _McuScreenAnswerChange.memberLeaves => update(
            members: [_participant(other)],
          ),
          _McuScreenAnswerChange.roomChanges => update(roomEpoch: epoch + 1),
          _McuScreenAnswerChange.newOffer => update(
            messages: [screenOffer('replacement-screen')],
          ),
          _McuScreenAnswerChange.unshare => update(
            messages: [
              _message(
                _remote,
                'unshareScreen',
                const <String, Object?>{},
                sid: originalSid,
                roomType: 'screen',
              ),
            ],
          ),
          _ => update(),
        };
        if (change == _McuScreenAnswerChange.leave) {
          await media.dispose();
        }
        updates.add(resumed);
        await pumpEventQueue();
        updates.add(
          update(members: resumed.participants, roomEpoch: resumed.roomEpoch),
        );
        await pumpEventQueue();

        switch (change) {
          case _McuScreenAnswerChange.resume:
            expect(attempted, [original, original]);
            expect(incomingScreen.createdAnswers, 1);
            expect(incomingScreen.closed, isFalse);
            expect(audioPeers.every((peer) => !peer.closed), isTrue);
            expect(media.state.phase, CallMediaPhase.connected);
          case _McuScreenAnswerChange.newOffer:
            expect(attempted.map((answer) => answer.sid), [
              originalSid,
              'replacement-screen',
            ]);
            expect(attempted.last.epoch, epoch);
            expect(incomingScreen.createdAnswers, 2);
          case _McuScreenAnswerChange.memberLeaves:
          case _McuScreenAnswerChange.unshare:
            expect(attempted, [original]);
            expect(incomingScreen.closed, isTrue);
            expect(audioPeers.last.closed, isFalse);
          case _McuScreenAnswerChange.roomChanges:
          case _McuScreenAnswerChange.leave:
            expect(attempted, [original]);
            expect(incomingScreen.closed, isTrue);
            expect(audioPeers.every((peer) => peer.closed), isTrue);
        }
      });
    }
  }
}
