part of 'call_media_session_test.dart';

extension _ScreenMediaSessionTests on _MediaSessionTests {
  void _registerScreenSharing() {
    for (final mcu in [false, true]) {
      test(
        'leaving during screen startup never publishes (MCU: $mcu)',
        () async {
          final media = session(
            _update(
              localPeerId: _local,
              participants: [_participant(_remote)],
              topology: mcu
                  ? SignalingTopology.externalMcu
                  : SignalingTopology.externalPeerToPeer,
            ),
            withControl: mcu,
          );
          addTearDown(media.dispose);
          await media.start();
          final connectionCount = engine.connections.length;
          engine.screenStartup = Completer<void>();
          final sharing = media.setScreenSharing(true);
          await pumpEventQueue();

          final leaving = media.dispose();
          engine.screenStartup!.complete();
          await Future.wait([sharing, leaving]);

          expect(engine.screens.single.disposed, isTrue);
          expect(engine.connections, hasLength(connectionCount));
          expect(
            sent.where((message) => message.roomType == 'screen'),
            isEmpty,
          );
          expect(media.state, CallMediaState.idle);
        },
      );
    }

    test('sharing this screen opens a send-only connection per peer', () async {
      final media = session(
        _update(localPeerId: _local, participants: [_participant(_remote)]),
      );
      addTearDown(media.dispose);
      await media.start();
      expect(engine.connections, hasLength(1));

      const source = CallScreenSource(
        id: 'screen-1',
        name: 'Display 1',
        isWindow: false,
      );
      await media.setScreenSharing(true, source: source);
      expect(engine.selectedScreenSource, same(source));
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

      await expectLater(
        media.setScreenSharing(true),
        throwsA(
          isA<CallMediaException>().having(
            (error) => error.code,
            'code',
            CallMediaError.screenSharePermissionDenied,
          ),
        ),
      );
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
        // The participant is asked for with a peer message, not offered to.
        final request = sent.singleWhere(
          (message) => message.type == 'requestoffer',
        );
        expect(request.recipient?.value, _remote);
        expect(request.roomType, 'video');
        expect(request.payload, isNull);
        // The subscriber connection this offer is for: the MCU answers on it,
        // and asking without one gets no offer at all.
        expect(request.sid, isNotNull);
        expect(request.sid, isNot(publisherSid));
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

    test(
      'a failed MCU subscriber requests an offer without publishing',
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
        final publisher = engine.connections.single;
        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            topology: SignalingTopology.externalMcu,
            messages: [
              _message(_remote, 'offer', {
                'type': 'offer',
                'sdp': 'remote-publisher',
              }, sid: 'mcu-old-subscriber'),
            ],
          ),
        );
        await pumpEventQueue();
        final subscriber = engine.connections.last;
        sent.clear();
        subscriber.emitConnectionState(CallMediaConnectionState.failed);
        await pumpEventQueue();
        expect(sent.where((message) => message.type == 'offer'), isEmpty);
        final request = sent.singleWhere(
          (message) => message.type == 'requestoffer',
        );
        expect(request.recipient?.value, _remote);
        expect(request.sid, isNot('mcu-old-subscriber'));
        expect(subscriber.closed, isTrue);
        expect(publisher.closed, isFalse);
        expect(publisher.createdOffers, 1);
        engine.connectionError = CallMediaError.engineFailure;
        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            topology: SignalingTopology.externalMcu,
            messages: [
              _message(_remote, 'offer', {
                'type': 'offer',
                'sdp': 'setup-fails',
              }, sid: 'failed-new-handle'),
            ],
          ),
        );
        await pumpEventQueue();
        engine.connectionError = null;
        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            topology: SignalingTopology.externalMcu,
            messages: [
              _message(_remote, 'offer', {
                'type': 'offer',
                'sdp': 'retired-offer',
              }, sid: 'mcu-old-subscriber'),
              _message(_remote, 'candidate', {
                'candidate': {
                  'candidate': 'candidate:retired',
                  'sdpMid': 'audio',
                  'sdpMLineIndex': 0,
                },
              }, sid: 'mcu-old-subscriber'),
            ],
          ),
        );
        await pumpEventQueue();
        expect(engine.connections, hasLength(2));
        updates.add(
          _update(
            localPeerId: _local,
            participants: [_participant(_remote)],
            topology: SignalingTopology.externalMcu,
            messages: [
              _message(_remote, 'offer', {
                'type': 'offer',
                'sdp': 'replacement-offer',
              }, sid: 'new-janus-handle'),
            ],
          ),
        );
        await pumpEventQueue();
        final replacement = engine.connections.last;
        expect(replacement, isNot(same(subscriber)));
        expect(replacement.remoteCandidates, isEmpty);
        expect(
          sent.lastWhere((message) => message.type == 'answer').sid,
          'new-janus-handle',
        );
        replacement.emitConnectionState(CallMediaConnectionState.connected);
        await pumpEventQueue();
        sent.clear();
        subscriber.emitConnectionState(CallMediaConnectionState.failed);
        subscriber.emitIceCandidate(
          const CallIceCandidate(
            candidate: 'candidate:late',
            sdpMid: 'audio',
            sdpMLineIndex: 0,
          ),
        );
        subscriber.receiveStatus('audioOff');
        subscriber.receiveStatus('speaking');
        await pumpEventQueue();
        expect(sent, isEmpty);
        expect(replacement.closed, isFalse);
        expect(media.state.participants.single.connected, isTrue);
        expect(media.state.participants.single.audioMuted, isFalse);
        expect(media.state.participants.single.speaking, isFalse);
      },
    );

    test(
      'through an MCU the screen is published once, not per participant',
      () async {
        final media = session(
          _update(
            localPeerId: _local,
            participants: [
              _participant(_remote),
              _participant('carol-session'),
            ],
            topology: SignalingTopology.externalMcu,
          ),
          withControl: true,
        );
        addTearDown(media.dispose);
        await media.start();
        final before = engine.connections.length;

        await media.setScreenSharing(true);
        await pumpEventQueue();
        // One connection more, not one per participant, and it is offered to this
        // side's own session id — the media server fans it out from there.
        expect(engine.connections.length, before + 1);
        final share = engine.connections.last;
        expect(share.video, same(engine.screens.single));
        final offer = sent.lastWhere((message) => message.type == 'offer');
        expect(offer.roomType, 'screen');
        expect(offer.recipient?.value, _local);
        // Whose screen it is; talk-web sends this to an MCU as well.
        expect(offer.broadcaster, _local);
      },
    );

    test(
      'through an MCU the screen is announced to every participant',
      () async {
        // The media server does not tell anyone a publisher appeared, and the
        // participants have no way to guess a screen exists, so the publisher
        // pushes an offer at each of them. Without this the publish succeeded
        // and nobody ever saw the picture (5 September 2026).
        final media = session(
          _update(
            localPeerId: _local,
            participants: [
              _participant(_remote),
              _participant('carol-session'),
            ],
            topology: SignalingTopology.externalMcu,
          ),
          withControl: true,
        );
        addTearDown(media.dispose);
        await media.start();

        await media.setScreenSharing(true);
        await pumpEventQueue();
        final offers = sent
            .where((message) => message.type == 'sendoffer')
            .toList(growable: false);
        expect(offers.map((message) => message.recipient?.value).toSet(), {
          _remote,
          'carol-session',
        });
        expect(offers.every((message) => message.roomType == 'screen'), isTrue);
        // The publish itself still goes to this side's own session only.
        expect(
          offers.every((message) => message.recipient?.value != _local),
          isTrue,
        );

        // Stopping tells them too: their subscription is not closed by the
        // message that drops the publisher, which is addressed to this side.
        sent.clear();
        await media.setScreenSharing(false);
        await pumpEventQueue();
        final stops = sent
            .where(
              (message) =>
                  message.type == 'unshareScreen' &&
                  message.recipient?.value != _local,
            )
            .toList(growable: false);
        expect(stops.map((message) => message.recipient?.value).toSet(), {
          _remote,
          'carol-session',
        });
        expect(stops.every((message) => message.roomType == 'screen'), isTrue);
      },
    );

    test('through an MCU the answer to the screen publish is accepted', () async {
      // The answer comes back from this side's OWN session id, exactly like the
      // audio/video publisher's, and is told apart by its sid and room type.
      // Routing it by the publisher alone dropped it silently and made the
      // server look like it never answered.
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
      await media.setScreenSharing(true);
      await pumpEventQueue();
      final share = engine.connections.last;
      final offer = sent.lastWhere((message) => message.type == 'offer');
      expect(offer.roomType, 'screen');

      updates.add(
        _update(
          localPeerId: _local,
          participants: [_participant(_remote)],
          topology: SignalingTopology.externalMcu,
          messages: [
            _message(
              _local,
              'answer',
              <String, Object?>{'type': 'answer', 'sdp': 'mcu-screen-answer'},
              sid: offer.sid,
              roomType: 'screen',
            ),
          ],
        ),
      );
      await pumpEventQueue();
      expect(share.remoteDescriptions.single.sdp, 'mcu-screen-answer');
    });

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
  }
}
