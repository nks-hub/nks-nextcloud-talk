import 'package:drift/drift.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'app_database.dart';

/// Durable recovery boundary for one active signaling room per account.
///
/// Only authority identifiers and monotonic epochs are stored. Settings,
/// tickets, resume IDs, participants and pending realtime frames are omitted
/// intentionally because the protocol requires a fresh settings fetch and
/// renegotiation after process death.
final class CallSessionRepository {
  const CallSessionRepository(this._database);

  final AppDatabase _database;

  Future<void> persist(SignalingAccountState state, {DateTime? updatedAt}) {
    final timestamp = (updatedAt ?? DateTime.now()).toUtc();
    return _database.transaction(() async {
      await (_database.delete(_database.callSessions)..where(
            (row) =>
                row.accountId.equals(state.accountId.value) &
                row.roomToken.equals(state.roomToken.value).not(),
          ))
          .go();
      await _database
          .into(_database.callSessions)
          .insertOnConflictUpdate(
            CallSessionsCompanion.insert(
              accountId: state.accountId.value,
              roomToken: state.roomToken.value,
              serverUrl: state.server.uri.toString(),
              credentialGeneration: state.credentialGeneration,
              capabilityGeneration: state.capabilityGeneration,
              settingsRevision: state.settingsRevision,
              profileEnabled: state.profile.enabled,
              profileChatRelay: state.profile.chatRelay,
              nextcloudSessionId: state.nextcloudSessionId.value,
              connectionEpoch: state.connectionEpoch,
              roomEpoch: state.roomEpoch,
              renegotiationRequired: state.renegotiationRequired,
              updatedAtMillis: timestamp.millisecondsSinceEpoch,
            ),
          );
    });
  }

  /// Restores a persisted authority and immediately applies the pure-Dart
  /// restart transition. The returned snapshot therefore has fresh epochs,
  /// no transient secret or pending frame, and requires renegotiation.
  Future<SignalingRuntimeSnapshot?> recover({
    required String accountId,
    required String roomToken,
  }) async {
    final query = _database.select(_database.callSessions)
      ..where(
        (row) =>
            row.accountId.equals(accountId) & row.roomToken.equals(roomToken),
      );
    final stored = await query.getSingleOrNull();
    if (stored == null) {
      return null;
    }

    try {
      if ((!stored.profileEnabled && stored.profileChatRelay) ||
          stored.connectionEpoch < 0 ||
          stored.roomEpoch < 1 ||
          stored.credentialGeneration < 1 ||
          stored.capabilityGeneration < 1 ||
          stored.settingsRevision.isEmpty ||
          stored.settingsRevision.length > 128 ||
          stored.settingsRevision.codeUnits.any(
            (unit) => unit < 0x21 || unit > 0x7e,
          )) {
        throw const FormatException('Invalid call session state');
      }
      final profile = SignalingCapabilityProfile.fromTalkFeatures(<String>[
        if (stored.profileEnabled) 'signaling-v3',
        if (stored.profileChatRelay) 'chat-keep-notifications',
      ]);
      final parsedAccountId = AccountId.parse(stored.accountId);
      final restored = SignalingAccountState(
        accountId: parsedAccountId,
        server: ServerBase.parse(stored.serverUrl),
        credentialGeneration: stored.credentialGeneration,
        capabilityGeneration: stored.capabilityGeneration,
        settingsRevision: stored.settingsRevision,
        profile: profile,
        roomToken: ConversationToken.parse(
          stored.roomToken,
          path: r'$.roomToken',
        ),
        nextcloudSessionId: ConversationSessionId.parse(
          stored.nextcloudSessionId,
        ),
        phase: profile.enabled
            ? SignalingAccountPhase.idle
            : SignalingAccountPhase.unsupported,
        settings: null,
        connectionEpoch: stored.connectionEpoch,
        roomEpoch: stored.roomEpoch,
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
        renegotiationRequired: stored.renegotiationRequired,
        federatedPeerEpoch: 0,
        pendingSettingsRequest: null,
        pendingInternalPull: null,
        pendingInternalBatch: null,
        pendingSocketOpen: null,
        pendingHpbFrame: null,
        awaitingHpbResponse: null,
        pendingDeadline: null,
      );
      var snapshot = SignalingRuntimeSnapshot(
        accounts: <AccountId, SignalingAccountState>{parsedAccountId: restored},
      );
      final recovery = recoverSignalingAfterProcessRestart(
        snapshot,
        accountId: parsedAccountId,
      );
      if (!recovery.canCommit) {
        throw StateError('Signaling recovery was rejected');
      }
      snapshot = recovery.plan!.commit(snapshot);
      return snapshot;
    } on TalkProtocolException {
      await delete(accountId: accountId, roomToken: roomToken);
      return null;
    } on FormatException {
      await delete(accountId: accountId, roomToken: roomToken);
      return null;
    }
  }

