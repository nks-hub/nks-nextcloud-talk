import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/signaling_test_support.dart';

void main() {
  group('signaling runtime binding', () {
    test('settings 404 at connection epoch zero emits room refresh', () {
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
        requestId: signalingRequestId(1),
      );
      snapshot = commitSignaling(snapshot, fetch);
      final result = applySignalingSettingsResponse(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        response: decodeSignalingSettingsResponse(
          request: fetch.request! as SignalingSettingsRequest,
          statusCode: 404,
          body: signalingOcsBody(statusCode: 404, data: null),
        ),
        refreshEffectId: signalingEffectId(1),
      );

      expect(
        result.outcome,
        SignalingRuntimeOutcome.roomSessionRefreshRequired,
      );
      expect(result.effects.single, isA<RefreshConversationSessionEffect>());
      expect(result.effects.single.context.connectionEpoch, 0);
    });

    test('settings refresh preserves required renegotiation', () {
      final authority = signalingAuthority();
      var snapshot = emptySignalingSnapshot();
      snapshot = commitSignaling(
        snapshot,
        addSignalingAccount(snapshot, authority: authority),
      );
      final account = snapshot.accounts[signalingAccountA]!;
      snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: account.copyWith(
            phase: SignalingAccountPhase.settingsRefreshRequired,
            renegotiationRequired: true,
          ),
        },
      );
      final fetch = planSignalingSettingsFetch(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(2),
      );
      snapshot = commitSignaling(snapshot, fetch);
      final applied = applySignalingSettingsResponse(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        response: decodeSignalingSettingsResponse(
          request: fetch.request! as SignalingSettingsRequest,
          statusCode: 200,
          body: signalingOcsBody(
            statusCode: 200,
            data: signalingSettingsData(),
          ),
        ),
      );
      snapshot = commitSignaling(snapshot, applied);

      expect(
        snapshot.accounts[signalingAccountA]!.renegotiationRequired,
        isTrue,
      );
    });

    test('stale connection or room epochs cannot mutate a newer session', () {
      final authority = signalingAuthority();
      final snapshot = externalReadySignalingSnapshot();
      final currentRoomEpoch = snapshot.accounts[signalingAccountA]!.roomEpoch;
      final frame = decodeHpbFrame(<String, Object?>{
        'type': 'event',
        'event': <String, Object?>{
          'target': 'room',
          'type': 'join',
          'join': <Object?>[
            <String, Object?>{
              'sessionid': 'peer-new',
              'userid': 'user-new',
              'roomsessionid': 'nextcloud-peer-new',
            },
          ],
        },
      });

      final stale = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 0,
        roomEpoch: currentRoomEpoch,
        frame: frame,
        nowMicros: 2000,
      );
      expect(stale.outcome, SignalingRuntimeOutcome.rejected);
      expect(stale.canCommit, isFalse);

      final staleRoom = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: currentRoomEpoch - 1,
        frame: frame,
        nowMicros: 2000,
      );
      expect(staleRoom.outcome, SignalingRuntimeOutcome.rejected);
      expect(staleRoom.canCommit, isFalse);

      final current = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: currentRoomEpoch,
        frame: frame,
        nowMicros: 2000,
      );
      final committed = commitSignaling(snapshot, current);
      expect(committed.accounts[signalingAccountA]!.participants, hasLength(1));
    });

    test('server response waits until the pending frame is sent', () {
      final authority = signalingAuthority();
      final pending = externalHelloPendingSnapshot();
      var snapshot = pending.snapshot;
      final response = decodeHpbFrame(<String, Object?>{
        'id': 'signaling-request-103',
        'type': 'hello',
        'hello': <String, Object?>{
          'version': '2.0',
          'sessionid': 'hpb-session-a',
          'resumeid': 'hpb-resume-a',
        },
      });

      expect(
        applyHpbServerFrame(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          connectionEpoch: 1,
          roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
          frame: response,
          nowMicros: 3000,
          nextRequestId: signalingRequestId(105),
          sendEffectId: signalingEffectId(105),
        ).outcome,
        SignalingRuntimeOutcome.rejected,
      );

      snapshot = commitSignaling(
        snapshot,
        completeHpbFrameSend(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          effect: pending.helloEffect,
        ),
      );
      final accepted = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: response,
        nowMicros: 3000,
        nextRequestId: signalingRequestId(105),
        sendEffectId: signalingEffectId(105),
      );
      expect(accepted.outcome, SignalingRuntimeOutcome.roomJoining);
    });
  });

  group('signaling participant state', () {
    test('all participant update changes incall without replacing peers', () {
      final authority = signalingAuthority();
      var snapshot = externalReadySignalingSnapshot();
      final account = snapshot.accounts[signalingAccountA]!;
      final first = signalingParticipant(peerId: 'peer-a', inCall: 1);
      final second = signalingParticipant(peerId: 'peer-b', inCall: 2);
      snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: account.copyWith(
            participants: <SignalingPeerId, SignalingParticipant>{
              first.peerId: first,
              second.peerId: second,
            },
          ),
        },
      );

      final result = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'type': 'event',
          'event': <String, Object?>{
            'target': 'participants',
            'type': 'update',
            'update': <String, Object?>{
              'roomid': 'rooma123',
              'all': true,
              'incall': 3,
            },
          },
        }),
        nowMicros: 4000,
      );
      snapshot = commitSignaling(snapshot, result);

      expect(
        snapshot.accounts[signalingAccountA]!.participants.values.map(
          (participant) => participant.inCall,
        ),
        everyElement(3),
      );
    });

    test('failed federation resume removes only federated peers', () {
      final authority = signalingAuthority();
      var snapshot = externalReadySignalingSnapshot();
      final account = snapshot.accounts[signalingAccountA]!;
      final local = signalingParticipant(peerId: 'peer-local');
      final remote = signalingParticipant(
        peerId: 'peer-remote',
        federated: true,
      );
      snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: account.copyWith(
            participants: <SignalingPeerId, SignalingParticipant>{
              local.peerId: local,
              remote.peerId: remote,
            },
          ),
        },
      );

      final result = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'type': 'event',
          'event': <String, Object?>{
            'target': 'room',
            'type': 'federation_resumed',
            'resumed': false,
          },
        }),
        nowMicros: 5000,
      );
      snapshot = commitSignaling(snapshot, result);
      final participants = snapshot.accounts[signalingAccountA]!.participants;

      expect(participants.keys, contains(local.peerId));
      expect(participants.keys, isNot(contains(remote.peerId)));
      expect(result.outcome, SignalingRuntimeOutcome.renegotiationRequired);
    });

    test('inbound frames require a sender in the current room snapshot', () {
      final snapshot = externalReadySignalingSnapshot();
      final authority = signalingAuthority();

      final message = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: _inboundMessageFrame('peer-stale'),
        nowMicros: 5100,
      );
      final control = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: _inboundControlFrame('peer-stale'),
        nowMicros: 5100,
      );

      expect(message.outcome, SignalingRuntimeOutcome.rejected);
      expect(message.messages, isEmpty);
      expect(control.outcome, SignalingRuntimeOutcome.rejected);
      expect(control.controls, isEmpty);
    });

    test('federation interruption blocks only federated inbound peers', () {
      final authority = signalingAuthority();
      final ready = externalReadySignalingSnapshot();
      final account = ready.accounts[signalingAccountA]!;
      final local = signalingParticipant(peerId: 'peer-local');
      final remote = signalingParticipant(
        peerId: 'peer-remote',
        federated: true,
      );
      final snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: account.copyWith(
            federationInterrupted: true,
            participants: <SignalingPeerId, SignalingParticipant>{
              local.peerId: local,
              remote.peerId: remote,
            },
          ),
        },
      );

      final remoteResult = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: _inboundMessageFrame('peer-remote'),
        nowMicros: 5200,
      );
      final localResult = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: _inboundMessageFrame('peer-local'),
        nowMicros: 5200,
      );

      expect(remoteResult.outcome, SignalingRuntimeOutcome.rejected);
      expect(localResult.outcome, SignalingRuntimeOutcome.messagesReceived);
      expect(localResult.messages, hasLength(1));
    });

    test('state and snapshot defensively copy caller-owned maps', () {
      final initial = SignalingAccountState.initial(
        authority: signalingAuthority(),
      );
      final participant = signalingParticipant();
      final participants = <SignalingPeerId, SignalingParticipant>{
        participant.peerId: participant,
      };
      final copied = initial.copyWith(participants: participants);
      participants.clear();
      expect(copied.participants, hasLength(1));

      final accounts = <AccountId, SignalingAccountState>{
        signalingAccountA: copied,
      };
      final snapshot = SignalingRuntimeSnapshot(accounts: accounts);
      accounts.clear();
      expect(snapshot.accounts, hasLength(1));
    });
  });

  group('signaling failure transitions', () {
    test('HPB rate limit closes the socket and uses a backoff gate', () {
      final authority = signalingAuthority();
      final pending = externalHelloPendingSnapshot();
      var snapshot = commitSignaling(
        pending.snapshot,
        completeHpbFrameSend(
          pending.snapshot,
          accountId: signalingAccountA,
          authority: authority,
          effect: pending.helloEffect,
        ),
      );
      final result = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'id': 'signaling-request-103',
          'type': 'error',
          'error': <String, Object?>{
            'code': 'too_many_requests',
            'message': 'Synthetic rate limit',
          },
        }),
        nowMicros: 6000,
        deadlineEffectId: signalingEffectId(106),
        closeEffectId: signalingEffectId(107),
      );

      expect(result.effects.whereType<CloseHpbSocketEffect>(), hasLength(1));
      final deadline = result.effects
          .whereType<ScheduleSignalingDeadlineEffect>()
          .single;
      expect(deadline.kind, SignalingDeadlineKind.backoff);
      snapshot = commitSignaling(snapshot, result);
      expect(snapshot.accounts[signalingAccountA]!.activeSocket, isFalse);
      expect(
        snapshot.accounts[signalingAccountA]!.phase,
        SignalingAccountPhase.reconnectWaiting,
      );
    });

    test('server bye emits a close effect before termination', () {
      final authority = signalingAuthority();
      final snapshot = externalReadySignalingSnapshot();
      final result = applyHpbServerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
        frame: decodeHpbFrame(<String, Object?>{
          'type': 'bye',
          'bye': <String, Object?>{},
        }),
        nowMicros: 7000,
        closeEffectId: signalingEffectId(108),
      );

      expect(result.effects.single, isA<CloseHpbSocketEffect>());
      expect(result.outcome, SignalingRuntimeOutcome.terminated);
    });

    test('authority refresh closes an active socket', () {
      final snapshot = externalReadySignalingSnapshot();
      final result = refreshSignalingAuthority(
        snapshot,
        authority: signalingAuthority(
          credentialGeneration: 4,
          settingsRevision: 'signaling-revision-b',
        ),
        closeEffectId: signalingEffectId(109),
      );

      expect(result.effects.single, isA<CloseHpbSocketEffect>());
      expect(result.outcome, SignalingRuntimeOutcome.authorityRefreshed);
    });

    // The flag stops the runtime carrying anything but typing, so a media
    // session that sees it reports a lost signalling and gives up. It used to
    // survive a fresh authority, which made it permanent: once a batch of
    // unknown delivery or a process restart set it, every later call refused
    // to negotiate. A new authority bumps the room epoch, and a new room epoch
    // tears down every peer connection, so the inconsistency it guards cannot
    // outlive it. Confirming a room within one epoch still preserves it.
    test('a fresh authority clears a required renegotiation', () {
      final ready = externalReadySignalingSnapshot();
      final snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: ready.accounts[signalingAccountA]!.copyWith(
            renegotiationRequired: true,
          ),
        },
      );
      final before = snapshot.accounts[signalingAccountA]!;

      final result = refreshSignalingAuthority(
        snapshot,
        authority: signalingAuthority(
          credentialGeneration: 4,
          settingsRevision: 'signaling-revision-b',
        ),
        closeEffectId: signalingEffectId(110),
      );
      final after = commitSignaling(
        snapshot,
        result,
      ).accounts[signalingAccountA]!;

      expect(after.renegotiationRequired, isFalse);
      expect(after.roomEpoch, before.roomEpoch + 1);
    });
  });

  group('signaling HTTP replay boundary', () {
    test('settings GET transport failure releases the account for retry', () {
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
        requestId: signalingRequestId(199),
      );
      snapshot = commitSignaling(snapshot, fetch);

      final failure = recordSignalingHttpTransportFailure(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        request: fetch.request!,
        bodyState: SignalingTransportBodyState.notSent,
      );

      expect(failure.outcome, SignalingRuntimeOutcome.settingsRefreshRequired);
      expect(failure.canCommit, isTrue);
      snapshot = commitSignaling(snapshot, failure);
      final account = snapshot.accounts[signalingAccountA]!;
      expect(account.pendingSettingsRequest, isNull);
      expect(account.phase, SignalingAccountPhase.settingsRefreshRequired);

      final retry = planSignalingSettingsFetch(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(200),
      );
      expect(retry.outcome, SignalingRuntimeOutcome.settingsFetching);
    });

    test('GET transport ambiguity never triggers renegotiation', () {
      final authority = signalingAuthority();
      var snapshot = configuredSignalingSnapshot(mode: 'internal');
      final pull = planInternalSignalingPull(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(200),
      );
      snapshot = commitSignaling(snapshot, pull);
      final failure = recordSignalingHttpTransportFailure(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        request: pull.request!,
        bodyState: SignalingTransportBodyState.possiblySent,
      );
      snapshot = commitSignaling(snapshot, failure);

      expect(failure.outcome, SignalingRuntimeOutcome.unchanged);
      expect(
        snapshot.accounts[signalingAccountA]!.renegotiationRequired,
        isFalse,
      );
    });

    test('possibly sent POST batch requires renegotiation', () {
      final authority = signalingAuthority();
      var snapshot = configuredSignalingSnapshot(mode: 'internal');
      final batch = planInternalSignalingBatch(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(201),
        messages: <SignalingPeerMessage>[signalingMessage()],
      );
      snapshot = commitSignaling(snapshot, batch);
      final failure = recordSignalingHttpTransportFailure(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        request: batch.request!,
        bodyState: SignalingTransportBodyState.possiblySent,
      );
      snapshot = commitSignaling(snapshot, failure);

      expect(failure.outcome, SignalingRuntimeOutcome.renegotiationRequired);
      expect(
        snapshot.accounts[signalingAccountA]!.renegotiationRequired,
        isTrue,
      );
    });

    test(
      'reauthentication clears every pending request in the account lane',
      () {
        final authority = signalingAuthority();
        var snapshot = configuredSignalingSnapshot(mode: 'internal');
        final pull = planInternalSignalingPull(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          requestId: signalingRequestId(202),
        );
        snapshot = commitSignaling(snapshot, pull);
        final batch = planInternalSignalingBatch(
          snapshot,
          accountId: signalingAccountA,
          authority: authority,
          requestId: signalingRequestId(203),
          messages: <SignalingPeerMessage>[signalingMessage()],
        );
        snapshot = commitSignaling(snapshot, batch);
        final response = decodeInternalSignalingPullResponse(
          request: pull.request! as InternalSignalingPullRequest,
          statusCode: 401,
          body: signalingOcsBody(statusCode: 401, data: null),
        );
        snapshot = commitSignaling(
          snapshot,
          applyInternalSignalingPullResponse(
            snapshot,
            accountId: signalingAccountA,
            authority: authority,
            response: response,
          ),
        );
        final account = snapshot.accounts[signalingAccountA]!;

        expect(account.pendingInternalPull, isNull);
        expect(account.pendingInternalBatch, isNull);
        expect(account.phase, SignalingAccountPhase.reauthenticationRequired);
      },
    );
  });

  test('peer frame planning reports its own outcome', () {
    final snapshot = externalReadySignalingSnapshot();
    final result = planHpbPeerFrame(
      snapshot,
      accountId: signalingAccountA,
      authority: signalingAuthority(),
      requestId: signalingRequestId(300),
      effectId: signalingEffectId(300),
      message: signalingMessage(),
    );

    expect(result.outcome, SignalingRuntimeOutcome.peerFrameSending);
    expect(result.effects.single, isA<SendHpbFrameEffect>());
  });

  test('completed control frame reports acceptance', () {
    final authority = signalingAuthority();
    var snapshot = externalReadySignalingSnapshot();
    final planned = planHpbControlFrame(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      requestId: signalingRequestId(301),
      effectId: signalingEffectId(301),
      control: HpbControlMessage(
        recipient: SignalingPeerId.parse('peer-b'),
        sender: null,
        data: SignalingOpaquePayload.fromJson(<String, Object?>{
          'type': 'mute',
        }),
      ),
    );
    snapshot = commitSignaling(snapshot, planned);

    final completed = completeHpbFrameSend(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      effect: planned.effects.single as SendHpbFrameEffect,
    );

    expect(completed.outcome, SignalingRuntimeOutcome.frameAccepted);
  });
}

HpbServerFrame _inboundMessageFrame(String peerId) =>
    decodeHpbFrame(<String, Object?>{
      'type': 'message',
      'message': <String, Object?>{
        'sender': <String, Object?>{'type': 'session', 'sessionid': peerId},
        'data': <String, Object?>{
          'type': 'offer',
          'roomType': 'video',
          'payload': <String, Object?>{'sdp': 'synthetic-sdp'},
        },
      },
    });

HpbServerFrame _inboundControlFrame(String peerId) =>
    decodeHpbFrame(<String, Object?>{
      'type': 'control',
      'control': <String, Object?>{
        'sender': <String, Object?>{'type': 'session', 'sessionid': peerId},
        'data': <String, Object?>{'type': 'hangup'},
      },
    });
