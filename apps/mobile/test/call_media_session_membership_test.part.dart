part of 'call_media_session_test.dart';

extension _MediaMembershipTests on _MediaSessionTests {
  void _registerMembership() {
    for (final phase in [
      SignalingAccountPhase.terminated,
      SignalingAccountPhase.unsupported,
      SignalingAccountPhase.reauthenticationRequired,
    ]) {
      test(
        'terminal initial signaling $phase refuses media before microphone',
        () async {
          final media = session(
            _update(localPeerId: _local, phase: phase, roomConfirmed: false),
          );
          addTearDown(media.dispose);
          await media.start();
          expect(media.state.phase, CallMediaPhase.failed);
          expect(media.state.error, CallMediaError.signalingLost);
          expect(engine.microphoneOpens, 0);
        },
      );
    }
    test(
      'terminal signaling update closes existing media instead of preparing forever',
      () async {
        final media = session(
          _update(localPeerId: _local, participants: [_participant(_remote)]),
        );
        addTearDown(media.dispose);
        await media.start();
        updates.add(
          _update(
            localPeerId: _local,
            phase: SignalingAccountPhase.terminated,
            roomConfirmed: false,
          ),
        );
        await pumpEventQueue();
        expect(media.state.phase, CallMediaPhase.failed);
        expect(media.state.error, CallMediaError.signalingLost);
        expect(engine.connections.single.closed, isTrue);
      },
    );
    for (final topology in [
      SignalingTopology.externalMcu,
      SignalingTopology.externalPeerToPeer,
    ]) {
      test(
        'first $topology room admission reannounces call membership once',
        () async {
          var announcements = 0;
          final media = session(
            _update(
              localPeerId: null,
              topology: topology,
              phase: SignalingAccountPhase.hpbRoomPending,
              roomConfirmed: false,
            ),
            withControl: true,
            onSignalingRebuilt: () => announcements++,
          );
          addTearDown(media.dispose);
          await media.start();
          expect(announcements, 0);
          updates.add(
            _update(
              localPeerId: _local,
              topology: topology,
              roomConfirmed: false,
            ),
          );
          await pumpEventQueue();
          expect(announcements, 0);
          updates.add(_update(localPeerId: null, topology: topology));
          await pumpEventQueue();
          expect(announcements, 0);
          updates.add(_update(localPeerId: _local, topology: topology));
          await pumpEventQueue();
          expect(announcements, 1);
          updates.add(
            _update(
              localPeerId: _local,
              topology: topology,
              participants: [_participant(_remote)],
            ),
          );
          updates.add(_update(localPeerId: _local, topology: topology));
          await pumpEventQueue();
          expect(announcements, 1);
        },
      );
    }

    test(
      'an already ready HPB session announces only its first binding',
      () async {
        var announcements = 0;
        final media = session(
          _update(localPeerId: _local),
          onSignalingRebuilt: () => announcements++,
        );
        addTearDown(media.dispose);
        await media.start();
        expect(announcements, 1);
        updates.add(_update(localPeerId: _local));
        await pumpEventQueue();
        expect(announcements, 1);
        updates.add(_update(localPeerId: 'replacement-session'));
        await pumpEventQueue();
        expect(announcements, 2);
        updates.add(_update(localPeerId: 'replacement-session'));
        await pumpEventQueue();
        expect(announcements, 2);
        await media.dispose();
        updates.add(_update(localPeerId: 'late-session', roomEpoch: 2));
        await pumpEventQueue();
        expect(announcements, 2);
      },
    );

    test(
      'internal room admission does not need an HPB membership announcement',
      () async {
        var announcements = 0;
        final media = session(
          _update(
            localPeerId: _local,
            transport: SignalingTransportKind.internal,
            topology: SignalingTopology.internalPeerToPeer,
          ),
          onSignalingRebuilt: () => announcements++,
        );
        addTearDown(media.dispose);
        await media.start();
        expect(announcements, 0);
      },
    );
  }
}
