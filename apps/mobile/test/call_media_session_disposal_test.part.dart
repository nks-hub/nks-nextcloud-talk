part of 'call_media_session_test.dart';

const _screenNegotiationHold = Duration(seconds: 45);

extension _MediaDisposalTests on _MediaSessionTests {
  void _registerDisposal() {
    for (final sharing in [false, true]) {
      test('leaving during ${sharing ? 'screen sharing' : 'mesh startup'} '
          'closes pending connections without starting more', () async {
        final gate = Completer<void>();
        final media = session(
          _update(
            localPeerId: _local,
            participants: [for (var i = 0; i < 6; i++) _participant('peer-$i')],
          ),
        );
        addTearDown(media.dispose);
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        if (sharing) await media.start();
        final alreadyOpened = engine.connectionCreateStarts;
        engine.connectionCreateGate = gate;
        final opening = sharing ? media.setScreenSharing(true) : media.start();
        await pumpEventQueue();
        expect(engine.connectionCreateStarts, alreadyOpened + 4);

        final leaving = media.dispose();
        gate.complete();
        await Future.wait([opening, leaving]);

        expect(engine.connectionCreateStarts, alreadyOpened + 4);
        expect(engine.connectionCloseStarts, alreadyOpened + 4);
        expect(
          engine.connections.every((connection) => connection.closed),
          isTrue,
        );
        expect(engine.audio.single.disposeCalls, 1);
        if (sharing) expect(engine.screens.single.disposeCalls, 1);
        expect(media.state.phase, CallMediaPhase.idle);
      });
    }

    test('leaving releases a late camera without attaching it', () async {
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
      );
      addTearDown(media.dispose);
      final opening = Completer<void>();
      engine.cameraStartup = opening;
      addTearDown(() {
        if (!opening.isCompleted) opening.complete();
      });
      await media.start();
      final connection = engine.connections.single;
      connection.sentStatus.clear();
      sent.clear();
      final enabling = media.setCameraEnabled(true);
      await pumpEventQueue();

      final leaving = media.dispose();
      opening.complete();
      await Future.wait([enabling, leaving]);

      expect(engine.cameras.single.disposeCalls, 1);
      expect(connection.localVideos, isEmpty);
      expect(connection.sentStatus, isEmpty);
      expect(sent, isEmpty);
    });

    test(
      'leaving stops camera fan-out after the active peer updates',
      () async {
        final media = session(
          _update(
            localPeerId: _local,
            participants: [for (var i = 0; i < 5; i++) _participant('peer-$i')],
          ),
        );
        addTearDown(media.dispose);
        await media.start();
        for (final connection in engine.connections) {
          connection.sentStatus.clear();
        }
        final fourUpdates = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        var started = 0;
        engine.beforeSetLocalVideo = () async {
          if (++started == 4) fourUpdates.complete();
          await release.future;
        };
        final enabling = media.setCameraEnabled(true);
        await fourUpdates.future;

        final leaving = media.dispose();
        release.complete();
        await Future.wait([enabling, leaving]);

        expect(started, 4);
        expect(engine.cameras.single.disposeCalls, 1);
        expect(
          engine.connections.expand((connection) => connection.sentStatus),
          isEmpty,
        );
      },
    );

