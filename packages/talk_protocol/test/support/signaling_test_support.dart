import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';

final signalingAccountA = AccountId.parse('signaling-account-a');
final signalingAccountB = AccountId.parse('signaling-account-b');
final signalingServerA = ServerBase.parse(
  'https://cloud.example.invalid/nextcloud',
);
final signalingServerB = ServerBase.parse(
  'https://other.example.invalid/nextcloud',
);
final signalingRoomA = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidSignalingState,
);
final signalingRoomB = ConversationToken.parse(
  'roomb123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidSignalingState,
);
final signalingSessionA = ConversationSessionId.parse(
  'nextcloud-session-a',
  code: TalkProtocolErrorCode.invalidSignalingState,
);

SignalingRequestId signalingRequestId(int value) =>
    SignalingRequestId.parse('signaling-request-$value');

SignalingEffectId signalingEffectId(int value) =>
    SignalingEffectId.parse('signaling-effect-$value');

SignalingCapabilityProfile signalingProfile({bool enabled = true}) =>
    SignalingCapabilityProfile.fromTalkFeatures(
      enabled
          ? const <Object?>['signaling-v3', 'chat-keep-notifications']
          : const <Object?>[],
    );

SignalingAuthority signalingAuthority({
  AccountId? accountId,
  ServerBase? server,
  ConversationToken? roomToken,
  ConversationSessionId? sessionId,
  int credentialGeneration = 3,
  int capabilityGeneration = 7,
  String settingsRevision = 'signaling-revision-a',
  SignalingCapabilityProfile? profile,
}) => SignalingAuthority(
  accountId: accountId ?? signalingAccountA,
  server: server ?? signalingServerA,
  credentialGeneration: credentialGeneration,
  capabilityGeneration: capabilityGeneration,
  settingsRevision: settingsRevision,
  profile: profile ?? signalingProfile(),
  roomToken: roomToken ?? signalingRoomA,
  nextcloudSessionId: sessionId ?? signalingSessionA,
);

SignalingRequestContext signalingRequestContext(
  int requestNumber, {
  int connectionEpoch = 0,
  int roomEpoch = 1,
}) => SignalingRequestContext(
  accountId: signalingAccountA,
  requestId: signalingRequestId(requestNumber),
  server: signalingServerA,
  roomToken: signalingRoomA,
  credentialGeneration: 3,
  capabilityGeneration: 7,
  settingsRevision: 'signaling-revision-a',
  connectionEpoch: connectionEpoch,
  roomEpoch: roomEpoch,
);

SignalingPeerMessage signalingMessage({
  String type = 'offer',
  String roomType = 'video',
  SignalingPeerId? recipient,
  SignalingPeerId? sender,
}) => SignalingPeerMessage(
  type: type,
  roomType: roomType,
  sid: 'stream-a',
  recipient: recipient ?? SignalingPeerId.parse('peer-b'),
  sender: sender,
  payload: SignalingOpaquePayload.fromJson(<String, Object?>{
    'sdp': 'synthetic-sdp',
  }),
);

SignalingParticipant signalingParticipant({
  String peerId = 'peer-a',
  int inCall = 1,
  bool federated = false,
}) => SignalingParticipant(
  peerId: SignalingPeerId.parse(peerId),
  nextcloudSessionId: ConversationSessionId.parse(
    'nextcloud-$peerId',
    code: TalkProtocolErrorCode.invalidSignalingFrame,
  ),
  userId: 'user-$peerId',
  inCall: inCall,
  permissions: 7,
  actorType: 'users',
  actorId: 'actor-$peerId',
  federated: federated,
  features: const <String>{'audio-video-permissions'},
);

SignalingRuntimeSnapshot emptySignalingSnapshot() => SignalingRuntimeSnapshot(
  accounts: const <AccountId, SignalingAccountState>{},
);

SignalingRuntimeSnapshot commitSignaling(
  SignalingRuntimeSnapshot snapshot,
  SignalingRuntimeResult result,
) => result.plan!.commit(snapshot);

