import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/signaling_test_support.dart';

void main() {
  group('signaling endpoint trust boundary', () {
    test(
      'production endpoints reject cleartext and URL authority smuggling',
      () {
        for (final endpoint in <String>[
          'http://hpb.example.invalid/signaling',
          'ws://hpb.example.invalid/signaling',
          'https://user@hpb.example.invalid/signaling',
          'https://hpb.example.invalid/signaling?token=private',
          'https://hpb.example.invalid/signaling#private',
          r'https://hpb.example.invalid\signaling',
        ]) {
          expect(
            () => HpbEndpoint.parse(endpoint),
            throwsA(
              isA<TalkProtocolException>().having(
                (error) => error.code,
                'code',
                TalkProtocolErrorCode.invalidSignalingSettings,
              ),
            ),
            reason: endpoint,
          );
        }
      },
    );

    test('debug cleartext is compile-time gated and remains canonical', () {
      final endpoint = HpbEndpoint.parse(
        'http://127.0.0.1:8080/signaling/',
        policy: SignalingEndpointPolicy.debug,
      );

      expect(endpoint.baseUri.toString(), 'http://127.0.0.1:8080/signaling');
      expect(
        endpoint.socketUri.toString(),
        'ws://127.0.0.1:8080/signaling/spreed',
      );
    });
  });

  group('signaling parser bounds', () {
    test('rejects oversized and over-depth HPB frames', () {
      expect(
        () => HpbServerFrame.decode('x' * (maximumSignalingWireBytes + 1)),
        throwsA(isA<TalkProtocolException>()),
      );

      Object? nested = <String, Object?>{'type': 'offer'};
      for (var depth = 0; depth < 34; depth++) {
        nested = <String, Object?>{'nested': nested};
      }
      expect(
        () => HpbServerFrame.decode(
          jsonEncode(<String, Object?>{
            'type': 'message',
            'message': <String, Object?>{
              'sender': <String, Object?>{
                'type': 'session',
                'sessionid': 'peer-a',
              },
              'data': <String, Object?>{'type': 'offer', 'payload': nested},
            },
          }),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test(
      'unknown top-level frames are safe but malformed known frames fail',
      () {
        expect(
          HpbServerFrame.decode('{"type":"future-frame"}'),
          isA<HpbUnsupportedServerFrame>(),
        );
        expect(
          () => HpbServerFrame.decode('{"type":"hello","hello":{}}'),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidSignalingIdentifier,
            ),
          ),
        );
      },
    );

    test('HPB frames reject escaped duplicate JSON members', () {
      expect(
        () => HpbServerFrame.decode(
          r'{"type":"future-frame","\u0074ype":"future-frame"}',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('OCS responses reject duplicate JSON members', () {
      final request = SignalingSettingsRequest(
        context: signalingRequestContext(398),
      );
      final source = jsonEncode(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': signalingSettingsData(),
        },
      });
      final duplicate = source.replaceFirst(
        '"signalingMode":"external"',
        '"signalingMode":"internal","signalingMode":"external"',
      );

      expect(
        () => decodeSignalingSettingsResponse(
          request: request,
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode(duplicate)),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('embedded internal messages reject duplicate JSON members', () {
      final request = InternalSignalingPullRequest(
        context: signalingRequestContext(399, connectionEpoch: 1),
        nextcloudSessionId: signalingSessionA,
      );

      expect(
        () => decodeInternalSignalingPullResponse(
          request: request,
          statusCode: 200,
          body: signalingOcsBody(
            statusCode: 200,
            data: <Object?>[
              <String, Object?>{
                'type': 'message',
                'data':
                    '{"type":"answer","type":"offer",'
                    '"roomType":"video","from":"peer-a","payload":{}}',
              },
              <String, Object?>{'type': 'usersInRoom', 'data': <Object?>[]},
            ],
          ),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('OCS response byte budget is enforced before parsing', () {
      final request = SignalingSettingsRequest(
        context: signalingRequestContext(400),
      );
      expect(
        () => decodeSignalingSettingsResponse(
          request: request,
          statusCode: 200,
          body: Uint8List(maximumSignalingWireBytes + 1),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('signaling account and epoch binding', () {
    test('cross-account, cross-origin and stale authorities are rejected', () {
      final authority = signalingAuthority();
      var snapshot = emptySignalingSnapshot();
      snapshot = commitSignaling(
        snapshot,
        addSignalingAccount(snapshot, authority: authority),
      );

      for (final invalid in <SignalingAuthority>[
        signalingAuthority(accountId: signalingAccountB),
        signalingAuthority(server: signalingServerB),
        signalingAuthority(credentialGeneration: 4),
        signalingAuthority(capabilityGeneration: 8),
        signalingAuthority(settingsRevision: 'signaling-revision-b'),
      ]) {
        final result = planSignalingSettingsFetch(
          snapshot,
          accountId: signalingAccountA,
          authority: invalid,
          requestId: signalingRequestId(401),
        );
        expect(result.outcome, SignalingRuntimeOutcome.rejected);
        expect(result.canCommit, isFalse);
      }
    });

    test('response must retain the exact originating request instance', () {
      final authority = signalingAuthority();
      var snapshot = emptySignalingSnapshot();
      snapshot = commitSignaling(
        snapshot,
        addSignalingAccount(snapshot, authority: authority),
      );
      final planned = planSignalingSettingsFetch(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(402),
      );
      snapshot = commitSignaling(snapshot, planned);
      final original = planned.request! as SignalingSettingsRequest;
      final lookalike = SignalingSettingsRequest(
        context: SignalingRequestContext(
          accountId: original.context.accountId,
          requestId: original.context.requestId,
          server: original.context.server,
          roomToken: original.context.roomToken,
          credentialGeneration: original.context.credentialGeneration,
          capabilityGeneration: original.context.capabilityGeneration,
          settingsRevision: original.context.settingsRevision,
          connectionEpoch: original.context.connectionEpoch,
          roomEpoch: original.context.roomEpoch,
        ),
      );
      final response = decodeSignalingSettingsResponse(
        request: lookalike,
        statusCode: 200,
        body: signalingOcsBody(statusCode: 200, data: signalingSettingsData()),
      );

      final result = applySignalingSettingsResponse(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        response: response,
      );
      expect(result.outcome, SignalingRuntimeOutcome.rejected);
      expect(result.canCommit, isFalse);
    });

    test('stale socket completion cannot cross authority rotation', () {
      final authority = signalingAuthority();
      var snapshot = configuredSignalingSnapshot();
      final opening = planSignalingConnect(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        nowMicros: 1000,
        effectId: signalingEffectId(403),
      );
      snapshot = commitSignaling(snapshot, opening);
      final refreshedAuthority = signalingAuthority(
        credentialGeneration: 4,
        settingsRevision: 'signaling-revision-b',
      );
      snapshot = commitSignaling(
        snapshot,
        refreshSignalingAuthority(
          snapshot,
          authority: refreshedAuthority,
          closeEffectId: signalingEffectId(404),
        ),
      );

      final stale = completeHpbSocketOpen(
        snapshot,
        accountId: signalingAccountA,
        authority: refreshedAuthority,
        effect: opening.effects.single as OpenHpbSocketEffect,
        deadlineEffectId: signalingEffectId(405),
        nowMicros: 2000,
      );
      expect(stale.outcome, SignalingRuntimeOutcome.rejected);
      expect(stale.canCommit, isFalse);
    });
  });

  group('signaling immutable transitions', () {
    test('candidate plans are source-bound and single-use', () {
      final authority = signalingAuthority();
      final first = emptySignalingSnapshot();
      final result = addSignalingAccount(first, authority: authority);
      final committed = result.plan!.commit(first);

      expect(
        () => result.plan!.commit(first),
        throwsA(isA<TalkProtocolException>()),
      );
      final second = emptySignalingSnapshot();
      final other = addSignalingAccount(second, authority: authority);
      expect(
        () => other.plan!.commit(committed),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('process restart drops ephemeral session and peer frames', () {
      final authority = signalingAuthority();
      var snapshot = externalReadySignalingSnapshot();
      final ready = snapshot.accounts[signalingAccountA]!;
      final peer = signalingParticipant();
      snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{
          signalingAccountA: ready.copyWith(
            participants: <SignalingPeerId, SignalingParticipant>{
              peer.peerId: peer,
            },
          ),
        },
      );
      final pending = planHpbPeerFrame(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(406),
        effectId: signalingEffectId(406),
        message: signalingMessage(),
      );
      snapshot = commitSignaling(snapshot, pending);
      final before = snapshot.accounts[signalingAccountA]!;

      snapshot = commitSignaling(
        snapshot,
        recoverSignalingAfterProcessRestart(
          snapshot,
          accountId: signalingAccountA,
        ),
      );
      final recovered = snapshot.accounts[signalingAccountA]!;

      expect(recovered.connectionEpoch, before.connectionEpoch + 1);
      expect(recovered.roomEpoch, before.roomEpoch + 1);
      expect(recovered.hpbSessionId, isNull);
      expect(recovered.hpbResumeId, isNull);
      expect(recovered.pendingHpbFrame, isNull);
      expect(recovered.participants, isEmpty);
      expect(recovered.settings, isNull);
      expect(recovered.renegotiationRequired, isTrue);
      expect(recovered.mediaReady, isFalse);
    });
  });

  test('secret values never enter diagnostics', () {
    const marker = 'PRIVATE_SIGNALING_REDACTION_GUARD';
    final request = SignalingSettingsRequest(
      context: signalingRequestContext(407),
    );
    final data = signalingSettingsData();
    final auth = data['helloAuthParams']! as Map<String, Object?>;
    auth['1.0'] = <String, Object?>{'userid': 'user-a', 'ticket': marker};
    auth['2.0'] = <String, Object?>{'token': marker};
    data['turnservers'] = <Object?>[
      <String, Object?>{
        'urls': <Object?>['turn:turn.example.invalid'],
        'username': marker,
        'credential': marker,
      },
    ];
    final response = decodeSignalingSettingsResponse(
      request: request,
      statusCode: 200,
      body: signalingOcsBody(statusCode: 200, data: data),
    );
    final settings = response.settings! as ExternalSignalingSettings;
    final frame = HpbHelloClientFrame.fullV2(
      requestId: signalingRequestId(408),
      server: signalingServerA,
      authentication: settings.v2Authentication!,
    );

    final diagnostics = <String>[
      response.toString(),
      settings.toString(),
      settings.v1Authentication.toString(),
      settings.v2Authentication.toString(),
      settings.turnServers.single.toString(),
      request.toString(),
      frame.toString(),
    ].join('\n');
    expect(diagnostics, isNot(contains(marker)));

    try {
      HpbV2Authentication(token: marker * 2000);
      fail('Oversized token must fail.');
    } on TalkProtocolException catch (error) {
      expect(error.toString(), isNot(contains(marker)));
      expect(error.path, r'$.ocs.data.helloAuthParams[2.0].token');
    }
  });
}
