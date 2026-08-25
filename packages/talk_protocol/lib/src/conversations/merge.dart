import 'dart:collection';

import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';
import 'response.dart';

const Duration conversationEmptyConfirmationWindow = Duration(seconds: 300);

enum ConversationMergeOutcome { applied, confirmationRequired }

/// Durable evidence for the first suspicious full-empty response.
final class ConversationEmptyConfirmation {
  ConversationEmptyConfirmation({
    required this.requestId,
    required DateTime observedAt,
  }) : observedAt = observedAt.toUtc() {
    if (this.observedAt.millisecondsSinceEpoch < 0) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.observedAt',
      );
    }
  }

  final ConversationRequestId requestId;
  final DateTime observedAt;

  @override
  String toString() => 'ConversationEmptyConfirmation(<redacted>)';
}

/// Immutable persisted state for one server/user account.
final class ConversationAccountState {
  factory ConversationAccountState({
    required ServerBase server,
    required Iterable<ConversationRoom> rooms,
    ConversationCursor? cursor,
    ConversationConfigurationHash? configurationHash,
    ConversationEmptyConfirmation? emptyConfirmation,
    bool capabilityRefreshRequired = false,
  }) {
    final indexed = <ConversationToken, ConversationRoom>{};
    for (final room in rooms) {
      if (indexed.containsKey(room.token)) {
        protocolFailure(
          TalkProtocolErrorCode.invalidConversationMerge,
          r'$.rooms',
        );
      }
      indexed[room.token] = room;
    }
    return ConversationAccountState._(
      server: server,
      rooms: indexed,
      cursor: cursor,
      configurationHash: configurationHash,
      emptyConfirmation: emptyConfirmation,
      capabilityRefreshRequired: capabilityRefreshRequired,
    );
  }

  ConversationAccountState._({
    required this.server,
    required Map<ConversationToken, ConversationRoom> rooms,
    required this.cursor,
    required this.configurationHash,
    required this.emptyConfirmation,
    required this.capabilityRefreshRequired,
  }) : rooms = UnmodifiableMapView(
         Map<ConversationToken, ConversationRoom>.of(rooms),
       );

  final ServerBase server;
  final Map<ConversationToken, ConversationRoom> rooms;
  final ConversationCursor? cursor;
  final ConversationConfigurationHash? configurationHash;
  final ConversationEmptyConfirmation? emptyConfirmation;
  final bool capabilityRefreshRequired;

  @override
  String toString() =>
      'ConversationAccountState(roomCount: ${rooms.length}, '
      'hasCursor: ${cursor != null}, '
      'capabilityRefreshRequired: $capabilityRefreshRequired)';
}

/// Immutable state across all configured accounts.
final class ConversationSnapshot {
  factory ConversationSnapshot({
    required Map<AccountId, ConversationAccountState> accounts,
  }) {
    return ConversationSnapshot._(
      Map<AccountId, ConversationAccountState>.of(accounts),
    );
  }

  ConversationSnapshot._(Map<AccountId, ConversationAccountState> accounts)
    : accounts = UnmodifiableMapView(accounts);

  final Map<AccountId, ConversationAccountState> accounts;

  ConversationSnapshot apply(ConversationMergePlan plan) {
    final current = accounts[plan.accountId];
    if (current == null || !identical(current, plan.previousAccountState)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.snapshot',
      );
    }
    final updated = Map<AccountId, ConversationAccountState>.of(accounts);
    updated[plan.accountId] = plan.nextAccountState;
    return ConversationSnapshot._(updated);
  }

  @override
  String toString() => 'ConversationSnapshot(accountCount: ${accounts.length})';
}

/// Candidate database operations. Persistence must commit them atomically.
final class ConversationMergePlan {
  ConversationMergePlan._({
    required this.accountId,
    required this.outcome,
    required List<ConversationRoom> upserts,
    required Set<ConversationToken> deleteTokens,
    required this.previousAccountState,
    required this.nextAccountState,
  }) : upserts = List<ConversationRoom>.unmodifiable(upserts),
       deleteTokens = Set<ConversationToken>.unmodifiable(deleteTokens);

  final AccountId accountId;
  final ConversationMergeOutcome outcome;
  final List<ConversationRoom> upserts;
  final Set<ConversationToken> deleteTokens;
  final ConversationAccountState previousAccountState;
  final ConversationAccountState nextAccountState;

  @override
  String toString() =>
      'ConversationMergePlan(outcome: ${outcome.name}, '
      'upserts: ${upserts.length}, deletes: ${deleteTokens.length})';
}