Uint8List signalingJsonBody(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Uint8List signalingOcsBody({required int statusCode, required Object? data}) =>
    signalingJsonBody(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': statusCode >= 200 && statusCode < 300 ? 'ok' : 'failure',
          'statuscode': statusCode,
          'message': statusCode >= 200 && statusCode < 300
              ? 'OK'
              : 'Synthetic failure',
        },
        'data': data,
      },
    });

Map<String, Object?> signalingSettingsData({
  String mode = 'external',
  String endpoint = 'https://hpb.example.invalid/signaling',
}) => <String, Object?>{
  'signalingMode': mode,
  'userId': 'user-a',
  'hideWarning': true,
  'server': mode == 'internal' ? '' : endpoint,
  'federation': null,
  'stunservers': <Object?>[],
  'turnservers': <Object?>[],
  'sipDialinInfo': '',
  if (mode == 'external')
    'helloAuthParams': <String, Object?>{
      '1.0': <String, Object?>{
        'userid': 'user-a',
        'ticket': 'synthetic-ticket-a',
      },
      '2.0': <String, Object?>{'token': 'synthetic-token-a'},
    },
};

HpbServerFrame decodeHpbFrame(Map<String, Object?> frame) =>
    HpbServerFrame.decode(jsonEncode(frame));

SignalingRuntimeSnapshot configuredSignalingSnapshot({
  String mode = 'external',
}) {
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
    requestId: signalingRequestId(100),
  );
  snapshot = commitSignaling(snapshot, fetch);
  final response = decodeSignalingSettingsResponse(
    request: fetch.request! as SignalingSettingsRequest,
    statusCode: 200,
    body: signalingOcsBody(
      statusCode: 200,
      data: signalingSettingsData(mode: mode),
    ),
  );
  return commitSignaling(
    snapshot,
    applySignalingSettingsResponse(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      response: response,
    ),
  );
}

({SignalingRuntimeSnapshot snapshot, SendHpbFrameEffect helloEffect})
externalHelloPendingSnapshot() {
  final authority = signalingAuthority();
  var snapshot = configuredSignalingSnapshot();
  final connect = planSignalingConnect(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    nowMicros: 1000,
    effectId: signalingEffectId(101),
  );
  snapshot = commitSignaling(snapshot, connect);
  final opened = completeHpbSocketOpen(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    effect: connect.effects.single as OpenHpbSocketEffect,
    deadlineEffectId: signalingEffectId(102),
    nowMicros: 1100,
  );
  snapshot = commitSignaling(snapshot, opened);
  final welcome = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: 1,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: decodeHpbFrame(<String, Object?>{
      'type': 'welcome',
      'welcome': <String, Object?>{
        'features': <Object?>['hello-v2', 'mcu', 'federation'],
      },
    }),
    nowMicros: 1200,
    nextRequestId: signalingRequestId(103),
    sendEffectId: signalingEffectId(103),
  );
  snapshot = commitSignaling(snapshot, welcome);
  return (
    snapshot: snapshot,
    helloEffect: welcome.effects.single as SendHpbFrameEffect,
  );
}

SignalingRuntimeSnapshot externalReadySignalingSnapshot() {
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
      'id': 'signaling-request-103',
      'type': 'hello',
      'hello': <String, Object?>{
        'version': '2.0',
        'sessionid': 'hpb-session-a',
        'resumeid': 'hpb-resume-a',
      },
    }),
    nowMicros: 1300,
    nextRequestId: signalingRequestId(104),
    sendEffectId: signalingEffectId(104),
  );
  snapshot = commitSignaling(snapshot, hello);
  snapshot = commitSignaling(
    snapshot,
    completeHpbFrameSend(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      effect: hello.effects.single as SendHpbFrameEffect,
    ),
  );
  final room = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: 1,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: decodeHpbFrame(<String, Object?>{
      'id': 'signaling-request-104',
      'type': 'room',
      'room': <String, Object?>{'roomid': 'rooma123'},
    }),
    nowMicros: 1400,
  );
  return commitSignaling(snapshot, room);
}
