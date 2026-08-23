import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import 'effects.dart';
import 'identifiers.dart';
import 'models.dart';

const Object _unset = Object();

enum PushAccountPhase {
  unsupported,
  waitingForToken,
  keyRequired,
  keyCreating,
  nextcloudRegistrationRequired,
  nextcloudRegistering,
  gatewayRegistrationRequired,
  gatewayRegistering,
  registered,
  retryable,
  reauthenticationRequired,
  failed,
  nextcloudUnregistrationRequired,
  nextcloudUnregistering,
  gatewayUnregistrationRequired,
  gatewayUnregistering,
  keyDestructionRequired,
  keyDestroying,
  removed,
}

enum PushCleanupTarget { disablePush, removeAccount }

enum PushRuntimeOutcome {
  accountAdded,
  tokenInstalled,
  effectPlanned,
  keyReady,
  nextcloudRegistered,
  gatewayRecoveryRequired,
  registered,
  retryable,
  reauthenticationRequired,
  failed,
  authorityRefreshed,
  removalRequested,
  nextcloudUnregistered,
  gatewayUnregistered,
  pushDisabled,
  removed,
  rejected,
  unchanged,
}

final class PushAccountState {
  PushAccountState({
    required this.authority,
    required this.phase,
    required this.key,
    required this.registration,
    required this.registrationRevision,
    required this.registeredProviderGeneration,
    required this.pendingEffect,
    required this.gatewayRecoveryAttempted,
    required this.errorClass,
    required this.retryPhase,
    required this.cleanupTarget,
  }) {
    if (registrationRevision < 0 ||
        (registeredProviderGeneration != null &&
            registeredProviderGeneration! < 1)) {
      _stateFailure(r'$.account');
    }
    final requiresRetryPhase =
        phase == PushAccountPhase.retryable ||
        phase == PushAccountPhase.reauthenticationRequired ||
        phase == PushAccountPhase.failed;
    if (requiresRetryPhase != (retryPhase != null) ||
        (phase == PushAccountPhase.removed &&
            (key != null ||
                registration != null ||
                registeredProviderGeneration != null ||
                pendingEffect != null ||
                cleanupTarget != null))) {
      _stateFailure(r'$.account.lifecycle');
    }
  }

  factory PushAccountState.initial(PushRegistrationAuthority authority) =>
      PushAccountState(
        authority: authority,
        phase: authority.supportsPushV2
            ? PushAccountPhase.waitingForToken
            : PushAccountPhase.unsupported,
        key: null,
        registration: null,
        registrationRevision: 0,
        registeredProviderGeneration: null,
        pendingEffect: null,
        gatewayRecoveryAttempted: false,
        errorClass: null,
        retryPhase: null,
        cleanupTarget: null,
      );

  final PushRegistrationAuthority authority;
  final PushAccountPhase phase;
  final PushDeviceKeyBinding? key;
  final PushServerRegistration? registration;
  final int registrationRevision;
  final int? registeredProviderGeneration;
  final PushEffect? pendingEffect;
  final bool gatewayRecoveryAttempted;
  final String? errorClass;
  final PushAccountPhase? retryPhase;
  final PushCleanupTarget? cleanupTarget;

  PushAccountState copyWith({
    Object? authority = _unset,
    PushAccountPhase? phase,
    Object? key = _unset,
    Object? registration = _unset,
    int? registrationRevision,
    Object? registeredProviderGeneration = _unset,
    Object? pendingEffect = _unset,
    bool? gatewayRecoveryAttempted,
    Object? errorClass = _unset,
    Object? retryPhase = _unset,
    Object? cleanupTarget = _unset,
  }) => PushAccountState(
    authority: identical(authority, _unset)
        ? this.authority
        : authority as PushRegistrationAuthority,
    phase: phase ?? this.phase,
    key: identical(key, _unset) ? this.key : key as PushDeviceKeyBinding?,
    registration: identical(registration, _unset)
        ? this.registration
        : registration as PushServerRegistration?,
    registrationRevision: registrationRevision ?? this.registrationRevision,
    registeredProviderGeneration:
        identical(registeredProviderGeneration, _unset)
        ? this.registeredProviderGeneration
        : registeredProviderGeneration as int?,
    pendingEffect: identical(pendingEffect, _unset)
        ? this.pendingEffect
        : pendingEffect as PushEffect?,
    gatewayRecoveryAttempted:
        gatewayRecoveryAttempted ?? this.gatewayRecoveryAttempted,
    errorClass: identical(errorClass, _unset)
        ? this.errorClass
        : errorClass as String?,
    retryPhase: identical(retryPhase, _unset)
        ? this.retryPhase
        : retryPhase as PushAccountPhase?,
    cleanupTarget: identical(cleanupTarget, _unset)
        ? this.cleanupTarget
        : cleanupTarget as PushCleanupTarget?,
  );

