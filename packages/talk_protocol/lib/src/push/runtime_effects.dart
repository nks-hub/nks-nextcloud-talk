part of 'runtime.dart';

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
