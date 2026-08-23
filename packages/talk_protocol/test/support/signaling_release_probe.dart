import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';

void main() {
  try {
    final accountId = AccountId.parse('release-signaling-account');
    final server = ServerBase.parse('https://cloud.example.invalid/nextcloud');
    final roomToken = ConversationToken.parse(
      'rooma123',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidSignalingState,
    );
    final nextcloudSessionId = ConversationSessionId.parse(
      'release-nextcloud-session',
      code: TalkProtocolErrorCode.invalidSignalingState,
    );
    final authority = SignalingAuthority(
      accountId: accountId,
      server: server,
      credentialGeneration: 1,
      capabilityGeneration: 1,
      settingsRevision: 'release-signaling-revision',
      profile: SignalingCapabilityProfile.fromTalkFeatures(const <Object?>[
        'signaling-v3',
        'chat-keep-notifications',
      ]),
      roomToken: roomToken,
      nextcloudSessionId: nextcloudSessionId,
    );
    var snapshot = SignalingRuntimeSnapshot(
      accounts: const <AccountId, SignalingAccountState>{},
    );
    snapshot = _commit(
      snapshot,
      addSignalingAccount(snapshot, authority: authority),
      SignalingRuntimeOutcome.accountAdded,
    );
    final settingsPlan = planSignalingSettingsFetch(
      snapshot,
      accountId: accountId,
      authority: authority,
      requestId: _requestId(1),
    );
    snapshot = _commit(
      snapshot,
      settingsPlan,
      SignalingRuntimeOutcome.settingsFetching,
    );
    snapshot = _commit(
      snapshot,
      applySignalingSettingsResponse(
        snapshot,
        accountId: accountId,
        authority: authority,
        response: decodeSignalingSettingsResponse(
          request: settingsPlan.request! as SignalingSettingsRequest,
          statusCode: 200,
          body: _settingsBody(),
        ),
      ),
      SignalingRuntimeOutcome.settingsConfigured,
    );

    final connect = planSignalingConnect(
      snapshot,
      accountId: accountId,
      authority: authority,
      nowMicros: 1000,
      effectId: _effectId(1),
    );
    snapshot = _commit(snapshot, connect, SignalingRuntimeOutcome.connecting);
    final opened = completeHpbSocketOpen(
      snapshot,
      accountId: accountId,
      authority: authority,
      effect: connect.effects.single as OpenHpbSocketEffect,
      deadlineEffectId: _effectId(2),
      nowMicros: 1100,
    );
    snapshot = _commit(
      snapshot,
      opened,
      SignalingRuntimeOutcome.awaitingWelcome,
    );
    final welcome = applyHpbServerFrame(
      snapshot,
      accountId: accountId,
      authority: authority,
      connectionEpoch: 1,
      roomEpoch: snapshot.accounts[accountId]!.roomEpoch,
      frame: _frame(<String, Object?>{
        'type': 'welcome',
        'welcome': <String, Object?>{
          'features': <Object?>['hello-v2', 'mcu'],
        },
      }),
      nowMicros: 1200,
      nextRequestId: _requestId(2),
      sendEffectId: _effectId(3),
    );
    snapshot = _commit(snapshot, welcome, SignalingRuntimeOutcome.helloSending);
    final helloEffect = welcome.effects.single as SendHpbFrameEffect;
    snapshot = _commit(
      snapshot,
      completeHpbFrameSend(
        snapshot,
        accountId: accountId,
        authority: authority,
        effect: helloEffect,
      ),
      SignalingRuntimeOutcome.unchanged,
    );
    final hello = applyHpbServerFrame(
      snapshot,
      accountId: accountId,
      authority: authority,
      connectionEpoch: 1,
      roomEpoch: snapshot.accounts[accountId]!.roomEpoch,
      frame: _frame(<String, Object?>{
        'id': helloEffect.frame.requestId.value,
        'type': 'hello',
        'hello': <String, Object?>{
          'version': '2.0',
          'sessionid': 'release-hpb-session',
          'resumeid': 'release-hpb-resume',
        },
      }),
      nowMicros: 1300,
      nextRequestId: _requestId(3),
      sendEffectId: _effectId(4),
    );
    snapshot = _commit(snapshot, hello, SignalingRuntimeOutcome.roomJoining);
    final roomEffect = hello.effects.single as SendHpbFrameEffect;
    snapshot = _commit(
      snapshot,
      completeHpbFrameSend(
        snapshot,
        accountId: accountId,
        authority: authority,
        effect: roomEffect,
      ),
      SignalingRuntimeOutcome.unchanged,
    );
    snapshot = _commit(
      snapshot,
      applyHpbServerFrame(
        snapshot,
        accountId: accountId,
        authority: authority,
        connectionEpoch: 1,
        roomEpoch: snapshot.accounts[accountId]!.roomEpoch,
        frame: _frame(<String, Object?>{
          'id': roomEffect.frame.requestId.value,
          'type': 'room',
          'room': <String, Object?>{'roomid': 'rooma123'},
        }),
        nowMicros: 1400,
      ),
      SignalingRuntimeOutcome.signalingReady,
    );

    final disconnected = recordHpbDisconnect(
      snapshot,
      accountId: accountId,
      authority: authority,
      connectionEpoch: 1,
      nowMicros: 2000,
      jitterUnit: 0,
      deadlineEffectId: _effectId(5),
    );
    snapshot = _commit(
      snapshot,
      disconnected,
      SignalingRuntimeOutcome.reconnectScheduled,
    );
    final deadline =
        disconnected.effects.single as ScheduleSignalingDeadlineEffect;
    final reconnect = planSignalingConnect(
      snapshot,
      accountId: accountId,
      authority: authority,
      nowMicros: deadline.deadlineMicros,
      effectId: _effectId(6),
      completedDeadline: deadline,
    );
    snapshot = _commit(snapshot, reconnect, SignalingRuntimeOutcome.connecting);
    final reopened = completeHpbSocketOpen(
      snapshot,
      accountId: accountId,
      authority: authority,
      effect: reconnect.effects.single as OpenHpbSocketEffect,
      deadlineEffectId: _effectId(7),
      nowMicros: deadline.deadlineMicros + 10,
    );
    snapshot = _commit(
      snapshot,
      reopened,
      SignalingRuntimeOutcome.awaitingWelcome,
    );
    final resumePlan = applyHpbServerFrame(
      snapshot,
      accountId: accountId,
      authority: authority,
      connectionEpoch: 2,
      roomEpoch: snapshot.accounts[accountId]!.roomEpoch,
      frame: _frame(<String, Object?>{
        'type': 'welcome',
        'welcome': <String, Object?>{
          'features': <Object?>['hello-v2', 'mcu'],
        },
      }),
      nowMicros: deadline.deadlineMicros + 20,
      nextRequestId: _requestId(4),
      sendEffectId: _effectId(8),
    );
    snapshot = _commit(
      snapshot,
      resumePlan,
      SignalingRuntimeOutcome.helloSending,
    );
    final resumeEffect = resumePlan.effects.single as SendHpbFrameEffect;
    final resumeFrame = resumeEffect.frame as HpbHelloClientFrame;
    if (!resumeFrame.isResume) {
      throw StateError('Release signaling resume was not selected.');
    }
    snapshot = _commit(
      snapshot,
      completeHpbFrameSend(
        snapshot,
        accountId: accountId,
        authority: authority,
        effect: resumeEffect,
      ),
      SignalingRuntimeOutcome.unchanged,
    );
    snapshot = _commit(
      snapshot,
      applyHpbServerFrame(
        snapshot,
        accountId: accountId,
        authority: authority,
        connectionEpoch: 2,
        roomEpoch: snapshot.accounts[accountId]!.roomEpoch,
        frame: _frame(<String, Object?>{
          'id': resumeEffect.frame.requestId.value,
          'type': 'hello',
          'hello': <String, Object?>{
            'version': '2.0',
            'sessionid': 'release-hpb-session',
          },
        }),
        nowMicros: deadline.deadlineMicros + 30,
      ),
      SignalingRuntimeOutcome.resumed,
    );
    final account = snapshot.accounts[accountId]!;
    if (!account.signalingReady || account.mediaReady) {
      throw StateError('Release signaling readiness invariant failed.');
    }
  } on Object catch (error) {
    stderr.writeln('Release signaling probe failed: ${error.runtimeType}');
    exitCode = 1;
  }
}