  @override
  String toString() =>
      'PushAccountState(phase: ${phase.name}, sensitive: <redacted>)';
}

final class PushRuntimeSnapshot {
  PushRuntimeSnapshot({
    required Map<AccountId, PushAccountState> accounts,
    required this.providerToken,
    required List<AccountId> registrationQueue,
    required this.activeAccountId,
  }) : accounts = UnmodifiableMapView<AccountId, PushAccountState>(
         Map<AccountId, PushAccountState>.of(accounts),
       ),
       registrationQueue = UnmodifiableListView<AccountId>(
         List<AccountId>.of(registrationQueue),
       ) {
    if (registrationQueue.toSet().length != registrationQueue.length ||
        registrationQueue.any(
          (accountId) => !accounts.containsKey(accountId),
        ) ||
        (activeAccountId != null &&
            !registrationQueue.contains(activeAccountId))) {
      _stateFailure(r'$.snapshot');
    }
  }

  factory PushRuntimeSnapshot.empty() => PushRuntimeSnapshot(
    accounts: const <AccountId, PushAccountState>{},
    providerToken: null,
    registrationQueue: const <AccountId>[],
    activeAccountId: null,
  );

  final Map<AccountId, PushAccountState> accounts;
  final PushProviderTokenBinding? providerToken;
  final List<AccountId> registrationQueue;
  final AccountId? activeAccountId;

  @override
  String toString() =>
      'PushRuntimeSnapshot(accounts: ${accounts.length}, sensitive: <redacted>)';
}

final class PushRuntimePlan {
  const PushRuntimePlan._(this.source, this.candidate);

  final PushRuntimeSnapshot source;
  final PushRuntimeSnapshot candidate;
}

final class PushRuntimeResult {
  const PushRuntimeResult._({
    required this.outcome,
    required this.accountId,
    required this.effect,
    required this.plan,
  });

  final PushRuntimeOutcome outcome;
  final AccountId? accountId;
  final PushEffect? effect;
  final PushRuntimePlan? plan;

  bool get canCommit => plan != null;

  @override
  String toString() =>
      'PushRuntimeResult(outcome: ${outcome.name}, sensitive: <redacted>)';
}

PushRuntimeSnapshot commitPushRuntime(
  PushRuntimeSnapshot current,
  PushRuntimeResult result,
) {
  final plan = result.plan;
  if (plan == null || !identical(plan.source, current)) {
    _stateFailure(r'$.commit');
  }
  return plan.candidate;
}

PushRuntimeResult addPushAccount(
  PushRuntimeSnapshot snapshot,
  PushRegistrationAuthority authority,
) {
  if (snapshot.accounts.containsKey(authority.accountId)) {
    return _result(PushRuntimeOutcome.rejected, accountId: authority.accountId);
  }
  var account = PushAccountState.initial(authority);
  final accounts = Map<AccountId, PushAccountState>.of(snapshot.accounts);
  final queue = List<AccountId>.of(snapshot.registrationQueue);
  if (authority.supportsPushV2 && snapshot.providerToken != null) {
    account = account.copyWith(phase: PushAccountPhase.keyRequired);
    queue.add(authority.accountId);
    _sortQueue(queue);
  }
  accounts[authority.accountId] = account;
  return _candidate(
    snapshot,
    PushRuntimeSnapshot(
      accounts: accounts,
      providerToken: snapshot.providerToken,
      registrationQueue: queue,
      activeAccountId: snapshot.activeAccountId,
    ),
    PushRuntimeOutcome.accountAdded,
    accountId: authority.accountId,
  );
}