  Future<void> delete({required String accountId, required String roomToken}) {
    return (_database.delete(_database.callSessions)..where(
          (row) =>
              row.accountId.equals(accountId) & row.roomToken.equals(roomToken),
        ))
        .go();
  }
}

/// Durable boundary for Talk's v4 call REST lifecycle.
///
/// Unlike [CallSessionRepository], this store survives signaling lane release.
/// It contains only authority, mutation phase and flags; credentials, peers,
/// HPB material and media state are never persisted.
final class CallLifecycleSessionRepository {
  const CallLifecycleSessionRepository(this._database);

  final AppDatabase _database;

  Future<void> persist(CallLifecycleState state) {
    return _database
        .into(_database.callLifecycleSessions)
        .insertOnConflictUpdate(
          CallLifecycleSessionsCompanion.insert(
            accountId: state.authority.accountId.value,
            roomToken: state.authority.roomToken.value,
            serverUrl: state.authority.server.uri.toString(),
            nextcloudSessionId: state.authority.nextcloudSessionId.value,
            credentialGeneration: state.authority.credentialGeneration,
            capabilityGeneration: state.authority.capabilityGeneration,
            capabilityRevision: state.authority.capabilityRevision,
            phase: state.phase.name,
            confirmedFlags: Value(state.confirmedFlags?.value),
            requestedFlags: Value(state.requestedFlags?.value),
            endForEveryone: Value(state.endForEveryone),
            mutationSequence: state.mutationSequence,
            updatedAtMillis: state.updatedAt.millisecondsSinceEpoch,
          ),
        );
  }

  /// Loads state only when every authority component still matches.
  ///
  /// A malformed row or drift in server, session, credential or capability
  /// authority is deleted instead of being replayed under a different login.
  Future<CallLifecycleState?> load({
    required CallLifecycleAuthority authority,
    bool afterRestart = false,
    DateTime? now,
  }) async {
    final accountId = authority.accountId.value;
    final roomToken = authority.roomToken.value;
    final query = _database.select(_database.callLifecycleSessions)
      ..where(
        (row) =>
            row.accountId.equals(accountId) & row.roomToken.equals(roomToken),
      );
    final stored = await query.getSingleOrNull();
    if (stored == null) {
      return null;
    }

    try {
      final storedAuthority = CallLifecycleAuthority(
        accountId: AccountId.parse(stored.accountId),
        server: ServerBase.parse(stored.serverUrl),
        roomToken: ConversationToken.parse(
          stored.roomToken,
          path: r'$.roomToken',
        ),
        nextcloudSessionId: ConversationSessionId.parse(
          stored.nextcloudSessionId,
        ),
        credentialGeneration: stored.credentialGeneration,
        capabilityGeneration: stored.capabilityGeneration,
        capabilityRevision: stored.capabilityRevision,
      );
      if (!storedAuthority.matches(authority) || stored.updatedAtMillis < 0) {
        throw const FormatException('Call lifecycle authority drift');
      }
      final phase = CallLifecyclePhase.values.byName(stored.phase);
      var state = CallLifecycleState(
        authority: storedAuthority,
        phase: phase,
        confirmedFlags: stored.confirmedFlags == null
            ? null
            : CallInCallFlags.parse(stored.confirmedFlags, requireJoined: true),
        requestedFlags: stored.requestedFlags == null
            ? null
            : CallInCallFlags.parse(stored.requestedFlags, requireJoined: true),
        endForEveryone: stored.endForEveryone,
        mutationSequence: stored.mutationSequence,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          stored.updatedAtMillis,
          isUtc: true,
        ),
      );
      if (afterRestart) {
        final recovered = state.afterRestart(
          updatedAt: (now ?? DateTime.now()).toUtc(),
        );
        if (!identical(recovered, state)) {
          state = recovered;
          await persist(state);
        }
      }
      return state;
    } on Object {
      await delete(accountId: accountId, roomToken: roomToken);
      return null;
    }
  }

  Future<void> delete({required String accountId, required String roomToken}) {
    return (_database.delete(_database.callLifecycleSessions)..where(
          (row) =>
              row.accountId.equals(accountId) & row.roomToken.equals(roomToken),
        ))
        .go();
  }
}
