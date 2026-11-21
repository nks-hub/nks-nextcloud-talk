part of 'call_media_session_test.dart';

extension _MediaDisposalTests on _MediaSessionTests {
  void _registerDisposal() {
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