    test('leaving stops status frames after a suspended send', () async {
      final sending = Completer<void>();
      final release = Completer<void>();
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
        sendMessage: (message, {required expectedRoomEpoch}) async {
          if (message.type == 'mute' &&
              message.payload?.wire['name'] == 'audio') {
            sending.complete();
            await release.future;
          }
          return true;
        },
      );
      addTearDown(media.dispose);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await media.start();
      final status = engine.connections.single.sentStatus;
      status.clear();
      final muting = media.setMicrophoneMuted(true);
      await sending.future;

      final leaving = media.dispose();
      release.complete();
      await Future.wait([muting, leaving]);

      expect(status.map((frame) => frame.type), ['audioOff']);
    });

    test('a failed live MCU screen closes only the outgoing share', () async {
      const peers = [_remote, 'second-session'];
      final media = session(
        _mcuScreenUpdate(
          peers: peers,
          messages: [
            for (final peer in peers)
              _message(peer, 'offer', {
                'type': 'offer',
                'sdp': 'subscriber-offer',
              }, sid: 'incoming-$peer'),
          ],
        ),
        withControl: true,
      );
      addTearDown(media.dispose);
      await media.start();
      final callConnections = engine.connections.toList();
      await media.setScreenSharing(true);
      final share = engine.connections.last;
      updates.add(
        _mcuScreenUpdate(
          peers: peers,
          messages: [
            for (final offer in sent.where(
              (message) => message.type == 'offer',
            ))
              _mcuPublisherAnswer(offer),
          ],
        ),
      );
      for (final connection in engine.connections) {
        connection.emitConnectionState(CallMediaConnectionState.connected);
      }
      await pumpEventQueue();
      expect(share.remoteDescriptions, hasLength(1));
      expect(callConnections.first.remoteDescriptions, hasLength(1));
      expect(media.state.screenSharing, isTrue);
      expect(media.state.connectedPeers, peers.length);

      sent.clear();
      share.emitConnectionState(CallMediaConnectionState.failed);
      await pumpEventQueue();

      expect(media.state.screenSharing, isFalse);
      expect(engine.screens.single.disposeCalls, 1);
      expect(share.closed, isTrue);
      expect(callConnections.every((connection) => !connection.closed), isTrue);
      expect(media.state.connectedPeers, peers.length);
      expect(media.state.phase, CallMediaPhase.connected);
      expect(
        sent
            .where((message) => message.type == 'unshareScreen')
            .map((message) => message.recipient?.value),
        unorderedEquals([_local, ...peers]),
      );
    });

    test(
      'an unanswered MCU screen offer releases its capture',
      () => _withCapturedTimers(_screenNegotiationHold, (timers) async {
        final media = await _startPendingMcuScreen();
        final [publisher, share] = engine.connections;
        expect(media.state.screenSharing, isTrue);

        expect(timers, hasLength(1));
        timers.single.expire();
        await pumpEventQueue();

        expect(media.state.screenSharing, isFalse);
        expect(engine.screens.single.disposeCalls, 1);
        expect(share.closed, isTrue);
        expect(publisher.closed, isFalse);
        expect(media.state.peers, 1);
      }),
    );

    for (final queuedDeadline in [false, true]) {
      test(
        queuedDeadline
            ? 'an MCU screen answer received before the deadline keeps sharing'
            : 'an accepted MCU screen answer cancels the deadline',
        () => _withCapturedTimers(_screenNegotiationHold, (timers) async {
          final media = await _startPendingMcuScreen();
          final share = engine.connections.last;
          final offer = sent.lastWhere((message) => message.type == 'offer');
          expect(timers.single.timer.isActive, isTrue);

          updates.add(_mcuScreenUpdate(messages: [_mcuPublisherAnswer(offer)]));
          if (queuedDeadline) timers.single.expire();
          await pumpEventQueue();

          expect(share.remoteDescriptions, hasLength(1));
          expect(timers.single.timer.isActive, isFalse);
          expect(media.state.screenSharing, isTrue);
          expect(engine.screens.single.disposed, isFalse);
        }),
      );
    }

    test(
      'queued MCU screen events cannot close a replacement share',
      () => _withCapturedTimers(_screenNegotiationHold, (timers) async {
        final media = await _startPendingMcuScreen();
        final replaced = engine.connections.last;

        final stopping = media.setScreenSharing(false);
        final starting = media.setScreenSharing(true);
        timers.single.expire();
        replaced.emitConnectionState(CallMediaConnectionState.failed);
        await Future.wait([stopping, starting]);
        await pumpEventQueue();

        expect(replaced.closed, isTrue);
        expect(engine.screens.first.disposeCalls, 1);
        expect(engine.connections.last.closed, isFalse);
        expect(timers, hasLength(2));
        expect(timers.last.timer.isActive, isTrue);
        expect(media.state.screenSharing, isTrue);
        expect(engine.screens.last.disposed, isFalse);
      }),
    );

    test(
      'leaving cancels the pending MCU screen deadline',
      () => _withCapturedTimers(_screenNegotiationHold, (timers) async {
        final media = await _startPendingMcuScreen();
        final share = engine.connections.last;
        expect(timers.single.timer.isActive, isTrue);

        sent.clear();
        share.emitConnectionState(CallMediaConnectionState.failed);
        final disposal = media.dispose();

        expect(timers.single.timer.isActive, isFalse);
        await disposal;

        expect(media.state, CallMediaState.idle);
        expect(engine.screens.single.disposeCalls, 1);
        expect(share.closed, isTrue);
        expect(sent, isEmpty);
      }),
    );

    test('an obsolete MCU answer cannot close a replacement share', () async {
      final participants = [_participant(_remote)];
      final media = session(
        _update(
          localPeerId: _local,
          topology: SignalingTopology.externalMcu,
          participants: participants,
        ),
        withControl: true,
      );
      addTearDown(media.dispose);
      await media.start();
      await media.setScreenSharing(true);
      final original = sent.lastWhere((message) => message.type == 'offer');
      await media.setScreenSharing(false);
      await media.setScreenSharing(true);
      final replacement = sent.lastWhere((message) => message.type == 'offer');
      final share = engine.connections.last;
      expect(replacement.sid, isNot(original.sid));

      void answer(String sender, String? sid) {
        updates.add(
          _update(
            localPeerId: _local,
            topology: SignalingTopology.externalMcu,
            participants: participants,
            messages: [
              _message(
                sender,
                'answer',
                {'type': 'answer', 'sdp': 'screen-answer'},
                sid: sid,
                roomType: 'screen',
              ),
            ],
          ),
        );
      }

      share.remoteDescriptionError = CallMediaError.engineFailure;
      answer(_local, original.sid);
      answer(_local, null);
      answer(_remote, replacement.sid);
      await pumpEventQueue();

      expect(share.closed, isFalse);
      expect(media.state.screenSharing, isTrue);
      expect(engine.screens.last.disposed, isFalse);
      expect(share.remoteDescriptions, isEmpty);

      share.remoteDescriptionError = null;
      answer(_local, replacement.sid);
      await pumpEventQueue();
      expect(share.remoteDescriptions.single.sdp, 'screen-answer');
    });

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
        final closeFailure = StateError('native peer close failed');
        failingPeer.closeFailure = closeFailure;
        engine.cameras.single.disposeFailure = StateError(
          'native camera release failed later',
        );

        final disposing = media.dispose();
        expect(media.dispose(), same(disposing));
        StackTrace? originalStack;
        final failure = await disposing.then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace stackTrace) {
            originalStack = stackTrace;
            return error;
          },
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
        expect(failure, same(closeFailure));
        expect(originalStack.toString(), contains('_FakeConnection.close'));
        await expectLater(media.dispose(), throwsA(same(closeFailure)));
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

    for (final leaving in [false, true]) {
      test(
        'MCU subscriber renderer failure during ${leaving ? 'leave' : 'recovery'}',
        () async {
          final media = session(_mcuScreenUpdate(), withControl: true);
          addTearDown(media.dispose);
          final releaseStarted = Completer<void>();
          final finishRelease = Completer<void>();
          addTearDown(() {
            if (!finishRelease.isCompleted) finishRelease.complete();
          });
          await media.start();
          updates.add(
            _mcuScreenUpdate(
              messages: [
                _message(_remote, 'offer', {
                  'type': 'offer',
                  'sdp': 'remote-video',
                }, sid: 'failed-subscriber'),
                _message(
                  _remote,
                  'offer',
                  {'type': 'offer', 'sdp': 'remote-screen'},
                  sid: 'incoming-screen',
                  roomType: 'screen',
                ),
              ],
            ),
          );
          await pumpEventQueue();
          final [publisher, subscriber, screen] = engine.connections;
          final renderer = _FakeRemoteVideo(
            beforeDispose: () async {
              releaseStarted.complete();
              await finishRelease.future;
              throw StateError('subscriber renderer release failed');
            },
          );
          subscriber.onRemoteVideo(renderer);
          await pumpEventQueue();
          expect(media.state.participants.single.video, same(renderer));
          expect(screen.remoteDescriptions.single.sdp, 'remote-screen');

          sent.clear();
          subscriber.emitConnectionState(CallMediaConnectionState.failed);
          await releaseStarted.future;
          final disposal = leaving ? media.dispose() : null;
          finishRelease.complete();
          await disposal;
          await pumpEventQueue();

          expect(renderer.disposed, isTrue);
          expect(subscriber.closed, isTrue);
          expect(publisher.closed, leaving);
          expect(screen.closed, leaving);
          final requests = sent.where(
            (message) => message.type == 'requestoffer',
          );
          if (leaving) {
            expect(requests, isEmpty);
          } else {
            expect(requests.single.recipient?.value, _remote);
            expect(requests.single.sid, isNot('failed-subscriber'));
            expect(sent.where((message) => message.type == 'offer'), isEmpty);
          }
        },
      );
    }

    test('dispose closes an incoming screen without a call peer', () async {
      engine.audioConnectionError = CallMediaError.engineFailure;
      final media = session(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          messages: [
            _message(
              _remote,
              'offer',
              {'type': 'offer', 'sdp': 'remote-screen'},
              roomType: 'screen',
              sid: 'incoming-screen',
            ),
          ],
        ),
      );
      addTearDown(media.dispose);
      await media.start();
      final screen = engine.connections.single;
      final renderer = _FakeRemoteVideo();
      screen.onRemoteVideo(renderer);
      await pumpEventQueue();
      expect(media.state.peers, 0);
      expect(screen.remoteDescriptions.single.sdp, 'remote-screen');
      expect(renderer.disposed, isFalse);

      await media.dispose();

      expect(renderer.disposed, isTrue);
      expect(screen.closed, isTrue);
      expect(engine.connectionCloseStarts, 1);
    });

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

  Future<CallMediaSession> _startPendingMcuScreen() async {
    final media = session(_mcuScreenUpdate(), withControl: true);
    addTearDown(media.dispose);
    await media.start();
    await media.setScreenSharing(true);
    return media;
  }
}

CallSignalingUpdate _mcuScreenUpdate({
  List<String> peers = const [_remote],
  List<SignalingPeerMessage> messages = const [],
}) => _update(
  localPeerId: _local,
  topology: SignalingTopology.externalMcu,
  participants: [for (final peer in peers) _participant(peer)],
  messages: messages,
);

SignalingPeerMessage _mcuPublisherAnswer(SignalingPeerMessage offer) =>
    _message(
      _local,
      'answer',
      {'type': 'answer', 'sdp': 'publisher-answer'},
      sid: offer.sid,
      roomType: offer.roomType,
    );
