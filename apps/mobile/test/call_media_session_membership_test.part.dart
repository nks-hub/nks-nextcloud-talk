part of 'call_media_session_test.dart';

extension _MediaMembershipTests on _MediaSessionTests {
  void _registerMembership() {
    test(
      'mesh call opens at most four peer connections concurrently',
      () async {
        final createGate = Completer<void>();
        engine.connectionCreateGate = createGate;
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
          if (!createGate.isCompleted) createGate.complete();
        });

        final starting = media.start();
        for (
          var turn = 0;
          turn < 50 && engine.connectionCreateStarts < 4;
          turn++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(engine.connectionCreateStarts, 4);
        expect(engine.connections, isEmpty);

        createGate.complete();
        await starting;
        expect(engine.connectionCreateStarts, 6);
        expect(engine.connections, hasLength(6));
        expect(media.state.phase, CallMediaPhase.negotiating);
      },
    );

    test('MCU subscriptions send at most four requests concurrently', () async {
      final peers = List.generate(6, (index) => 'peer-$index');
      final releases = <Completer<void>>[];
      var active = 0;
      var maximumActive = 0;
      final media = session(
        _update(
          localPeerId: _local,
          participants: [for (final peer in peers) _participant(peer)],
          topology: SignalingTopology.externalMcu,
        ),
        withControl: true,
        sendMessage: (message, {required expectedRoomEpoch}) async {
          sent.add(message);
          if (message.type != 'requestoffer') {
            return true;
          }
          active++;
          maximumActive = active > maximumActive ? active : maximumActive;
          final release = Completer<void>();
          releases.add(release);
          await release.future;
          active--;
          return true;
        },
      );
      addTearDown(media.dispose);
      addTearDown(() {
        for (final release in releases) {
          if (!release.isCompleted) release.complete();
        }
      });

      final starting = media.start();
      for (var turn = 0; turn < 50 && releases.length < 4; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(releases, hasLength(4));
      expect(active, 4);
      expect(maximumActive, 4);

      releases.first.complete();
      for (var turn = 0; turn < 50 && releases.length < 5; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(
        releases,
        hasLength(5),
        reason: 'the next subscription starts when one worker becomes free',
      );
      for (var index = 1; index < 4; index++) {
        releases[index].complete();
      }
      for (var turn = 0; turn < 50 && releases.length < 6; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(releases, hasLength(6));
      for (var index = 4; index < releases.length; index++) {
        releases[index].complete();
      }
      await starting;

      expect(active, 0);
      expect(maximumActive, 4);
      expect(
        sent.where((message) => message.type == 'requestoffer'),
        hasLength(6),
      );
      expect(engine.connections, hasLength(1), reason: 'publisher only');
      expect(media.state.peers, 6);
    });

    for (final failure in ['offer', 'answer']) {
      test(
        'MCU replaces a publisher after a failed $failure',
        () => _withPublisherRetry((retryPublisher) async {
          final participants = [_participant(_remote)];
          final media = session(
            _update(
              localPeerId: _local,
              topology: SignalingTopology.externalMcu,
              participants: participants,
              messages: [
                _message(_remote, 'offer', {
                  'type': 'offer',
                  'sdp': 'subscriber-sdp',
                }, sid: 'subscriber-sid'),
              ],
            ),
            withControl: true,
          );
          if (failure == 'offer') {
            engine.beforeCreateOffer = (connection) async {
              if (connection.index == 1) {
                throw const CallMediaException(CallMediaError.engineFailure);
              }
            };
          }
          try {
            await media.start();
            final [publisher, subscriber] = engine.connections;
            if (failure == 'answer') {
              final offer = sent.singleWhere(
                (message) => message.type == 'offer',
              );
              publisher.remoteDescriptionError = CallMediaError.engineFailure;
              updates.add(
                _update(
                  localPeerId: _local,
                  topology: SignalingTopology.externalMcu,
                  participants: participants,
                  messages: [
                    _message(_local, 'answer', {
                      'type': 'answer',
                      'sdp': 'publisher-answer',
                    }, sid: offer.sid),
                  ],
                ),
              );
              await pumpEventQueue();
            }

            expect(publisher.closed, isTrue);
            expect(subscriber.closed, isFalse);
            expect(media.state.peers, 1);
            sent.clear();
            publisher.emitIceCandidate(
              const CallIceCandidate(
                candidate: 'candidate:old-publisher',
                sdpMid: '0',
                sdpMLineIndex: 0,
              ),
            );
            await pumpEventQueue();
            expect(
              sent.where((message) => message.type == 'candidate'),
              isEmpty,
            );
            expect(engine.connections, hasLength(2));

            retryPublisher();
            await pumpEventQueue();
            expect(engine.connections, hasLength(3));
            expect(subscriber.closed, isFalse);
            final retry = sent.singleWhere(
              (message) => message.type == 'offer',
            );
            expect(retry.recipient?.value, _local);
            expect(retry.payload?.wire['sdp'], 'sdp-offer-3');
          } finally {
            await media.dispose();
          }
        }),
      );
    }

    test(
      'MCU publisher retry is cancelled when its room changes',
      () => _withPublisherRetry((retryPublisher) async {
        engine.beforeCreateOffer = (connection) async {
          if (connection.index == 1) {
            throw const CallMediaException(CallMediaError.engineFailure);
          }
        };
        final media = session(
          _update(localPeerId: _local, topology: SignalingTopology.externalMcu),
          withControl: true,
        );
        try {
          await media.start();
          expect(engine.connections.single.closed, isTrue);
          updates.add(
            _update(
              localPeerId: 'later-session',
              topology: SignalingTopology.externalMcu,
              roomEpoch: 2,
            ),
          );
          await pumpEventQueue();
          retryPublisher();
          await pumpEventQueue();

          expect(engine.connections, hasLength(2));
          expect(
            sent
                .singleWhere((message) => message.type == 'offer')
                .recipient
                ?.value,
            'later-session',
          );
        } finally {
          await media.dispose();
        }
      }),
    );

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

Future<void> _withPublisherRetry(
  Future<void> Function(VoidCallback retryPublisher) testBody,
) {
  Timer? retry;
  VoidCallback? fire;
  return runZoned(
    () => testBody(() {
      final timer = retry;
      if (timer == null || !timer.isActive) return;
      timer.cancel();
      fire?.call();
    }),
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, delay, callback) {
        final timer = parent.createTimer(zone, delay, callback);
        if (delay == const Duration(seconds: 10)) {
          retry = timer;
          fire = callback;
        }
        return timer;
      },
    ),
  );
}