/// Pure account-scoped planner for full and incremental conversation merges.
final class ConversationMergePlanner {
  const ConversationMergePlanner();

  ConversationMergePlan plan({
    required ConversationSnapshot snapshot,
    required ConversationListSuccess response,
    DateTime? observedAt,
  }) {
    final request = response.request;
    final accountId = request.accountId;
    final current = snapshot.accounts[accountId];
    if (current == null) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.accountId',
      );
    }
    if (request.server != current.server) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.server',
      );
    }
    if (request.mode == ConversationFetchMode.incremental &&
        request.cursor != current.cursor) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.query.modifiedSince',
      );
    }

    if (request.mode == ConversationFetchMode.full &&
        response.rooms.isEmpty &&
        current.rooms.isNotEmpty) {
      return _planGuardedEmpty(
        current: current,
        accountId: accountId,
        requestId: request.requestId,
        observedAt: observedAt,
        response: response,
      );
    }

    return _planApplied(
      current: current,
      accountId: accountId,
      mode: request.mode,
      response: response,
    );
  }

  ConversationMergePlan _planGuardedEmpty({
    required ConversationAccountState current,
    required AccountId accountId,
    required ConversationRequestId requestId,
    required DateTime? observedAt,
    required ConversationListSuccess response,
  }) {
    if (observedAt == null || observedAt.millisecondsSinceEpoch < 0) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.observedAt',
      );
    }
    final normalizedObservedAt = observedAt.toUtc();
    final previousProof = current.emptyConfirmation;
    if (previousProof != null && previousProof.requestId == requestId) {
      return _confirmationPlan(
        accountId: accountId,
        current: current,
        next: current,
      );
    }

    if (previousProof != null) {
      final age = normalizedObservedAt.difference(previousProof.observedAt);
      if (!age.isNegative && age <= conversationEmptyConfirmationWindow) {
        return _planApplied(
          current: current,
          accountId: accountId,
          mode: ConversationFetchMode.full,
          response: response,
        );
      }
    }

    final next = ConversationAccountState._(
      server: current.server,
      rooms: current.rooms,
      cursor: current.cursor,
      configurationHash: current.configurationHash,
      emptyConfirmation: ConversationEmptyConfirmation(
        requestId: requestId,
        observedAt: normalizedObservedAt,
      ),
      capabilityRefreshRequired: current.capabilityRefreshRequired,
    );
    return _confirmationPlan(
      accountId: accountId,
      current: current,
      next: next,
    );
  }

  ConversationMergePlan _confirmationPlan({
    required AccountId accountId,
    required ConversationAccountState current,
    required ConversationAccountState next,
  }) {
    return ConversationMergePlan._(
      accountId: accountId,
      outcome: ConversationMergeOutcome.confirmationRequired,
      upserts: const <ConversationRoom>[],
      deleteTokens: const <ConversationToken>{},
      previousAccountState: current,
      nextAccountState: next,
    );
  }

  ConversationMergePlan _planApplied({
    required ConversationAccountState current,
    required AccountId accountId,
    required ConversationFetchMode mode,
    required ConversationListSuccess response,
  }) {
    final nextRooms = mode == ConversationFetchMode.full
        ? <ConversationToken, ConversationRoom>{}
        : Map<ConversationToken, ConversationRoom>.of(current.rooms);
    final upserts = <ConversationRoom>[];
    for (final room in response.rooms) {
      final previous = current.rooms[room.token];
      final nextRoom = mode == ConversationFetchMode.incremental &&
              previous != null
          ? room.preserveUserStatusFrom(previous)
          : room;
      nextRooms[room.token] = nextRoom;
      upserts.add(nextRoom);
    }

    final deleteTokens = mode == ConversationFetchMode.full
        ? current.rooms.keys
              .where((token) => !nextRooms.containsKey(token))
              .toSet()
        : <ConversationToken>{};
    final previousHash = current.configurationHash;
    final hashChanged =
        previousHash != null && previousHash != response.configurationHash;
    final nextProof =
        mode == ConversationFetchMode.incremental && response.rooms.isEmpty
        ? current.emptyConfirmation
        : null;
    final next = ConversationAccountState._(
      server: current.server,
      rooms: nextRooms,
      cursor: response.cursor,
      configurationHash: response.configurationHash,
      emptyConfirmation: nextProof,
      capabilityRefreshRequired:
          current.capabilityRefreshRequired || hashChanged,
    );

    return ConversationMergePlan._(
      accountId: accountId,
      outcome: ConversationMergeOutcome.applied,
      upserts: upserts,
      deleteTokens: deleteTokens,
      previousAccountState: current,
      nextAccountState: next,
    );
  }
}