PushRuntimeResult installPushProviderToken(
  PushRuntimeSnapshot snapshot,
  PushProviderTokenBinding providerToken,
) {
  final current = snapshot.providerToken;
  if (current != null) {
    if (current.bindingEquals(providerToken)) {
      return _result(PushRuntimeOutcome.unchanged);
    }
    if (providerToken.generation <= current.generation) {
      return _result(PushRuntimeOutcome.rejected);
    }
  }

  final accounts = <AccountId, PushAccountState>{};
  final queue = <AccountId>[];
  for (final entry in snapshot.accounts.entries) {
    final account = entry.value;
    if (account.phase == PushAccountPhase.removed) {
      accounts[entry.key] = account;
      continue;
    }
    if (account.cleanupTarget != null) {
      if (account.phase == PushAccountPhase.retryable ||
          account.phase == PushAccountPhase.reauthenticationRequired ||
          account.phase == PushAccountPhase.failed) {
        accounts[entry.key] = account.copyWith(
          registeredProviderGeneration: null,
          pendingEffect: null,
        );
        continue;
      }
      final cleanupPhase = _cleanupRequiredPhase(account);
      accounts[entry.key] = account.copyWith(
        phase: cleanupPhase,
        registeredProviderGeneration: null,
        pendingEffect: null,
        errorClass: null,
        retryPhase: null,
      );
      queue.add(entry.key);
      continue;
    }
    if (!account.authority.supportsPushV2) {
      accounts[entry.key] = account.copyWith(
        phase: PushAccountPhase.unsupported,
        pendingEffect: null,
        retryPhase: null,
      );
      continue;
    }
    accounts[entry.key] = account.copyWith(
      phase: account.key == null
          ? PushAccountPhase.keyRequired
          : PushAccountPhase.nextcloudRegistrationRequired,
      registration: null,
      registeredProviderGeneration: null,
      pendingEffect: null,
      gatewayRecoveryAttempted: false,
      errorClass: null,
      retryPhase: null,
    );
    queue.add(entry.key);
  }
  _sortQueue(queue);
  return _candidate(
    snapshot,
    PushRuntimeSnapshot(
      accounts: accounts,
      providerToken: providerToken,
      registrationQueue: queue,
      activeAccountId: null,
    ),
    PushRuntimeOutcome.tokenInstalled,
  );
}

PushRuntimeResult retryPushAccount(
  PushRuntimeSnapshot snapshot,
  PushRegistrationAuthority authority,
) {
  final account = snapshot.accounts[authority.accountId];
  final retryPhase = account?.retryPhase;
  if (account == null ||
      snapshot.providerToken == null ||
      !account.authority.bindingEquals(authority) ||
      account.phase != PushAccountPhase.retryable ||
      retryPhase == null ||
      account.pendingEffect != null ||
      !_isPlannablePhase(retryPhase)) {
    return _result(PushRuntimeOutcome.rejected, accountId: authority.accountId);
  }
  final queue = List<AccountId>.of(snapshot.registrationQueue);
  _enqueue(queue, authority.accountId);
  return _replaceAccount(
    snapshot,
    account.copyWith(phase: retryPhase, retryPhase: null, errorClass: null),
    PushRuntimeOutcome.retryable,
    registrationQueue: queue,
  );
}

PushRuntimeResult refreshPushAccountAuthority(
  PushRuntimeSnapshot snapshot,
  PushRegistrationAuthority authority,
) {
  final account = snapshot.accounts[authority.accountId];
  if (account == null ||
      account.phase == PushAccountPhase.removed ||
      account.pendingEffect != null ||
      account.authority.server != authority.server ||
      account.authority.gateway != authority.gateway ||
      account.authority.cloudId != authority.cloudId ||
      authority.credentialGeneration < account.authority.credentialGeneration ||
      authority.capabilityGeneration < account.authority.capabilityGeneration) {
    return _result(PushRuntimeOutcome.rejected, accountId: authority.accountId);
  }
  if (account.authority.bindingEquals(authority)) {
    return _result(
      PushRuntimeOutcome.unchanged,
      accountId: authority.accountId,
    );
  }

  final queue = List<AccountId>.of(snapshot.registrationQueue)
    ..remove(authority.accountId);
  var activeAccountId = snapshot.activeAccountId;
  if (activeAccountId == authority.accountId) {
    activeAccountId = null;
  }
  PushAccountState refreshed;
  if (account.cleanupTarget == PushCleanupTarget.removeAccount) {
    final phase = account.phase == PushAccountPhase.reauthenticationRequired
        ? account.retryPhase!
        : account.phase;
    refreshed = account.copyWith(
      authority: authority,
      phase: phase,
      retryPhase: account.phase == PushAccountPhase.reauthenticationRequired
          ? null
          : account.retryPhase,
      errorClass: account.phase == PushAccountPhase.reauthenticationRequired
          ? null
          : account.errorClass,
    );
    if (_isPlannablePhase(phase)) {
      _enqueue(queue, authority.accountId);
    }
  } else if (!authority.supportsPushV2) {
    if (account.key == null) {
      refreshed = account.copyWith(
        authority: authority,
        phase: PushAccountPhase.unsupported,
        registration: null,
        registeredProviderGeneration: null,
        pendingEffect: null,
        retryPhase: null,
        cleanupTarget: null,
        errorClass: null,
      );
    } else {
      refreshed = account.copyWith(
        authority: authority,
        phase: PushAccountPhase.nextcloudUnregistrationRequired,
        registeredProviderGeneration: null,
        pendingEffect: null,
        retryPhase: null,
        cleanupTarget: PushCleanupTarget.disablePush,
        errorClass: null,
      );
      _enqueue(queue, authority.accountId);
    }
  } else if (account.phase == PushAccountPhase.retryable ||
      account.phase == PushAccountPhase.failed) {
    refreshed = account.copyWith(authority: authority);
  } else if (account.phase == PushAccountPhase.reauthenticationRequired) {
    final retryPhase = account.retryPhase!;
    refreshed = account.copyWith(
      authority: authority,
      phase: retryPhase,
      retryPhase: null,
      errorClass: null,
    );
    _enqueue(queue, authority.accountId);
  } else if (snapshot.providerToken == null) {
    refreshed = account.copyWith(
      authority: authority,
      phase: PushAccountPhase.waitingForToken,
      registration: null,
      registeredProviderGeneration: null,
      pendingEffect: null,
      retryPhase: null,
      cleanupTarget: null,
      errorClass: null,
    );
  } else {
    refreshed = account.copyWith(
      authority: authority,
      phase: account.key == null
          ? PushAccountPhase.keyRequired
          : PushAccountPhase.nextcloudRegistrationRequired,
      registration: null,
      registeredProviderGeneration: null,
      pendingEffect: null,
      gatewayRecoveryAttempted: false,
      retryPhase: null,
      cleanupTarget: null,
      errorClass: null,
    );
    _enqueue(queue, authority.accountId);
  }
  return _replaceAccount(
    snapshot,
    refreshed,
    PushRuntimeOutcome.authorityRefreshed,
    registrationQueue: queue,
    activeAccountId: activeAccountId,
  );
}

