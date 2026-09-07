part of 'call_media_session_test.dart';

extension _ControlsMediaSessionTests on _MediaSessionTests {
  void _registerControls() {
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

    // A live two-Chrome capture on 7 September 2026 saw exactly six frame
    // types on Talk's `status` data channel and nothing else: audioOn/Off,
    // videoOn/Off, speaking/stoppedSpeaking. These tests cover the peer-to-peer
    // side of that channel; the ordinary `mute`/`unmute`/`raiseHand` signalling
    // messages it rides beside are covered above and in the hand-raise test.
    group('status data channel', () {
      test('opens on a call connection and never on a screen share', () async {
        final media = session(
          _update(localPeerId: _local, participants: [_participant(_remote)]),
        );
        addTearDown(media.dispose);
        await media.start();

        final call = engine.connections.single;
        expect(call.onStatusMessage, isNotNull);

        await media.setScreenSharing(true);
        final share = engine.connections.last;
        expect(share.onStatusMessage, isNull);
        expect(share.sendStatus('audioOn'), isFalse);
      });

      test('the microphone toggle sends audioOff and audioOn', () async {
        final media = session(
          _update(localPeerId: _local, participants: [_participant(_remote)]),
        );
        addTearDown(media.dispose);
        await media.start();
        final connection = engine.connections.single;
        // The initial announce when the peer was created.
        expect(connection.sentStatus.map((frame) => frame.type), [
          'audioOn',
          'videoOff',
        ]);

        // Every announce carries both facts, like the mute/unmute pair above.
        await media.setMicrophoneMuted(true);
        expect(
          connection.sentStatus.map((frame) => frame.type).toList().sublist(2),
          ['audioOff', 'videoOff'],
        );

        await media.setMicrophoneMuted(false);
        expect(
          connection.sentStatus.map((frame) => frame.type).toList().sublist(4),
          ['audioOn', 'videoOff'],
        );
      });

      test('the camera toggle sends videoOn and videoOff', () async {
        final media = session(
          _update(localPeerId: _local, participants: [_participant(_remote)]),
        );
        addTearDown(media.dispose);
        await media.start();
        final connection = engine.connections.single;

        await media.setCameraEnabled(true);
        expect(connection.sentStatus.last, (type: 'videoOn', payload: null));

        await media.setCameraEnabled(false);
        expect(connection.sentStatus.last, (type: 'videoOff', payload: null));
      });

      test('through an MCU this side sends once, on the publisher', () async {
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
        expect(publisher.onStatusMessage, isNotNull);

        await media.setMicrophoneMuted(true);
        expect(
          publisher.sentStatus.map((frame) => frame.type),
          contains('audioOff'),
        );
      });

      test('an incoming audioOff/audioOn frame updates the same state the '
          'mute/unmute signalling message does', () async {
        final media = session(
          _update(localPeerId: _local, participants: [_participant(_remote)]),
        );
        addTearDown(media.dispose);
        await media.start();
        final connection = engine.connections.single;

        connection.receiveStatus('audioOff');
        await pumpEventQueue();
        expect(media.state.participants.single.audioMuted, isTrue);

        connection.receiveStatus('audioOn');
        await pumpEventQueue();
        expect(media.state.participants.single.audioMuted, isFalse);
      });

      test(
        'an incoming speaking/stoppedSpeaking frame updates the peer state',
        () async {
          final media = session(
            _update(localPeerId: _local, participants: [_participant(_remote)]),
          );
          addTearDown(media.dispose);
          await media.start();
          final connection = engine.connections.single;

          expect(media.state.participants.single.speaking, isFalse);
          connection.receiveStatus('speaking');
          await pumpEventQueue();
          expect(media.state.participants.single.speaking, isTrue);

          connection.receiveStatus('stoppedSpeaking');
          await pumpEventQueue();
          expect(media.state.participants.single.speaking, isFalse);
        },
      );

      test('a peer that leaves the call is forgotten', () async {
        final media = session(
          _update(localPeerId: _local, participants: [_participant(_remote)]),
        );
        addTearDown(media.dispose);
        await media.start();
        engine.connections.single.receiveStatus('speaking');
        await pumpEventQueue();
        expect(media.state.participants.single.speaking, isTrue);

        updates.add(_update(localPeerId: _local, participants: []));
        await pumpEventQueue();
        expect(media.state.participants, isEmpty);
      });
    });

    // The web client keys a peer connection by `sid`; a message with a foreign
    // or missing one opens a new connection or is dropped.
  }
}