SignalingRuntimeSnapshot _commit(
  SignalingRuntimeSnapshot snapshot,
  SignalingRuntimeResult result,
  SignalingRuntimeOutcome expected,
) {
  if (result.outcome != expected || result.plan == null) {
    throw StateError('Unexpected signaling outcome: ${result.outcome.name}');
  }
  return result.plan!.commit(snapshot);
}

SignalingRequestId _requestId(int value) =>
    SignalingRequestId.parse('release-request-$value');

SignalingEffectId _effectId(int value) =>
    SignalingEffectId.parse('release-effect-$value');

HpbServerFrame _frame(Map<String, Object?> value) =>
    HpbServerFrame.decode(jsonEncode(value));

Uint8List _settingsBody() => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': <String, Object?>{
          'signalingMode': 'external',
          'userId': 'release-user',
          'hideWarning': true,
          'server': 'https://hpb.example.invalid/signaling',
          'federation': null,
          'stunservers': <Object?>[],
          'turnservers': <Object?>[],
          'sipDialinInfo': '',
          'helloAuthParams': <String, Object?>{
            '1.0': <String, Object?>{
              'userid': 'release-user',
              'ticket': 'release-ticket',
            },
            '2.0': <String, Object?>{'token': 'release-token'},
          },
        },
      },
    }),
  ),
);