PushRuntimeResult requestPushAccountRemoval(
  PushRuntimeSnapshot snapshot,
  PushRegistrationAuthority authority,
) {
  final account = snapshot.accounts[authority.accountId];
  if (account == null || !account.authority.bindingEquals(authority)) {
    return _result(PushRuntimeOutcome.rejected, accountId: authority.accountId);
  }
  if (account.phase == PushAccountPhase.removed ||
      account.cleanupTarget == PushCleanupTarget.removeAccount) {
    return _result(
      PushRuntimeOutcome.unchanged,
      accountId: authority.accountId,
    );
  }
  if (account.pendingEffect != null) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        registeredProviderGeneration: null,
        cleanupTarget: PushCleanupTarget.removeAccount,
        errorClass: null,
      ),
      PushRuntimeOutcome.removalRequested,
    );
  }

  final queue = List<AccountId>.of(snapshot.registrationQueue);
  if (account.key == null) {
    queue.remove(authority.accountId);
    return _replaceAccount(
      snapshot,
      _asRemoved(account),
      PushRuntimeOutcome.removed,
      registrationQueue: queue,
      activeAccountId: snapshot.activeAccountId == authority.accountId
          ? null
          : snapshot.activeAccountId,
    );
  }
  final cleanupPhase =
      account.phase == PushAccountPhase.unsupported &&
          account.registration == null
      ? PushAccountPhase.keyDestructionRequired
      : _cleanupRequiredPhase(account);
  _enqueue(queue, authority.accountId);
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: cleanupPhase,
      registeredProviderGeneration: null,
      pendingEffect: null,
      retryPhase: null,
      cleanupTarget: PushCleanupTarget.removeAccount,
      errorClass: null,
    ),
    PushRuntimeOutcome.removalRequested,
    registrationQueue: queue,
  );
}

