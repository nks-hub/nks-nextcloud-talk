import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/signaling_test_support.dart';

void main() {
  group('HPB hello selection', () {
    test('welcome timeout uses the legacy V1 authentication fallback', () {
      final authority = signalingAuthority();
      var snapshot = configuredSignalingSnapshot();
      final connect = planSignalingConnect(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        nowMicros: 1000,
        effectId: signalingEffectId(500),
      );
      snapshot = commitSignaling(snapshot, connect);
      final opened = completeHpbSocketOpen(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        effect: connect.effects.single as OpenHpbSocketEffect,
        deadlineEffectId: signalingEffectId(501),
        nowMicros: 1100,
      );
      snapshot = commitSignaling(snapshot, opened);
      final deadline = opened.effects.single as ScheduleSignalingDeadlineEffect;

      final timedOut = handleHpbWelcomeTimeout(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        effect: deadline,
        nowMicros: deadline.deadlineMicros,
        requestId: signalingRequestId(502),
        sendEffectId: signalingEffectId(502),
      );
      final hello = (timedOut.effects.single as SendHpbFrameEffect).frame;

      expect(hello, isA<HpbHelloClientFrame>());
      expect((hello as HpbHelloClientFrame).version, HpbHelloVersion.v1);
      expect(hello.isResume, isFalse);
    });

    test('missing V1 fallback becomes unsupported without sending a frame', () {
      final authority = signalingAuthority();
      final data = signalingSettingsData();
      final auth = data['helloAuthParams']! as Map<String, Object?>;
      auth.remove('1.0');
      var snapshot = _configuredExternalSnapshot(data);
      final connect = planSignalingConnect(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        nowMicros: 2000,
        effectId: signalingEffectId(503),
      );
      snapshot = commitSignaling(snapshot, connect);
      final opened = completeHpbSocketOpen(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        effect: connect.effects.single as OpenHpbSocketEffect,
        deadlineEffectId: signalingEffectId(504),
        nowMicros: 2100,
      );
      snapshot = commitSignaling(snapshot, opened);
      final deadline = opened.effects.single as ScheduleSignalingDeadlineEffect;

      final timedOut = handleHpbWelcomeTimeout(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        effect: deadline,
        nowMicros: deadline.deadlineMicros,
        requestId: signalingRequestId(505),
        sendEffectId: signalingEffectId(505),
      );
      snapshot = commitSignaling(snapshot, timedOut);

      expect(timedOut.outcome, SignalingRuntimeOutcome.unsupported);
      expect(timedOut.effects, isEmpty);
      expect(
        snapshot.accounts[signalingAccountA]!.phase,
        SignalingAccountPhase.unsupported,
      );
    });

    test('welcome features select V2 and MCU topology', () {
      final pending = externalHelloPendingSnapshot();
      final effect =
          pending.snapshot.accounts[signalingAccountA]!.pendingHpbFrame!;
      final hello = effect.frame as HpbHelloClientFrame;

      expect(hello.version, HpbHelloVersion.v2);
      expect(hello.isResume, isFalse);
      expect(
        pending.snapshot.accounts[signalingAccountA]!.topology,
        SignalingTopology.externalMcu,
      );
    });
  });

  group('HPB resume lifecycle', () {
    test(
      'resume is selected inside the window and full hello after expiry',
      () {
        final beforeExpiry = _planHelloAfterDisconnect(
          nowMicros: 10000,
          reconnectMicros: 1010000,
          requestNumber: 510,
        );
        expect(beforeExpiry.hello.isResume, isTrue);

        final afterExpiry = _planHelloAfterDisconnect(
          nowMicros: 10000,
          reconnectMicros: 30010000,
          requestNumber: 520,
        );
        expect(afterExpiry.hello.isResume, isFalse);
        expect(afterExpiry.hello.version, HpbHelloVersion.v2);
        expect(afterExpiry.account.participants, isEmpty);
        expect(afterExpiry.account.renegotiationRequired, isTrue);
      },
    );

    test('successful resume preserves ambiguous outbound renegotiation', () {
      final authority = signalingAuthority();
      final prepared = _planHelloAfterDisconnect(
        nowMicros: 15000,
        reconnectMicros: 1015000,
        requestNumber: 525,
        outboundPossiblySent: true,
      );
      var snapshot = prepared.snapshot;
      final send = snapshot.accounts[signalingAccountA]!.pendingHpbFrame!;
      snapshot = commitSignaling(
        snapshot,
        completeHpbFrameSend(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          effect: send,
        ),
      );

      final resumed = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 2,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': send.frame.requestId.value,
          'type': 'hello',
          'hello': <String, Object?>{
            'version': '2.0',
            'sessionid': 'hpb-session-a',
          },
        }),
        nowMicros: 1015300,
      );
      snapshot = commitSignaling(snapshot, resumed);

      expect(resumed.outcome, SignalingRuntimeOutcome.resumed);
      expect(
        snapshot.accounts[signalingAccountA]!.renegotiationRequired,
        isTrue,
      );
    });

    test('a process restart leaves no federated state behind', () {
      var snapshot = externalReadySignalingSnapshot();
      // A federated participant is present and the federation is interrupted:
      // the state a restart must not carry over, because the socket, the
      // session and every peer are gone with the process.
      final account = snapshot.accounts[signalingAccountA]!;
      snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: account.copyWith(
            federationInterrupted: true,
            participants: <SignalingPeerId, SignalingParticipant>{
              SignalingPeerId.parse('federated-peer'): SignalingParticipant(
                peerId: SignalingPeerId.parse('federated-peer'),
                nextcloudSessionId: ConversationSessionId.parse('remote'),
                userId: 'someone',
                inCall: 7,
                permissions: 0,
                actorType: 'federated_users',
                actorId: 'someone@remote.invalid',
                federated: true,
                features: const <String>[],
              ),
            },
          ),
        },
      );

      snapshot = commitSignaling(
        snapshot,
        recoverSignalingAfterProcessRestart(
          snapshot,
          accountId: signalingAccountA,
        ),
      );
      final recovered = snapshot.accounts[signalingAccountA]!;

      expect(recovered.federationInterrupted, isFalse);
      expect(recovered.participants, isEmpty);
      // The federated endpoint is part of the settings, which are fetched
      // again rather than trusted from before the restart.
      expect(recovered.settings, isNull);
      expect(recovered.roomConfirmed, isFalse);
      expect(recovered.activeSocket, isFalse);
      // The epoch never goes backwards, so a late frame from before the
      // restart cannot be mistaken for a current one.
      expect(recovered.connectionEpoch, greaterThan(account.connectionEpoch));
      expect(recovered.roomEpoch, greaterThan(account.roomEpoch));
    });

    test('a peer message arrives while a frame of ours waits to be sent', () {
      final authority = signalingAuthority();
      var snapshot = externalReadySignalingSnapshot();
      // Something of ours is queued for the socket: an MCU answers the
      // publisher's offer at exactly this moment, and dropping it would lose
      // the call's only answer.
      final planned = planHpbPeerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(540),
        effectId: signalingEffectId(540),
        message: SignalingPeerMessage(
          type: 'offer',
          roomType: 'video',
          sid: 'publisher-1',
          recipient: SignalingPeerId.parse('hpb-session-a'),
          sender: null,
          payload: SignalingOpaquePayload.fromJson(<String, Object?>{
            'type': 'offer',
            'sdp': 'v=0',
          }),
        ),
      );
      snapshot = commitSignaling(snapshot, planned);
      expect(snapshot.accounts[signalingAccountA]!.pendingHpbFrame, isNotNull);

      final received = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: snapshot.accounts[signalingAccountA]!.connectionEpoch,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'type': 'message',
          'message': <String, Object?>{
            'sender': <String, Object?>{
              'type': 'session',
              'sessionid': 'hpb-session-a',
            },
            'data': <String, Object?>{
              'type': 'answer',
              'roomType': 'video',
              'sid': 'publisher-1',
              'payload': <String, Object?>{'type': 'answer', 'sdp': 'v=0'},
            },
          },
        }),
        nowMicros: 100000,
      );

      expect(received.outcome, SignalingRuntimeOutcome.messagesReceived);
      expect(received.messages.single.type, 'answer');
    });

    test('a full hello clears the renegotiation the lost session raised', () {
      final authority = signalingAuthority();
      // The resume window has passed, so the reconnect is a full hello and the
      // flag is up.
      final prepared = _planHelloAfterDisconnect(
        nowMicros: 10000,
        reconnectMicros: 30010000,
        requestNumber: 530,
      );
      expect(prepared.account.renegotiationRequired, isTrue);
      var snapshot = prepared.snapshot;
      final send = snapshot.accounts[signalingAccountA]!.pendingHpbFrame!;
      snapshot = commitSignaling(
        snapshot,
        completeHpbFrameSend(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          effect: send,
        ),
      );

      final welcomed = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 2,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': send.frame.requestId.value,
          'type': 'hello',
          'hello': <String, Object?>{
            'version': '2.0',
            'sessionid': 'hpb-session-b',
            'resumeid': 'hpb-resume-b',
          },
        }),
        nowMicros: 30010300,
        nextRequestId: signalingRequestId(534),
        sendEffectId: signalingEffectId(534),
      );
      snapshot = commitSignaling(snapshot, welcomed);

      // A new session in a new room epoch with no participants carried over:
      // every peer is rebuilt, which is what the flag was asking for.
      final account = snapshot.accounts[signalingAccountA]!;
      expect(account.renegotiationRequired, isFalse);
      expect(account.roomEpoch, greaterThan(prepared.account.roomEpoch));
      expect(account.participants, isEmpty);
    });

    test('failed reconnect does not extend the original resume window', () {
      final authority = signalingAuthority();
      final prepared = _planHelloAfterDisconnect(
        nowMicros: 25000,
        reconnectMicros: 1025000,
        requestNumber: 528,
      );
      final originalDeadline = prepared.account.resumeDeadlineMicros;

      final disconnectedAgain = recordHpbDisconnect(
        prepared.snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 2,
        nowMicros: 1030000,
        jitterUnit: 0,
        deadlineEffectId: signalingEffectId(529),
      );
      final snapshot = commitSignaling(prepared.snapshot, disconnectedAgain);

      expect(originalDeadline, 30025000);
      expect(
        snapshot.accounts[signalingAccountA]!.resumeDeadlineMicros,
        originalDeadline,
      );
    });

    test('no_such_session replaces resume with a full hello', () {
      final authority = signalingAuthority();
      final prepared = _planHelloAfterDisconnect(
        nowMicros: 20000,
        reconnectMicros: 1020000,
        requestNumber: 530,
      );
      var snapshot = prepared.snapshot;
      final send = snapshot.accounts[signalingAccountA]!.pendingHpbFrame!;
      snapshot = commitSignaling(
        snapshot,
        completeHpbFrameSend(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          effect: send,
        ),
      );

      final result = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 2,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': send.frame.requestId.value,
          'type': 'error',
          'error': <String, Object?>{
            'code': 'no_such_session',
            'message': 'Synthetic expired session',
          },
        }),
        nowMicros: 1030000,
        nextRequestId: signalingRequestId(533),
        sendEffectId: signalingEffectId(533),
      );
      final replacement = (result.effects.single as SendHpbFrameEffect).frame;

      expect(result.outcome, SignalingRuntimeOutcome.helloSending);
      expect(replacement, isA<HpbHelloClientFrame>());
      expect((replacement as HpbHelloClientFrame).isResume, isFalse);
      expect(replacement.version, HpbHelloVersion.v2);
    });
  });

  group('HPB room error handling', () {
    test('room confirmation preserves required renegotiation', () {
      final pending = _roomPending();
      final authority = signalingAuthority();
      final account = pending.snapshot.accounts[signalingAccountA]!;
      final snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: account.copyWith(renegotiationRequired: true),
        },
      );

      final accepted = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': pending.frame.requestId.value,
          'type': 'room',
          'room': <String, Object?>{'roomid': 'rooma123'},
        }),
        nowMicros: 2900,
      );
      final committed = commitSignaling(snapshot, accepted);

      expect(
        committed.accounts[signalingAccountA]!.renegotiationRequired,
        isTrue,
      );
    });

    test('already_joined confirms only the requested room', () {
      final pending = _roomPending();
      final authority = signalingAuthority();
      final accepted = applyHpbServerFrame(
        pending.snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: pending.snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': pending.frame.requestId.value,
          'type': 'error',
          'error': <String, Object?>{
            'code': 'already_joined',
            'message': 'Synthetic room state',
            'details': <String, Object?>{
              'room': <String, Object?>{'roomid': 'rooma123'},
            },
          },
        }),
        nowMicros: 3000,
      );

      expect(accepted.outcome, SignalingRuntimeOutcome.signalingReady);

      final foreign = applyHpbServerFrame(
        pending.snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: pending.snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': pending.frame.requestId.value,
          'type': 'error',
          'error': <String, Object?>{
            'code': 'already_joined',
            'message': 'Synthetic foreign room',
            'details': <String, Object?>{
              'room': <String, Object?>{'roomid': 'roomb123'},
            },
          },
        }),
        nowMicros: 3000,
        closeEffectId: signalingEffectId(540),
      );
      expect(foreign.outcome, SignalingRuntimeOutcome.terminated);
      expect(foreign.effects.single, isA<CloseHpbSocketEffect>());
    });

    test('no_such_room closes HPB and requests a fresh PHP session', () {
      final pending = _roomPending();
      final result = applyHpbServerFrame(
        pending.snapshot,
        accountId: signalingAccountA,
        authority: signalingAuthority(),
        connectionEpoch: 1,
        roomEpoch: pending.snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': pending.frame.requestId.value,
          'type': 'error',
          'error': <String, Object?>{
            'code': 'no_such_room',
            'message': 'Synthetic stale PHP session',
          },
        }),
        nowMicros: 3100,
        refreshEffectId: signalingEffectId(541),
        closeEffectId: signalingEffectId(542),
      );

      expect(
        result.outcome,
        SignalingRuntimeOutcome.roomSessionRefreshRequired,
      );
      expect(result.effects.whereType<CloseHpbSocketEffect>(), hasLength(1));
      expect(
        result.effects.whereType<RefreshConversationSessionEffect>(),
        hasLength(1),
      );
    });
  });

  group('internal signaling status matrix', () {
    test('maps 400, 401, 404, 409 and 500 without state leakage', () {
      final expected = <int, SignalingRuntimeOutcome>{
        400: SignalingRuntimeOutcome.settingsRefreshRequired,
        401: SignalingRuntimeOutcome.reauthenticationRequired,
        404: SignalingRuntimeOutcome.roomSessionRefreshRequired,
        409: SignalingRuntimeOutcome.terminated,
        500: SignalingRuntimeOutcome.unchanged,
      };

      for (final entry in expected.entries) {
        final authority = signalingAuthority();
        var snapshot = configuredSignalingSnapshot(mode: 'internal');
        final pull = planInternalSignalingPull(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          requestId: signalingRequestId(550 + entry.key),
        );
        snapshot = commitSignaling(snapshot, pull);
        final response = decodeInternalSignalingPullResponse(
          request: pull.request! as InternalSignalingPullRequest,
          statusCode: entry.key,
          body: signalingOcsBody(statusCode: entry.key, data: null),
        );
        final result = applyInternalSignalingPullResponse(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          response: response,
          refreshEffectId: entry.key == 404 ? signalingEffectId(600) : null,
        );
        snapshot = commitSignaling(snapshot, result);
        final account = snapshot.accounts[signalingAccountA]!;

        expect(result.outcome, entry.value, reason: 'HTTP ${entry.key}');
        expect(account.pendingInternalPull, isNull);
        expect(account.pendingInternalBatch, isNull);
      }
    });

    test(
      'successful pull atomically publishes messages and full participants',
      () {
        final authority = signalingAuthority();
        var snapshot = configuredSignalingSnapshot(mode: 'internal');
        final pull = planInternalSignalingPull(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          requestId: signalingRequestId(601),
        );
        snapshot = commitSignaling(snapshot, pull);
        final response = decodeInternalSignalingPullResponse(
          request: pull.request! as InternalSignalingPullRequest,
          statusCode: 200,
          body: signalingOcsBody(
            statusCode: 200,
            data: <Object?>[
              <String, Object?>{
                'type': 'message',
                'data': jsonEncode(<String, Object?>{
                  'type': 'offer',
                  'roomType': 'video',
                  'from': 'peer-a',
                  'payload': <String, Object?>{'sdp': 'synthetic-sdp'},
                }),
              },
              <String, Object?>{
                'type': 'usersInRoom',
                'data': <Object?>[_internalParticipant()],
              },
            ],
          ),
        );
        final result = applyInternalSignalingPullResponse(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          response: response,
        );
        snapshot = commitSignaling(snapshot, result);

        expect(result.outcome, SignalingRuntimeOutcome.messagesReceived);
        expect(result.messages, hasLength(1));
        expect(
          snapshot.accounts[signalingAccountA]!.participants,
          hasLength(1),
        );
        expect(snapshot.accounts[signalingAccountA]!.roomConfirmed, isTrue);
      },
    );
  });

  test(
    'reconnect delay is bounded exponential backoff with deterministic jitter',
    () {
      expect(
        <int>[
          for (var attempt = 1; attempt <= 7; attempt++)
            computeSignalingReconnectDelayMicros(
              attempt: attempt,
              jitterUnit: 0,
            ),
        ],
        <int>[1000000, 2000000, 4000000, 8000000, 16000000, 16000000, 16000000],
      );
      expect(
        computeSignalingReconnectDelayMicros(attempt: 5, jitterUnit: 1000000),
        20000000,
      );
    },
  );
}

