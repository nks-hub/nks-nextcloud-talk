part of 'signaling_network_test.dart';

void _registerMediaReconnectNetworkTests() {
  test(
    'ambiguous media reconnect authenticates a new HPB session without replay',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = StreamIterator<HttpRequest>(server);
      addTearDown(() async {
        await requests.cancel();
        await server.close(force: true);
      });
      final authority = signalingAuthority();
      var snapshot = _configuredSnapshot(
        authority: authority,
        settingsData: signalingSettingsData(
          endpoint: 'http://127.0.0.1:${server.port}',
        ),
        endpointPolicy: SignalingEndpointPolicy.debug,
      );
      final initial = await _executeFullHpbHandshake(
        snapshot: snapshot,
        authority: authority,
        requests: requests,
        nowMicros: 1000,
        idBase: 1100,
        sessionId: 'old-hpb-session',
        resumeId: 'old-hpb-resume',
      );
      snapshot = initial.snapshot;
      final oldEpoch = snapshot.accounts[signalingAccountA]!.roomEpoch;
      final sending = planHpbPeerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(1104),
        effectId: signalingEffectId(1104),
        message: _mediaOffer('old-hpb-session', 'old-media'),
      );
      snapshot = commitSignaling(snapshot, sending);
      final oldSend = sending.effects.single as SendHpbFrameEffect;
      _sendText(initial.pair.client, oldSend.frame.encode());
      final oldWire = await _nextJson(initial.pair.serverEvents);
      expect(((oldWire['message'] as Map)['data'] as Map)['sid'], 'old-media');
      // The peer read the bytes but this host never committed send completion.
      await initial.pair.server.close();
      await _expectRemoteClose(initial.pair.clientEvents);
      await initial.pair.cancel();
      final disconnect = recordHpbDisconnect(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        nowMicros: 2000,
        jitterUnit: 0,
        deadlineEffectId: signalingEffectId(1105),
        outboundPossiblySent: true,
      );
      snapshot = commitSignaling(snapshot, disconnect);
      expect(
        snapshot.accounts[signalingAccountA]!.renegotiationRequired,
        isTrue,
      );
      final deadline =
          disconnect.effects.single as ScheduleSignalingDeadlineEffect;
      final renewed = await _executeFullHpbHandshake(
        snapshot: snapshot,
        authority: authority,
        requests: requests,
        nowMicros: deadline.deadlineMicros,
        completedDeadline: deadline,
        idBase: 1110,
        sessionId: 'new-hpb-session',
        resumeId: 'new-hpb-resume',
      );
      snapshot = renewed.snapshot;
      final current = snapshot.accounts[signalingAccountA]!;
      expect(renewed.hello.containsKey('resumeid'), isFalse);
      expect(renewed.hello.containsKey('auth'), isTrue);
      expect(renewed.room['sessionid'], authority.nextcloudSessionId.value);
      expect(current.hpbSessionId!.value, 'new-hpb-session');
      expect(current.connectionEpoch, 2);
      expect(current.roomEpoch, oldEpoch + 1);
      expect(current.renegotiationRequired, isFalse);
      expect(current.roomConfirmed, isTrue);
      expect(current.participants, isEmpty);
      expect(
        completeHpbFrameSend(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          effect: oldSend,
        ).outcome,
        SignalingRuntimeOutcome.rejected,
      );

      final update = <String, Object?>{
        'type': 'event',
        'event': <String, Object?>{
          'target': 'participants',
          'type': 'update',
          'update': <String, Object?>{
            'roomid': signalingRoomA.value,
            'users': <Object?>[
              <String, Object?>{'sessionId': 'current-peer', 'inCall': 7},
            ],
          },
        },
      };
      _sendJson(renewed.pair.server, update);
      final frame = HpbServerFrame.decode(
        await _nextText(renewed.pair.clientEvents),
      );
      expect(
        applyHpbServerFrame(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          connectionEpoch: 1,
          roomEpoch: oldEpoch,
          frame: frame,
          nowMicros: deadline.deadlineMicros + 500,
        ).outcome,
        SignalingRuntimeOutcome.rejected,
      );
      expect(
        applyHpbServerFrame(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          connectionEpoch: 2,
          roomEpoch: oldEpoch,
          frame: frame,
          nowMicros: deadline.deadlineMicros + 500,
        ).outcome,
        SignalingRuntimeOutcome.rejected,
      );
      snapshot = commitSignaling(
        snapshot,
        applyHpbServerFrame(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          connectionEpoch: 2,
          roomEpoch: current.roomEpoch,
          frame: frame,
          nowMicros: deadline.deadlineMicros + 500,
        ),
      );
      expect(
        snapshot.accounts[signalingAccountA]!.participants.values.single.inCall,
        7,
      );

      final messages = [
        _mediaOffer('new-hpb-session', 'new-media'),
        SignalingPeerMessage(
          type: 'requestoffer',
          roomType: 'video',
          sid: 'new-subscriber',
          recipient: SignalingPeerId.parse('current-peer'),
          sender: null,
          payload: null,
        ),
      ];
      for (var index = 0; index < messages.length; index++) {
        final plan = planHpbPeerFrame(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          requestId: signalingRequestId(1120 + index),
          effectId: signalingEffectId(1120 + index),
          message: messages[index],
        );
        snapshot = commitSignaling(snapshot, plan);
        final send = plan.effects.single as SendHpbFrameEffect;
        _sendText(renewed.pair.client, send.frame.encode());
        final wire = await _nextJson(renewed.pair.serverEvents);
        expect(
          ((wire['message'] as Map)['data'] as Map)['sid'],
          messages[index].sid,
        );
        snapshot = commitSignaling(
          snapshot,
          completeHpbFrameSend(
            snapshot,
            accountId: signalingAccountA,
            authority: authority,
            effect: send,
          ),
        );
      }
      expect(snapshot.accounts[signalingAccountA]!.signalingReady, isTrue);
      await renewed.pair.server.close();
      await _expectRemoteClose(renewed.pair.clientEvents);
      await renewed.pair.cancel();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

SignalingPeerMessage _mediaOffer(String recipient, String sid) =>
    SignalingPeerMessage(
      type: 'offer',
      roomType: 'video',
      sid: sid,
      recipient: SignalingPeerId.parse(recipient),
      sender: null,
      payload: SignalingOpaquePayload.fromJson({
        'type': 'offer',
        'sdp': 'v=0\r\n',
      }),
    );