PushRuntimeResult planNextPushEffect(
  PushRuntimeSnapshot snapshot, {
  required PushEffectId effectId,
}) {
  final providerToken = snapshot.providerToken;
  if (providerToken == null || snapshot.registrationQueue.isEmpty) {
    return _result(PushRuntimeOutcome.unchanged);
  }
  final accountId =
      snapshot.activeAccountId ?? snapshot.registrationQueue.first;
  final account = snapshot.accounts[accountId];
  if (account == null || account.pendingEffect != null) {
    return _result(PushRuntimeOutcome.rejected, accountId: accountId);
  }
  final context = PushEffectContext.forAuthority(
    effectId: effectId,
    authority: account.authority,
    providerTokenGeneration: providerToken.generation,
    keyGeneration: account.key?.generation ?? 0,
    registrationRevision: account.registrationRevision,
  );

  late final PushEffect effect;
  late final PushAccountPhase phase;
  switch (account.phase) {
    case PushAccountPhase.keyRequired:
      effect = EnsurePushDeviceKeyEffect(context: context);
      phase = PushAccountPhase.keyCreating;
    case PushAccountPhase.nextcloudRegistrationRequired:
      final key = account.key;
      if (key == null) {
        return _result(PushRuntimeOutcome.rejected, accountId: accountId);
      }
      effect = RegisterPushWithNextcloudEffect(
        context: context,
        providerToken: providerToken,
        key: key,
      );
      phase = PushAccountPhase.nextcloudRegistering;
    case PushAccountPhase.gatewayRegistrationRequired:
      final registration = account.registration;
      if (registration == null || account.registrationRevision < 1) {
        return _result(PushRuntimeOutcome.rejected, accountId: accountId);
      }
      effect = RegisterPushWithGatewayEffect(
        context: context,
        providerToken: providerToken,
        registration: registration,
        cloudId: account.gatewayRecoveryAttempted
            ? account.authority.cloudId
            : null,
      );
      phase = PushAccountPhase.gatewayRegistering;
    case PushAccountPhase.nextcloudUnregistrationRequired:
      if (account.cleanupTarget == null) {
        return _result(PushRuntimeOutcome.rejected, accountId: accountId);
      }
      effect = UnregisterPushFromNextcloudEffect(context: context);
      phase = PushAccountPhase.nextcloudUnregistering;
    case PushAccountPhase.gatewayUnregistrationRequired:
      final registration = account.registration;
      if (account.cleanupTarget == null ||
          registration == null ||
          account.registrationRevision < 1) {
        return _result(PushRuntimeOutcome.rejected, accountId: accountId);
      }
      effect = UnregisterPushFromGatewayEffect(
        context: context,
        registration: registration,
      );
      phase = PushAccountPhase.gatewayUnregistering;
    case PushAccountPhase.keyDestructionRequired:
      final key = account.key;
      if (account.cleanupTarget != PushCleanupTarget.removeAccount ||
          key == null) {
        return _result(PushRuntimeOutcome.rejected, accountId: accountId);
      }
      effect = DestroyPushDeviceKeyEffect(context: context, key: key);
      phase = PushAccountPhase.keyDestroying;
    case PushAccountPhase.unsupported:
    case PushAccountPhase.waitingForToken:
    case PushAccountPhase.keyCreating:
    case PushAccountPhase.nextcloudRegistering:
    case PushAccountPhase.gatewayRegistering:
    case PushAccountPhase.registered:
    case PushAccountPhase.retryable:
    case PushAccountPhase.reauthenticationRequired:
    case PushAccountPhase.failed:
    case PushAccountPhase.nextcloudUnregistering:
    case PushAccountPhase.gatewayUnregistering:
    case PushAccountPhase.keyDestroying:
    case PushAccountPhase.removed:
      return _result(PushRuntimeOutcome.rejected, accountId: accountId);
  }
  final updated = account.copyWith(
    phase: phase,
    pendingEffect: effect,
    errorClass: null,
  );
  return _replaceAccount(
    snapshot,
    updated,
    PushRuntimeOutcome.effectPlanned,
    effect: effect,
    activeAccountId: accountId,
  );
}

PushRuntimeResult completePushEffect(
  PushRuntimeSnapshot snapshot,
  PushEffectCompletion completion,
) {
  final accountId = completion.effect.context.accountId;
  final account = snapshot.accounts[accountId];
  final providerToken = snapshot.providerToken;
  if (account == null ||
      providerToken == null ||
      snapshot.activeAccountId != accountId ||
      account.pendingEffect == null ||
      !account.pendingEffect!.bindingEquals(completion.effect) ||
      !_contextMatches(account, providerToken, completion.effect.context)) {
    return _result(PushRuntimeOutcome.rejected, accountId: accountId);
  }

  return switch (completion) {
    final PushDeviceKeyCompletion value => _completeDeviceKey(
      snapshot,
      account,
      value,
    ),
    final PushNextcloudRegistrationCompletion value => _completeNextcloud(
      snapshot,
      account,
      value,
    ),
    final PushGatewayRegistrationCompletion value => _completeGateway(
      snapshot,
      account,
      value,
    ),
    final PushNextcloudUnregistrationCompletion value =>
      _completeNextcloudUnregistration(snapshot, account, value),
    final PushGatewayUnregistrationCompletion value =>
      _completeGatewayUnregistration(snapshot, account, value),
    final PushDeviceKeyDestructionCompletion value =>
      _completeDeviceKeyDestruction(snapshot, account, value),
  };
}