SignalingRuntimeSnapshot _configuredExternalSnapshot(
  Map<String, Object?> data,
) {
  final authority = signalingAuthority();
  var snapshot = emptySignalingSnapshot();
  snapshot = commitSignaling(
    snapshot,
    addSignalingAccount(snapshot, authority: authority),
  );
  final fetch = planSignalingSettingsFetch(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    requestId: signalingRequestId(700),
  );
  snapshot = commitSignaling(snapshot, fetch);
  return commitSignaling(
    snapshot,
    applySignalingSettingsResponse(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      response: decodeSignalingSettingsResponse(
        request: fetch.request! as SignalingSettingsRequest,
        statusCode: 200,
        body: signalingOcsBody(statusCode: 200, data: data),
      ),
    ),
  );
}

({
  SignalingRuntimeSnapshot snapshot,
  HpbHelloClientFrame hello,
  SignalingAccountState account,
})
_planHelloAfterDisconnect({
  required int nowMicros,
  required int reconnectMicros,
  required int requestNumber,
  bool outboundPossiblySent = false,
}) {
  final authority = signalingAuthority();
  var snapshot = externalReadySignalingSnapshot();
  final disconnected = recordHpbDisconnect(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: 1,
    nowMicros: nowMicros,
    jitterUnit: 0,
    deadlineEffectId: signalingEffectId(requestNumber),
    outboundPossiblySent: outboundPossiblySent,
  );
  snapshot = commitSignaling(snapshot, disconnected);
  final deadline =
      disconnected.effects.single as ScheduleSignalingDeadlineEffect;
  final connect = planSignalingConnect(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    nowMicros: reconnectMicros,
    effectId: signalingEffectId(requestNumber + 1),
    completedDeadline: deadline,
  );
  snapshot = commitSignaling(snapshot, connect);
  final opened = completeHpbSocketOpen(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    effect: connect.effects.single as OpenHpbSocketEffect,
    deadlineEffectId: signalingEffectId(requestNumber + 2),
    nowMicros: reconnectMicros + 10,
  );
  snapshot = commitSignaling(snapshot, opened);
  final welcomed = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: 2,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: decodeHpbFrame(<String, Object?>{
      'type': 'welcome',
      'welcome': <String, Object?>{
        'features': <Object?>['hello-v2', 'mcu'],
      },
    }),
    nowMicros: reconnectMicros + 20,
    nextRequestId: signalingRequestId(requestNumber + 2),
    sendEffectId: signalingEffectId(requestNumber + 3),
  );
  snapshot = commitSignaling(snapshot, welcomed);
  final hello = (welcomed.effects.single as SendHpbFrameEffect).frame;
  return (
    snapshot: snapshot,
    hello: hello as HpbHelloClientFrame,
    account: snapshot.accounts[signalingAccountA]!,
  );
}

