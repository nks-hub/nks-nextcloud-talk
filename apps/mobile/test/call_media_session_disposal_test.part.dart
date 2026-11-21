part of 'call_media_session_test.dart';

extension _MediaDisposalTests on _MediaSessionTests {
  void _registerDisposal() {
    test(
      'dispose releases the MCU publisher after a peer close fails',
      () async {
        const peers = [_remote, 'second-session'];
        final media = session(
          _update(
            localPeerId: _local,
            topology: SignalingTopology.externalMcu,
            participants: [for (final peer in peers) _participant(peer)],
            messages: [
              for (final peer in peers)
                _message(peer, 'offer', {
                  'type': 'offer',
                  'sdp': 'remote-publisher',
                }, sid: 'incoming-$peer'),
            ],
          ),
          withControl: true,
        );
        final statesClosed = Completer<void>();
        final subscription = media.states.listen(
          (_) {},
          onDone: statesClosed.complete,
        );
        addTearDown(subscription.cancel);
        await media.start();
        final [publisher, failingPeer, otherPeer] = engine.connections;
        await media.setCameraEnabled(true);
        await media.setScreenSharing(true);
        final screenPublisher = engine.connections.last;
        failingPeer.closeFailure = StateError('native peer close failed');

        final disposing = media.dispose();
        expect(media.dispose(), same(disposing));
        final failure = await disposing.then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );

        expect(otherPeer.closed, isTrue);
        expect(publisher.closed, isTrue);
        expect(screenPublisher.closed, isTrue);
        expect(engine.screens.single.disposeCalls, 1);
        expect(engine.cameras.single.disposeCalls, 1);
        expect(engine.audio.single.disposeCalls, 1);
        expect(engine.connectionCloseStarts, 4);
        expect(media.state.phase, CallMediaPhase.idle);
        expect(statesClosed.isCompleted, isTrue);
        expect(failure, isNull);
        await media.dispose();
        expect(engine.connectionCloseStarts, 4);
      },
    );

    test(
      'stopping screen share releases capture after a peer close fails',
      () async {
        final media = session(
          _update(
            localPeerId: _local,
            participants: [
              _participant(_remote),
              _participant('second-session'),
            ],
          ),
        );
        await media.start();
        final callPeers = engine.connections.toList();
        await media.setScreenSharing(true);
        final [failingShare, otherShare] = engine.connections.skip(2).toList();
        failingShare.closeFailure = StateError(
          'native screen peer close failed',
        );
        addTearDown(() async {
          failingShare.closeFailure = null;
          await media.dispose();
        });

        final failure = await media
            .setScreenSharing(false)
            .then<Object?>((_) => null, onError: (Object error) => error);

        expect(otherShare.closed, isTrue);
        expect(engine.screens.single.disposeCalls, 1);
        expect(media.state.screenSharing, isFalse);
        expect(callPeers.every((peer) => !peer.closed), isTrue);
        expect(engine.audio.single.disposed, isFalse);
        expect(failure, isNull);
        await media.setScreenSharing(false);
        expect(engine.connectionCloseStarts, 2);
      },
    );

    test('dispose closes peer connections with bounded concurrency', () async {
      final closeGate = Completer<void>();
      engine.connectionCloseGate = closeGate;
      final media = session(
        _update(
          localPeerId: _local,
          participants: [
            for (final peerId in const [
              'peer-a',
              'peer-b',
              'peer-c',
              'peer-d',
              'peer-e',
              'peer-f',
            ])
              _participant(peerId),
          ],
        ),
      );
      addTearDown(media.dispose);
      addTearDown(() {
        if (!closeGate.isCompleted) {
          closeGate.complete();
        }
      });
      await media.start();
      expect(engine.connections, hasLength(6));

      final disposing = media.dispose();
      for (
        var turn = 0;
        turn < 50 && engine.connectionCloseStarts < 4;
        turn++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(engine.connectionCloseStarts, 4);
      expect(
        engine.connections.where((connection) => connection.closed),
        isEmpty,
      );

      closeGate.complete();
      await disposing;
      expect(engine.connectionCloseStarts, 6);
      expect(
        engine.connections.every((connection) => connection.closed),
        isTrue,
      );
    });
  }
}