PushRuntimeResult _completeDeviceKey(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushDeviceKeyCompletion completion,
) {
  if (account.phase != PushAccountPhase.keyCreating) {
    return _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    );
  }
  if (completion.classification != PushCompletionClass.success) {
    return _completeFailure(
      snapshot,
      account,
      completion.classification,
      'key',
      retryPhase: PushAccountPhase.keyRequired,
    );
  }
  final key = completion.key!;
  final duplicate = snapshot.accounts.values.any(
    (other) =>
        other.authority.accountId != account.authority.accountId &&
        other.key != null &&
        (other.key!.handle == key.handle ||
            other.key!.publicKey == key.publicKey),
  );
  if (duplicate) {
    return _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    );
  }
  if (account.cleanupTarget != null) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: PushAccountPhase.nextcloudUnregistrationRequired,
        key: key,
        registeredProviderGeneration: null,
        pendingEffect: null,
        retryPhase: null,
        errorClass: null,
      ),
      PushRuntimeOutcome.removalRequested,
    );
  }
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: PushAccountPhase.nextcloudRegistrationRequired,
      key: key,
      pendingEffect: null,
      retryPhase: null,
      errorClass: null,
    ),
    PushRuntimeOutcome.keyReady,
  );
}

PushRuntimeResult _completeNextcloud(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushNextcloudRegistrationCompletion completion,
) {
  if (account.phase != PushAccountPhase.nextcloudRegistering) {
    return _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    );
  }
  if (completion.classification != PushCompletionClass.success) {
    if (account.cleanupTarget != null &&
        completion.classification !=
            PushCompletionClass.reauthenticationRequired) {
      return _replaceAccount(
        snapshot,
        account.copyWith(
          phase: PushAccountPhase.nextcloudUnregistrationRequired,
          registeredProviderGeneration: null,
          pendingEffect: null,
          retryPhase: null,
          errorClass: 'registration-cleanup-required',
        ),
        PushRuntimeOutcome.removalRequested,
      );
    }
    return _completeFailure(
      snapshot,
      account,
      completion.classification,
      'nextcloud-registration',
      retryPhase: account.cleanupTarget == null
          ? PushAccountPhase.nextcloudRegistrationRequired
          : PushAccountPhase.nextcloudUnregistrationRequired,
    );
  }
  if (account.cleanupTarget != null) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: PushAccountPhase.nextcloudUnregistrationRequired,
        registration: completion.registration,
        registrationRevision: account.registrationRevision + 1,
        registeredProviderGeneration: null,
        pendingEffect: null,
        gatewayRecoveryAttempted: false,
        retryPhase: null,
        errorClass: null,
      ),
      PushRuntimeOutcome.removalRequested,
    );
  }
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: PushAccountPhase.gatewayRegistrationRequired,
      registration: completion.registration,
      registrationRevision: account.registrationRevision + 1,
      pendingEffect: null,
      gatewayRecoveryAttempted: false,
      retryPhase: null,
      errorClass: null,
    ),
    PushRuntimeOutcome.nextcloudRegistered,
  );
}

PushRuntimeResult _completeGateway(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushGatewayRegistrationCompletion completion,
) {
  if (account.phase != PushAccountPhase.gatewayRegistering) {
    return _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    );
  }
  if (account.cleanupTarget != null) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: PushAccountPhase.nextcloudUnregistrationRequired,
        registeredProviderGeneration: null,
        pendingEffect: null,
        gatewayRecoveryAttempted: false,
        retryPhase: null,
        errorClass: completion.classification == PushCompletionClass.success
            ? null
            : 'gateway-registration-cleanup-required',
      ),
      PushRuntimeOutcome.removalRequested,
    );
  }
  if (completion.classification == PushCompletionClass.success) {
    final updated = account.copyWith(
      phase: PushAccountPhase.registered,
      registeredProviderGeneration: snapshot.providerToken!.generation,
      pendingEffect: null,
      retryPhase: null,
      errorClass: null,
    );
    return _finishLane(snapshot, updated, PushRuntimeOutcome.registered);
  }
  if (completion.classification == PushCompletionClass.conflict &&
      !account.gatewayRecoveryAttempted &&
      account.authority.cloudId != null &&
      completion.effect.cloudId == null) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: PushAccountPhase.gatewayRegistrationRequired,
        pendingEffect: null,
        gatewayRecoveryAttempted: true,
        retryPhase: null,
        errorClass: 'gateway-conflict-recovery',
      ),
      PushRuntimeOutcome.gatewayRecoveryRequired,
    );
  }
  return _completeFailure(
    snapshot,
    account,
    completion.classification == PushCompletionClass.conflict
        ? PushCompletionClass.rejected
        : completion.classification,
    completion.classification == PushCompletionClass.conflict
        ? 'gateway-conflict'
        : 'gateway-registration',
    retryPhase: PushAccountPhase.gatewayRegistrationRequired,
  );
}

