import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('join and update persist intent before confirmation', () {
    final joining = CallLifecycleState.beginJoin(
      authority: _authority(),
      flags: CallInCallFlags.audioVideo(),
      updatedAt: DateTime.utc(2026, 8, 26),
    );
    expect(joining.phase, CallLifecyclePhase.joining);
    expect(joining.mutationSequence, 1);

    final joined = joining.confirm(updatedAt: DateTime.utc(2026, 8, 26, 1));
    final updating = joined.beginUpdate(
      flags: CallInCallFlags.parse(3, requireJoined: true),
      updatedAt: DateTime.utc(2026, 8, 26, 2),
    );
    expect(updating.phase, CallLifecyclePhase.updating);
    expect(updating.confirmedFlags?.value, 7);
    expect(updating.requestedFlags?.value, 3);
    expect(updating.mutationSequence, 2);

    final uncertain = updating.markUncertain(
      updatedAt: DateTime.utc(2026, 8, 26, 3),
    );
    expect(uncertain.phase, CallLifecyclePhase.uncertainUpdate);
    expect(
      uncertain.afterRestart(updatedAt: DateTime.utc(2026)).phase,
      CallLifecyclePhase.uncertainUpdate,
    );
  });

  test('restart turns an in-flight join into an uncertain join', () {
    final state = CallLifecycleState.beginJoin(
      authority: _authority(),
      flags: CallInCallFlags.audioVideo(),
      updatedAt: DateTime.utc(2026, 8, 26),
    );

    expect(
      state.afterRestart(updatedAt: DateTime.utc(2026, 8, 27)).phase,
      CallLifecyclePhase.uncertainJoin,
    );
  });

  test('GET confirms an ambiguous join only for the own session id', () {
    final joining = CallLifecycleState.beginJoin(
      authority: _authority(),
      flags: CallInCallFlags.audioVideo(),
      updatedAt: DateTime.utc(2026, 8, 26),
    ).markUncertain(updatedAt: DateTime.utc(2026, 8, 26, 1));

    final confirmed = reconcileCallLifecycle(
      state: joining,
      peersResponse: _peersResponse(<Object?>[_peer('session-a')]),
      observedAt: DateTime.utc(2026, 8, 26, 2),
    );
    expect(confirmed.action, CallRecoveryAction.joinedConfirmed);
    expect(confirmed.state?.phase, CallLifecyclePhase.joined);

    final absent = reconcileCallLifecycle(
      state: joining,
      peersResponse: _peersResponse(<Object?>[_peer('someone-else')]),
      observedAt: DateTime.utc(2026, 8, 26, 2),
    );
    expect(absent.action, CallRecoveryAction.deleteLocalState);
    expect(absent.state, isNull);
  });

  test('uncertain leave retries only after GET still sees own session', () {
    final leaving =
        CallLifecycleState.beginJoin(
              authority: _authority(),
              flags: CallInCallFlags.audioVideo(),
              updatedAt: DateTime.utc(2026, 8, 26),
            )
            .confirm(updatedAt: DateTime.utc(2026, 8, 26, 1))
            .beginLeave(
              endForEveryone: true,
              updatedAt: DateTime.utc(2026, 8, 26, 2),
            )
            .markUncertain(updatedAt: DateTime.utc(2026, 8, 26, 3));

    final retry = reconcileCallLifecycle(
      state: leaving,
      peersResponse: _peersResponse(<Object?>[_peer('session-a')]),
      observedAt: DateTime.utc(2026, 8, 26, 4),
    );
    expect(retry.action, CallRecoveryAction.retryLeave);
    expect(retry.state?.endForEveryone, isTrue);

    final complete = reconcileCallLifecycle(
      state: leaving,
      peersResponse: _peersResponse(const <Object?>[]),
      observedAt: DateTime.utc(2026, 8, 26, 4),
    );
    expect(complete.action, CallRecoveryAction.deleteLocalState);
  });

  test('GET cannot guess the result of an ambiguous flag update', () {
    final updating =
        CallLifecycleState.beginJoin(
              authority: _authority(),
              flags: CallInCallFlags.audioVideo(),
              updatedAt: DateTime.utc(2026, 8, 26),
            )
            .confirm(updatedAt: DateTime.utc(2026, 8, 26, 1))
            .beginUpdate(
              flags: CallInCallFlags.parse(3, requireJoined: true),
              updatedAt: DateTime.utc(2026, 8, 26, 2),
            )
            .markUncertain(updatedAt: DateTime.utc(2026, 8, 26, 3));

    final decision = reconcileCallLifecycle(
      state: updating,
      peersResponse: _peersResponse(<Object?>[_peer('session-a')]),
      observedAt: DateTime.utc(2026, 8, 26, 4),
    );
    expect(decision.action, CallRecoveryAction.stillUncertain);
    expect(decision.state?.phase, CallLifecyclePhase.uncertainUpdate);
    expect(decision.state?.confirmedFlags?.value, 7);
    expect(decision.state?.requestedFlags?.value, 3);
  });
}

CallLifecycleAuthority _authority() => CallLifecycleAuthority(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  nextcloudSessionId: ConversationSessionId.parse('session-a'),
  credentialGeneration: 1,
  capabilityGeneration: 1,
  capabilityRevision: 'call-v4:1:1:1:2',
);

CallRestResponse _peersResponse(List<Object?> peers) => decodeCallRestResponse(
  request: CallPeersRequest(
    context: CallRequestContext(authority: _authority(), mutationSequence: 0),
  ),
  statusCode: 200,
  body: Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': peers,
        },
      }),
    ),
  ),
);

Map<String, Object?> _peer(String sessionId) => <String, Object?>{
  'actorType': 'users',
  'actorId': 'alice',
  'displayName': 'Alice',
  'token': 'rooma123',
  'lastPing': 1770000000,
  'sessionId': sessionId,
};
