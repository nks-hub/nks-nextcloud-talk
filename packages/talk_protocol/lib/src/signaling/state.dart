import 'dart:collection';

import '../conversations/identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'effects.dart';
import 'hpb.dart';
import 'identifiers.dart';
import 'models.dart';
import 'profile.dart';
import 'request.dart';

enum SignalingAccountPhase {
  idle,
  fetchingSettings,
  internalReady,
  internalPolling,
  hpbConnecting,
  hpbAwaitingWelcome,
  hpbHelloPending,
  hpbRoomPending,
  signalingReady,
  reconnectWaiting,
  roomSessionRefreshRequired,
  reauthenticationRequired,
  settingsRefreshRequired,
  terminated,
  unsupported,
}

final class SignalingAuthority {
  SignalingAuthority({
    required this.accountId,
    required this.server,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.settingsRevision,
    required this.profile,
    required this.roomToken,
    required this.nextcloudSessionId,
  }) {
    if (credentialGeneration < 1 ||
        capabilityGeneration < 1 ||
        settingsRevision.isEmpty ||
        settingsRevision.length > 128 ||
        settingsRevision.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      _stateFailure(r'$.authority');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final int credentialGeneration;
  final int capabilityGeneration;
  final String settingsRevision;
  final SignalingCapabilityProfile profile;
  final ConversationToken roomToken;
  final ConversationSessionId nextcloudSessionId;

  @override
  String toString() =>
      'SignalingAuthority(credentialGeneration: $credentialGeneration, '
      'capabilityGeneration: $capabilityGeneration, sensitive: <redacted>)';
}

final class SignalingAccountState {
  SignalingAccountState({
    required this.accountId,
    required this.server,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.settingsRevision,
    required this.profile,
    required this.roomToken,
    required this.nextcloudSessionId,
    required this.phase,
    required this.settings,
    required this.connectionEpoch,
    required this.roomEpoch,
    required this.helloVersion,
    required this.hpbSessionId,
    required this.hpbResumeId,
    required this.resumeDeadlineMicros,
    required this.reconnectAtMicros,
    required this.reconnectAttempt,
    required this.serverFeatures,
    required this.topology,
    required Map<SignalingPeerId, SignalingParticipant> participants,
    required this.roomConfirmed,
    required this.activeSocket,
    required this.federationInterrupted,
    required this.renegotiationRequired,
    required this.federatedPeerEpoch,
    required this.pendingSettingsRequest,
    required this.pendingInternalPull,
    required this.pendingInternalBatch,
    required this.pendingSocketOpen,
    required this.pendingHpbFrame,
    required this.awaitingHpbResponse,
    required this.pendingDeadline,
  }) : participants = UnmodifiableMapView(
         Map<SignalingPeerId, SignalingParticipant>.of(participants),
       ) {
    if (credentialGeneration < 1 ||
        capabilityGeneration < 1 ||
        settingsRevision.isEmpty ||
        connectionEpoch < 0 ||
        roomEpoch < 1 ||
        reconnectAttempt < 0 ||
        federatedPeerEpoch < 0 ||
        this.participants.length > maximumSignalingParticipants) {
      _stateFailure(r'$.account');
    }
    if (pendingSocketOpen != null && activeSocket) {
      _stateFailure(r'$.account.socket');
    }
  }

  factory SignalingAccountState.initial({
    required SignalingAuthority authority,
  }) => SignalingAccountState(
    accountId: authority.accountId,
    server: authority.server,
    credentialGeneration: authority.credentialGeneration,
    capabilityGeneration: authority.capabilityGeneration,
    settingsRevision: authority.settingsRevision,
    profile: authority.profile,
    roomToken: authority.roomToken,
    nextcloudSessionId: authority.nextcloudSessionId,
    phase: authority.profile.enabled
        ? SignalingAccountPhase.idle
        : SignalingAccountPhase.unsupported,
    settings: null,
    connectionEpoch: 0,
    roomEpoch: 1,
    helloVersion: null,
    hpbSessionId: null,
    hpbResumeId: null,
    resumeDeadlineMicros: null,
    reconnectAtMicros: null,
    reconnectAttempt: 0,
    serverFeatures: HpbServerFeatures.empty,
    topology: SignalingTopology.internalPeerToPeer,
    participants: const <SignalingPeerId, SignalingParticipant>{},
    roomConfirmed: false,
    activeSocket: false,
    federationInterrupted: false,
    renegotiationRequired: false,
    federatedPeerEpoch: 0,
    pendingSettingsRequest: null,
    pendingInternalPull: null,
    pendingInternalBatch: null,
    pendingSocketOpen: null,
    pendingHpbFrame: null,
    awaitingHpbResponse: null,
    pendingDeadline: null,
  );

  final AccountId accountId;
  final ServerBase server;
  final int credentialGeneration;
  final int capabilityGeneration;
  final String settingsRevision;
  final SignalingCapabilityProfile profile;
  final ConversationToken roomToken;
  final ConversationSessionId nextcloudSessionId;
  final SignalingAccountPhase phase;
  final SignalingSettings? settings;
  final int connectionEpoch;
  final int roomEpoch;
  final HpbHelloVersion? helloVersion;
  final HpbSessionId? hpbSessionId;
  final HpbResumeId? hpbResumeId;
  final int? resumeDeadlineMicros;
  final int? reconnectAtMicros;
  final int reconnectAttempt;
  final HpbServerFeatures serverFeatures;
  final SignalingTopology topology;
  final Map<SignalingPeerId, SignalingParticipant> participants;
  final bool roomConfirmed;
  final bool activeSocket;
  final bool federationInterrupted;
  final bool renegotiationRequired;
  final int federatedPeerEpoch;
  final SignalingSettingsRequest? pendingSettingsRequest;
  final InternalSignalingPullRequest? pendingInternalPull;
  final InternalSignalingBatchRequest? pendingInternalBatch;
  final OpenHpbSocketEffect? pendingSocketOpen;
  final SendHpbFrameEffect? pendingHpbFrame;
  final HpbClientFrame? awaitingHpbResponse;
  final ScheduleSignalingDeadlineEffect? pendingDeadline;

  bool get signalingReady =>
      phase == SignalingAccountPhase.signalingReady ||
      phase == SignalingAccountPhase.internalReady ||
      phase == SignalingAccountPhase.internalPolling;

  bool get mediaReady => false;

  SignalingTransportKind? get transport => settings?.transport;

  SignalingAccountState copyWith({
    int? credentialGeneration,
    int? capabilityGeneration,
    String? settingsRevision,
    SignalingCapabilityProfile? profile,
    ConversationSessionId? nextcloudSessionId,
    SignalingAccountPhase? phase,
    Object? settings = _unset,
    int? connectionEpoch,
    int? roomEpoch,
    Object? helloVersion = _unset,
    Object? hpbSessionId = _unset,
    Object? hpbResumeId = _unset,
    Object? resumeDeadlineMicros = _unset,
    Object? reconnectAtMicros = _unset,
    int? reconnectAttempt,
    HpbServerFeatures? serverFeatures,
    SignalingTopology? topology,
    Map<SignalingPeerId, SignalingParticipant>? participants,
    bool? roomConfirmed,
    bool? activeSocket,
    bool? federationInterrupted,
    bool? renegotiationRequired,
    int? federatedPeerEpoch,
    Object? pendingSettingsRequest = _unset,
    Object? pendingInternalPull = _unset,
    Object? pendingInternalBatch = _unset,
    Object? pendingSocketOpen = _unset,
    Object? pendingHpbFrame = _unset,
    Object? awaitingHpbResponse = _unset,
    Object? pendingDeadline = _unset,
  }) => SignalingAccountState(
    accountId: accountId,
    server: server,
    credentialGeneration: credentialGeneration ?? this.credentialGeneration,
    capabilityGeneration: capabilityGeneration ?? this.capabilityGeneration,
    settingsRevision: settingsRevision ?? this.settingsRevision,
    profile: profile ?? this.profile,
    roomToken: roomToken,
    nextcloudSessionId: nextcloudSessionId ?? this.nextcloudSessionId,
    phase: phase ?? this.phase,
    settings: identical(settings, _unset)
        ? this.settings
        : settings as SignalingSettings?,
    connectionEpoch: connectionEpoch ?? this.connectionEpoch,
    roomEpoch: roomEpoch ?? this.roomEpoch,
    helloVersion: identical(helloVersion, _unset)
        ? this.helloVersion
        : helloVersion as HpbHelloVersion?,
    hpbSessionId: identical(hpbSessionId, _unset)
        ? this.hpbSessionId
        : hpbSessionId as HpbSessionId?,
    hpbResumeId: identical(hpbResumeId, _unset)
        ? this.hpbResumeId
        : hpbResumeId as HpbResumeId?,
    resumeDeadlineMicros: identical(resumeDeadlineMicros, _unset)
        ? this.resumeDeadlineMicros
        : resumeDeadlineMicros as int?,
    reconnectAtMicros: identical(reconnectAtMicros, _unset)
        ? this.reconnectAtMicros
        : reconnectAtMicros as int?,
    reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
    serverFeatures: serverFeatures ?? this.serverFeatures,
    topology: topology ?? this.topology,
    participants: participants ?? this.participants,
    roomConfirmed: roomConfirmed ?? this.roomConfirmed,
    activeSocket: activeSocket ?? this.activeSocket,
    federationInterrupted: federationInterrupted ?? this.federationInterrupted,
    renegotiationRequired: renegotiationRequired ?? this.renegotiationRequired,
    federatedPeerEpoch: federatedPeerEpoch ?? this.federatedPeerEpoch,
    pendingSettingsRequest: identical(pendingSettingsRequest, _unset)
        ? this.pendingSettingsRequest
        : pendingSettingsRequest as SignalingSettingsRequest?,
    pendingInternalPull: identical(pendingInternalPull, _unset)
        ? this.pendingInternalPull
        : pendingInternalPull as InternalSignalingPullRequest?,
    pendingInternalBatch: identical(pendingInternalBatch, _unset)
        ? this.pendingInternalBatch
        : pendingInternalBatch as InternalSignalingBatchRequest?,
    pendingSocketOpen: identical(pendingSocketOpen, _unset)
        ? this.pendingSocketOpen
        : pendingSocketOpen as OpenHpbSocketEffect?,
    pendingHpbFrame: identical(pendingHpbFrame, _unset)
        ? this.pendingHpbFrame
        : pendingHpbFrame as SendHpbFrameEffect?,
    awaitingHpbResponse: identical(awaitingHpbResponse, _unset)
        ? this.awaitingHpbResponse
        : awaitingHpbResponse as HpbClientFrame?,
    pendingDeadline: identical(pendingDeadline, _unset)
        ? this.pendingDeadline
        : pendingDeadline as ScheduleSignalingDeadlineEffect?,
  );

  @override
  String toString() =>
      'SignalingAccountState(phase: ${phase.name}, '
      'connectionEpoch: $connectionEpoch, roomEpoch: $roomEpoch, '
      'participants: ${participants.length}, signalingReady: $signalingReady, '
      'mediaReady: $mediaReady, sensitive: <redacted>)';
}

final class SignalingRuntimeSnapshot {
  SignalingRuntimeSnapshot({
    required Map<AccountId, SignalingAccountState> accounts,
  }) : accounts = UnmodifiableMapView(
         Map<AccountId, SignalingAccountState>.of(accounts),
       ) {
    for (final entry in this.accounts.entries) {
      if (entry.key != entry.value.accountId) {
        _stateFailure(r'$.accounts');
      }
    }
  }

  final Map<AccountId, SignalingAccountState> accounts;

  @override
  String toString() => 'SignalingRuntimeSnapshot(accounts: ${accounts.length})';
}

const Object _unset = Object();

Never _stateFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingState, path);