PushRuntimeResult _completeNextcloudUnregistration(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushNextcloudUnregistrationCompletion completion,
) {
  if (account.phase != PushAccountPhase.nextcloudUnregistering ||
      account.cleanupTarget == null) {
    return _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    );
  }
  if (completion.classification != PushCompletionClass.success) {
    return _completeFailure(
      snapshot,
      account,
      completion.classification,
      'nextcloud-unregistration',
      retryPhase: PushAccountPhase.nextcloudUnregistrationRequired,
    );
  }
  if (account.registration != null) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: PushAccountPhase.gatewayUnregistrationRequired,
        registeredProviderGeneration: null,
        pendingEffect: null,
        retryPhase: null,
        errorClass: null,
      ),
      PushRuntimeOutcome.nextcloudUnregistered,
    );
  }
  return _advanceAfterRemoteCleanup(
    snapshot,
    account,
    completedOutcome: PushRuntimeOutcome.nextcloudUnregistered,
  );
}

PushRuntimeResult _completeGatewayUnregistration(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushGatewayUnregistrationCompletion completion,
) {
  if (account.phase != PushAccountPhase.gatewayUnregistering ||
      account.cleanupTarget == null) {
    return _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    );
  }
  if (completion.classification != PushCompletionClass.success) {
    return _completeFailure(
      snapshot,
      account,
      completion.classification,
      'gateway-unregistration',
      retryPhase: PushAccountPhase.gatewayUnregistrationRequired,
    );
  }
  return _advanceAfterRemoteCleanup(
    snapshot,
    account.copyWith(registration: null),
    completedOutcome: PushRuntimeOutcome.gatewayUnregistered,
  );
}

PushRuntimeResult _completeDeviceKeyDestruction(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushDeviceKeyDestructionCompletion completion,
) {
  if (account.phase != PushAccountPhase.keyDestroying ||
      account.cleanupTarget != PushCleanupTarget.removeAccount) {
    return _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    );
  }
  if (completion.classification != PushCompletionClass.success) {
    return _completeFailure(
      snapshot,
      account,
      completion.classification,
      'key-destruction',
      retryPhase: PushAccountPhase.keyDestructionRequired,
    );
  }
  return _finishLane(snapshot, _asRemoved(account), PushRuntimeOutcome.removed);
}

PushRuntimeResult _advanceAfterRemoteCleanup(
  PushRuntimeSnapshot snapshot,
  PushAccountState account, {
  required PushRuntimeOutcome completedOutcome,
}) {
  return switch (account.cleanupTarget) {
    PushCleanupTarget.removeAccount => _replaceAccount(
      snapshot,
      account.copyWith(
        phase: PushAccountPhase.keyDestructionRequired,
        registration: null,
        registeredProviderGeneration: null,
        pendingEffect: null,
        retryPhase: null,
        errorClass: null,
      ),
      completedOutcome,
    ),
    PushCleanupTarget.disablePush => _finishLane(
      snapshot,
      account.copyWith(
        phase: PushAccountPhase.unsupported,
        registration: null,
        registeredProviderGeneration: null,
        pendingEffect: null,
        retryPhase: null,
        cleanupTarget: null,
        errorClass: null,
      ),
      PushRuntimeOutcome.pushDisabled,
    ),
    null => _result(
      PushRuntimeOutcome.rejected,
      accountId: account.authority.accountId,
    ),
  };
}

PushRuntimeResult _completeFailure(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushCompletionClass classification,
  String errorPrefix, {
  required PushAccountPhase retryPhase,
}) {
  final (phase, outcome, suffix) = switch (classification) {
    PushCompletionClass.reauthenticationRequired => (
      PushAccountPhase.reauthenticationRequired,
      PushRuntimeOutcome.reauthenticationRequired,
      'reauthentication-required',
    ),
    PushCompletionClass.transientFailure => (
      PushAccountPhase.retryable,
      PushRuntimeOutcome.retryable,
      'transient',
    ),
    PushCompletionClass.rejected || PushCompletionClass.conflict => (
      PushAccountPhase.failed,
      PushRuntimeOutcome.failed,
      'rejected',
    ),
    PushCompletionClass.success => throw StateError(
      'A successful completion cannot enter failure handling.',
    ),
  };
  final errorClass = errorPrefix == 'gateway-conflict'
      ? errorPrefix
      : '$errorPrefix-$suffix';
  final updated = account.copyWith(
    phase: phase,
    pendingEffect: null,
    errorClass: errorClass,
    retryPhase: retryPhase,
  );
  return _finishLane(snapshot, updated, outcome);
}