({SignalingRuntimeSnapshot snapshot, HpbRoomClientFrame frame}) _roomPending() {
  final authority = signalingAuthority();
  final pending = externalHelloPendingSnapshot();
  var snapshot = pending.snapshot;
  snapshot = commitSignaling(
    snapshot,
    completeHpbFrameSend(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      effect: pending.helloEffect,
    ),
  );
  final hello = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: 1,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: decodeHpbFrame(<String, Object?>{
      'id': pending.helloEffect.frame.requestId.value,
      'type': 'hello',
      'hello': <String, Object?>{
        'version': '2.0',
        'sessionid': 'hpb-session-room-test',
        'resumeid': 'hpb-resume-room-test',
      },
    }),
    nowMicros: 2500,
    nextRequestId: signalingRequestId(710),
    sendEffectId: signalingEffectId(710),
  );
  snapshot = commitSignaling(snapshot, hello);
  final roomEffect = hello.effects.single as SendHpbFrameEffect;
  snapshot = commitSignaling(
    snapshot,
    completeHpbFrameSend(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      effect: roomEffect,
    ),
  );
  return (snapshot: snapshot, frame: roomEffect.frame as HpbRoomClientFrame);
}

Map<String, Object?> _internalParticipant() => <String, Object?>{
  'sessionId': 'internal-peer-a',
  'roomId': 42,
  'lastPing': 100,
  'userId': 'internal-user-a',
  'inCall': 3,
  'participantPermissions': 7,
  'actorType': 'users',
  'actorId': 'internal-user-a',
};