bool _contextMatches(
  PushAccountState account,
  PushProviderTokenBinding providerToken,
  PushEffectContext context,
) =>
    context.accountId == account.authority.accountId &&
    context.server == account.authority.server &&
    context.gateway == account.authority.gateway &&
    context.credentialGeneration == account.authority.credentialGeneration &&
    context.capabilityGeneration == account.authority.capabilityGeneration &&
    context.providerTokenGeneration == providerToken.generation &&
    context.keyGeneration == (account.key?.generation ?? 0) &&
    context.registrationRevision == account.registrationRevision;

PushRuntimeResult _finishLane(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushRuntimeOutcome outcome,
) {
  final queue = List<AccountId>.of(snapshot.registrationQueue)
    ..remove(account.authority.accountId);
  return _replaceAccount(
    snapshot,
    account,
    outcome,
    registrationQueue: queue,
    activeAccountId: null,
  );
}

PushRuntimeResult _replaceAccount(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
  PushRuntimeOutcome outcome, {
  PushEffect? effect,
  List<AccountId>? registrationQueue,
  Object? activeAccountId = _unset,
}) {
  final accounts = Map<AccountId, PushAccountState>.of(snapshot.accounts);
  accounts[account.authority.accountId] = account;
  final active = identical(activeAccountId, _unset)
      ? snapshot.activeAccountId
      : activeAccountId as AccountId?;
  return _candidate(
    snapshot,
    PushRuntimeSnapshot(
      accounts: accounts,
      providerToken: snapshot.providerToken,
      registrationQueue: registrationQueue ?? snapshot.registrationQueue,
      activeAccountId: active,
    ),
    outcome,
    accountId: account.authority.accountId,
    effect: effect,
  );
}

PushRuntimeResult _candidate(
  PushRuntimeSnapshot source,
  PushRuntimeSnapshot candidate,
  PushRuntimeOutcome outcome, {
  AccountId? accountId,
  PushEffect? effect,
}) => PushRuntimeResult._(
  outcome: outcome,
  accountId: accountId,
  effect: effect,
  plan: PushRuntimePlan._(source, candidate),
);

PushRuntimeResult _result(PushRuntimeOutcome outcome, {AccountId? accountId}) =>
    PushRuntimeResult._(
      outcome: outcome,
      accountId: accountId,
      effect: null,
      plan: null,
    );

PushAccountState _asRemoved(PushAccountState account) => account.copyWith(
  phase: PushAccountPhase.removed,
  key: null,
  registration: null,
  registeredProviderGeneration: null,
  pendingEffect: null,
  gatewayRecoveryAttempted: false,
  errorClass: null,
  retryPhase: null,
  cleanupTarget: null,
);

PushAccountPhase _cleanupRequiredPhase(PushAccountState account) {
  if (account.key == null) {
    return PushAccountPhase.keyRequired;
  }
  return switch (account.phase) {
    PushAccountPhase.gatewayUnregistrationRequired ||
    PushAccountPhase.gatewayUnregistering =>
      account.registration == null
          ? PushAccountPhase.keyDestructionRequired
          : PushAccountPhase.gatewayUnregistrationRequired,
    PushAccountPhase.keyDestructionRequired ||
    PushAccountPhase.keyDestroying => PushAccountPhase.keyDestructionRequired,
    _ => PushAccountPhase.nextcloudUnregistrationRequired,
  };
}

bool _isPlannablePhase(PushAccountPhase phase) => switch (phase) {
  PushAccountPhase.keyRequired ||
  PushAccountPhase.nextcloudRegistrationRequired ||
  PushAccountPhase.gatewayRegistrationRequired ||
  PushAccountPhase.nextcloudUnregistrationRequired ||
  PushAccountPhase.gatewayUnregistrationRequired ||
  PushAccountPhase.keyDestructionRequired => true,
  _ => false,
};

void _enqueue(List<AccountId> queue, AccountId accountId) {
  if (!queue.contains(accountId)) {
    queue.add(accountId);
    _sortQueue(queue);
  }
}

void _sortQueue(List<AccountId> queue) =>
    queue.sort((left, right) => left.value.compareTo(right.value));

Never _stateFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidPushState, path);
