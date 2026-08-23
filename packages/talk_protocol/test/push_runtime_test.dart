import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/push_test_support.dart';

void main() {
  group('push registration runtime', () {
    test('registers two servers through one deterministic token lane', () {
      var snapshot = PushRuntimeSnapshot.empty();
      final authorityA = pushAuthority(pushAccountA);
      final authorityB = pushAuthority(
        pushAccountB,
        server: 'https://cloud-b.example.invalid/nextcloud',
        cloudId: 'demo@cloud-b.example.invalid/nextcloud',
      );
      snapshot = commitPushRuntime(
        snapshot,
        addPushAccount(snapshot, authorityB),
      );
      snapshot = commitPushRuntime(
        snapshot,
        addPushAccount(snapshot, authorityA),
      );
      snapshot = commitPushRuntime(
        snapshot,
        installPushProviderToken(snapshot, pushProviderToken()),
      );

      expect(snapshot.registrationQueue, <AccountId>[
        pushAccountA,
        pushAccountB,
      ]);
      snapshot = completePushAccountRegistration(
        snapshot,
        authorityA,
        key: pushDeviceKey(pushAccountA),
      );

      expect(
        snapshot.accounts[pushAccountA]!.phase,
        PushAccountPhase.registered,
      );
      expect(snapshot.activeAccountId, isNull);
      expect(snapshot.registrationQueue, <AccountId>[pushAccountB]);

      final next = planNextPushEffect(snapshot, effectId: pushEffectId(10));
      expect(next.effect, isA<EnsurePushDeviceKeyEffect>());
      expect(next.accountId, pushAccountB);
    });

    test('409 retries once with the account cloudId', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authority,
      );
      var planned = planNextPushEffect(snapshot, effectId: pushEffectId(20));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushDeviceKeyCompletion.success(
            effect: planned.effect! as EnsurePushDeviceKeyEffect,
            key: pushDeviceKey(pushAccountA),
          ),
        ),
      );
      planned = planNextPushEffect(snapshot, effectId: pushEffectId(21));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushNextcloudRegistrationCompletion.success(
            effect: planned.effect! as RegisterPushWithNextcloudEffect,
            registration: pushServerRegistration(),
          ),
        ),
      );
      planned = planNextPushEffect(snapshot, effectId: pushEffectId(22));
      snapshot = commitPushRuntime(snapshot, planned);
      final first = planned.effect! as RegisterPushWithGatewayEffect;
      expect(first.cloudId, isNull);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushGatewayRegistrationCompletion.conflict(effect: first),
        ),
      );

      planned = planNextPushEffect(snapshot, effectId: pushEffectId(23));
      final recovery = planned.effect! as RegisterPushWithGatewayEffect;
      expect(recovery.cloudId, authority.cloudId);
      snapshot = commitPushRuntime(snapshot, planned);
      final repeated = completePushEffect(
        snapshot,
        PushGatewayRegistrationCompletion.conflict(effect: recovery),
      );
      snapshot = commitPushRuntime(snapshot, repeated);

      expect(snapshot.accounts[pushAccountA]!.phase, PushAccountPhase.failed);
      expect(snapshot.accounts[pushAccountA]!.errorClass, 'gateway-conflict');
    });

    test('token refresh keeps partial account failures isolated', () {
      final authorityA = pushAuthority(pushAccountA);
      final authorityB = pushAuthority(
        pushAccountB,
        server: 'https://cloud-b.example.invalid',
        cloudId: 'demo@cloud-b.example.invalid',
      );
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authorityA,
      );
      snapshot = commitPushRuntime(
        snapshot,
        addPushAccount(snapshot, authorityB),
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authorityA,
        key: pushDeviceKey(pushAccountA),
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authorityB,
        key: pushDeviceKey(pushAccountB),
        effectSeed: 10,
      );

      snapshot = commitPushRuntime(
        snapshot,
        installPushProviderToken(snapshot, pushProviderToken(generation: 2)),
      );
      var planned = planNextPushEffect(snapshot, effectId: pushEffectId(30));
      expect(planned.effect, isA<RegisterPushWithNextcloudEffect>());
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushNextcloudRegistrationCompletion.transientFailure(
            effect: planned.effect! as RegisterPushWithNextcloudEffect,
          ),
        ),
      );

      expect(
        snapshot.accounts[pushAccountA]!.phase,
        PushAccountPhase.retryable,
      );
      expect(snapshot.registrationQueue, <AccountId>[pushAccountB]);
      planned = planNextPushEffect(snapshot, effectId: pushEffectId(31));
      expect(planned.accountId, pushAccountB);
      expect(snapshot.accounts[pushAccountB]!.key, isNotNull);
    });

    test(
      'retry resumes the exact failed stage without duplicating the lane',
      () {
        final authority = pushAuthority(pushAccountA);
        var snapshot = addPushAccountAndToken(
          PushRuntimeSnapshot.empty(),
          authority,
        );
        var planned = planNextPushEffect(snapshot, effectId: pushEffectId(40));
        snapshot = commitPushRuntime(snapshot, planned);
        snapshot = commitPushRuntime(
          snapshot,
          completePushEffect(
            snapshot,
            PushDeviceKeyCompletion.success(
              effect: planned.effect! as EnsurePushDeviceKeyEffect,
              key: pushDeviceKey(pushAccountA),
            ),
          ),
        );
        planned = planNextPushEffect(snapshot, effectId: pushEffectId(41));
        snapshot = commitPushRuntime(snapshot, planned);
        snapshot = commitPushRuntime(
          snapshot,
          completePushEffect(
            snapshot,
            PushNextcloudRegistrationCompletion.transientFailure(
              effect: planned.effect! as RegisterPushWithNextcloudEffect,
            ),
          ),
        );

        snapshot = commitPushRuntime(
          snapshot,
          retryPushAccount(snapshot, authority),
        );
        final retry = planNextPushEffect(snapshot, effectId: pushEffectId(42));

        expect(retry.effect, isA<RegisterPushWithNextcloudEffect>());
        expect(snapshot.registrationQueue, <AccountId>[pushAccountA]);
      },
    );

    test('reauth refresh resumes with the new authority generation', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authority,
      );
      var planned = planNextPushEffect(snapshot, effectId: pushEffectId(43));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushDeviceKeyCompletion.success(
            effect: planned.effect! as EnsurePushDeviceKeyEffect,
            key: pushDeviceKey(pushAccountA),
          ),
        ),
      );
      planned = planNextPushEffect(snapshot, effectId: pushEffectId(44));
      snapshot = commitPushRuntime(snapshot, planned);
      final staleEffect = planned.effect! as RegisterPushWithNextcloudEffect;
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushNextcloudRegistrationCompletion.reauthenticationRequired(
            effect: staleEffect,
          ),
        ),
      );

      expect(
        snapshot.accounts[pushAccountA]!.retryPhase,
        PushAccountPhase.nextcloudRegistrationRequired,
      );
      final refreshedAuthority = pushAuthority(
        pushAccountA,
        credentialGeneration: 2,
        capabilityGeneration: 2,
      );
      snapshot = commitPushRuntime(
        snapshot,
        refreshPushAccountAuthority(snapshot, refreshedAuthority),
      );

      expect(
        snapshot.accounts[pushAccountA]!.phase,
        PushAccountPhase.nextcloudRegistrationRequired,
      );
      expect(snapshot.registrationQueue, <AccountId>[pushAccountA]);
      final next = planNextPushEffect(snapshot, effectId: pushEffectId(45));
      final nextEffect = next.effect! as RegisterPushWithNextcloudEffect;
      expect(nextEffect.context.credentialGeneration, 2);
      expect(nextEffect.context.capabilityGeneration, 2);
      expect(
        completePushEffect(
          snapshot,
          PushNextcloudRegistrationCompletion.success(
            effect: staleEffect,
            registration: pushServerRegistration(),
          ),
        ).outcome,
        PushRuntimeOutcome.rejected,
      );
    });

    test(
      'capability removal cleans remote state but preserves the account key',
      () {
        final authority = pushAuthority(pushAccountA);
        var snapshot = addPushAccountAndToken(
          PushRuntimeSnapshot.empty(),
          authority,
        );
        snapshot = completePushAccountRegistration(
          snapshot,
          authority,
          key: pushDeviceKey(pushAccountA),
        );
        final disabledAuthority = pushAuthority(
          pushAccountA,
          capabilityGeneration: 2,
          supportsPushV2: false,
        );
        snapshot = commitPushRuntime(
          snapshot,
          refreshPushAccountAuthority(snapshot, disabledAuthority),
        );
        expect(
          snapshot.accounts[pushAccountA]!.cleanupTarget,
          PushCleanupTarget.disablePush,
        );

        var planned = planNextPushEffect(snapshot, effectId: pushEffectId(46));
        snapshot = commitPushRuntime(snapshot, planned);
        snapshot = commitPushRuntime(
          snapshot,
          completePushEffect(
            snapshot,
            PushNextcloudUnregistrationCompletion.success(
              effect: planned.effect! as UnregisterPushFromNextcloudEffect,
            ),
          ),
        );
        planned = planNextPushEffect(snapshot, effectId: pushEffectId(47));
        snapshot = commitPushRuntime(snapshot, planned);
        snapshot = commitPushRuntime(
          snapshot,
          completePushEffect(
            snapshot,
            PushGatewayUnregistrationCompletion.success(
              effect: planned.effect! as UnregisterPushFromGatewayEffect,
            ),
          ),
        );

        final disabled = snapshot.accounts[pushAccountA]!;
        expect(disabled.phase, PushAccountPhase.unsupported);
        expect(disabled.key, isNotNull);
        expect(disabled.registration, isNull);
        expect(disabled.cleanupTarget, isNull);

        final enabledAuthority = pushAuthority(
          pushAccountA,
          capabilityGeneration: 3,
        );
        snapshot = commitPushRuntime(
          snapshot,
          refreshPushAccountAuthority(snapshot, enabledAuthority),
        );
        expect(
          snapshot.accounts[pushAccountA]!.phase,
          PushAccountPhase.nextcloudRegistrationRequired,
        );
        expect(snapshot.accounts[pushAccountA]!.key, isNotNull);
      },
    );

    test('capability removal preserves required account removal cleanup', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = _startAccountRemoval(authority);
      final disabledAuthority = pushAuthority(
        pushAccountA,
        credentialGeneration: 2,
        capabilityGeneration: 2,
        supportsPushV2: false,
      );

      snapshot = commitPushRuntime(
        snapshot,
        refreshPushAccountAuthority(snapshot, disabledAuthority),
      );

      final account = snapshot.accounts[pushAccountA]!;
      expect(account.cleanupTarget, PushCleanupTarget.removeAccount);
      expect(account.phase, PushAccountPhase.nextcloudUnregistrationRequired);
      expect(snapshot.registrationQueue, <AccountId>[pushAccountA]);
    });

    test('capability removal preserves retryable account removal cleanup', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = _startAccountRemoval(authority);
      snapshot = _failNextcloudRemoval(
        snapshot,
        PushNextcloudUnregistrationCompletion.transientFailure,
      );
      final disabledAuthority = pushAuthority(
        pushAccountA,
        credentialGeneration: 2,
        capabilityGeneration: 2,
        supportsPushV2: false,
      );

      snapshot = commitPushRuntime(
        snapshot,
        refreshPushAccountAuthority(snapshot, disabledAuthority),
      );

      final account = snapshot.accounts[pushAccountA]!;
      expect(account.cleanupTarget, PushCleanupTarget.removeAccount);
      expect(account.phase, PushAccountPhase.retryable);
      expect(
        account.retryPhase,
        PushAccountPhase.nextcloudUnregistrationRequired,
      );
      snapshot = commitPushRuntime(
        snapshot,
        retryPushAccount(snapshot, disabledAuthority),
      );
      expect(
        planNextPushEffect(snapshot, effectId: pushEffectId(103)).effect,
        isA<UnregisterPushFromNextcloudEffect>(),
      );
    });

    test('capability removal preserves reauthentication account removal', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = _startAccountRemoval(authority);
      snapshot = _failNextcloudRemoval(
        snapshot,
        PushNextcloudUnregistrationCompletion.reauthenticationRequired,
      );
      final disabledAuthority = pushAuthority(
        pushAccountA,
        credentialGeneration: 2,
        capabilityGeneration: 2,
        supportsPushV2: false,
      );

      snapshot = commitPushRuntime(
        snapshot,
        refreshPushAccountAuthority(snapshot, disabledAuthority),
      );

      final account = snapshot.accounts[pushAccountA]!;
      expect(account.cleanupTarget, PushCleanupTarget.removeAccount);
      expect(account.phase, PushAccountPhase.nextcloudUnregistrationRequired);
      expect(snapshot.registrationQueue, <AccountId>[pushAccountA]);
      expect(
        planNextPushEffect(snapshot, effectId: pushEffectId(104)).effect,
        isA<UnregisterPushFromNextcloudEffect>(),
      );
    });

    test('logout removes only one account and destroys its key last', () {
      final authorityA = pushAuthority(pushAccountA);
      final authorityB = pushAuthority(
        pushAccountB,
        server: 'https://cloud-b.example.invalid',
        cloudId: 'demo@cloud-b.example.invalid',
      );
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authorityA,
      );
      snapshot = commitPushRuntime(
        snapshot,
        addPushAccount(snapshot, authorityB),
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authorityA,
        key: pushDeviceKey(pushAccountA),
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authorityB,
        key: pushDeviceKey(pushAccountB),
        effectSeed: 10,
      );

      snapshot = commitPushRuntime(
        snapshot,
        requestPushAccountRemoval(snapshot, authorityA),
      );
      var planned = planNextPushEffect(snapshot, effectId: pushEffectId(50));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushNextcloudUnregistrationCompletion.success(
            effect: planned.effect! as UnregisterPushFromNextcloudEffect,
          ),
        ),
      );
      expect(snapshot.accounts[pushAccountA]!.key, isNotNull);

      planned = planNextPushEffect(snapshot, effectId: pushEffectId(51));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushGatewayUnregistrationCompletion.success(
            effect: planned.effect! as UnregisterPushFromGatewayEffect,
          ),
        ),
      );
      expect(snapshot.accounts[pushAccountA]!.key, isNotNull);

      planned = planNextPushEffect(snapshot, effectId: pushEffectId(52));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushDeviceKeyDestructionCompletion.success(
            effect: planned.effect! as DestroyPushDeviceKeyEffect,
          ),
        ),
      );

      expect(snapshot.accounts[pushAccountA]!.phase, PushAccountPhase.removed);
      expect(snapshot.accounts[pushAccountA]!.key, isNull);
      expect(
        snapshot.accounts[pushAccountB]!.phase,
        PushAccountPhase.registered,
      );
      expect(snapshot.providerToken!.generation, 1);
    });

    test('transient logout cleanup remains a retryable tombstone', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authority,
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authority,
        key: pushDeviceKey(pushAccountA),
      );
      snapshot = commitPushRuntime(
        snapshot,
        requestPushAccountRemoval(snapshot, authority),
      );
      var planned = planNextPushEffect(snapshot, effectId: pushEffectId(60));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushNextcloudUnregistrationCompletion.transientFailure(
            effect: planned.effect! as UnregisterPushFromNextcloudEffect,
          ),
        ),
      );

      final tombstone = snapshot.accounts[pushAccountA]!;
      expect(tombstone.phase, PushAccountPhase.retryable);
      expect(
        tombstone.retryPhase,
        PushAccountPhase.nextcloudUnregistrationRequired,
      );
      expect(tombstone.key, isNotNull);
      expect(tombstone.registration, isNotNull);
      snapshot = commitPushRuntime(
        snapshot,
        retryPushAccount(snapshot, authority),
      );
      planned = planNextPushEffect(snapshot, effectId: pushEffectId(61));
      expect(planned.effect, isA<UnregisterPushFromNextcloudEffect>());
      expect(snapshot.registrationQueue, <AccountId>[pushAccountA]);
    });

    test('token rotation cannot resurrect or commit stale logout work', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authority,
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authority,
        key: pushDeviceKey(pushAccountA),
      );
      snapshot = commitPushRuntime(
        snapshot,
        requestPushAccountRemoval(snapshot, authority),
      );
      final planned = planNextPushEffect(snapshot, effectId: pushEffectId(70));
      snapshot = commitPushRuntime(snapshot, planned);
      final staleEffect = planned.effect! as UnregisterPushFromNextcloudEffect;

      snapshot = commitPushRuntime(
        snapshot,
        installPushProviderToken(snapshot, pushProviderToken(generation: 2)),
      );

      expect(
        snapshot.accounts[pushAccountA]!.phase,
        PushAccountPhase.nextcloudUnregistrationRequired,
      );
      expect(
        completePushEffect(
          snapshot,
          PushNextcloudUnregistrationCompletion.success(effect: staleEffect),
        ).outcome,
        PushRuntimeOutcome.rejected,
      );
      final replacement = planNextPushEffect(
        snapshot,
        effectId: pushEffectId(71),
      );
      expect(replacement.effect, isA<UnregisterPushFromNextcloudEffect>());
      expect(replacement.effect!.context.providerTokenGeneration, 2);
    });

    test('logout requested during key creation waits and then cleans up', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authority,
      );
      final planned = planNextPushEffect(snapshot, effectId: pushEffectId(80));
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        requestPushAccountRemoval(snapshot, authority),
      );

      expect(
        snapshot.accounts[pushAccountA]!.pendingEffect,
        same(planned.effect),
      );
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          PushDeviceKeyCompletion.success(
            effect: planned.effect! as EnsurePushDeviceKeyEffect,
            key: pushDeviceKey(pushAccountA),
          ),
        ),
      );

      expect(
        snapshot.accounts[pushAccountA]!.phase,
        PushAccountPhase.nextcloudUnregistrationRequired,
      );
      final cleanup = planNextPushEffect(snapshot, effectId: pushEffectId(81));
      expect(cleanup.effect, isA<UnregisterPushFromNextcloudEffect>());
      snapshot = commitPushRuntime(snapshot, cleanup);
      final completion = completePushEffect(
        snapshot,
        PushNextcloudUnregistrationCompletion.success(
          effect: cleanup.effect! as UnregisterPushFromNextcloudEffect,
        ),
      );

      expect(completion.outcome, PushRuntimeOutcome.nextcloudUnregistered);
      snapshot = commitPushRuntime(snapshot, completion);
      expect(
        snapshot.accounts[pushAccountA]!.phase,
        PushAccountPhase.keyDestructionRequired,
      );
      expect(
        planNextPushEffect(snapshot, effectId: pushEffectId(82)).effect,
        isA<DestroyPushDeviceKeyEffect>(),
      );
    });
  });
}

PushRuntimeSnapshot _startAccountRemoval(PushRegistrationAuthority authority) {
  var snapshot = addPushAccountAndToken(PushRuntimeSnapshot.empty(), authority);
  snapshot = completePushAccountRegistration(
    snapshot,
    authority,
    key: pushDeviceKey(authority.accountId),
    effectSeed: 90,
  );
  return commitPushRuntime(
    snapshot,
    requestPushAccountRemoval(snapshot, authority),
  );
}

PushRuntimeSnapshot _failNextcloudRemoval(
  PushRuntimeSnapshot snapshot,
  PushNextcloudUnregistrationCompletion Function({
    required UnregisterPushFromNextcloudEffect effect,
  })
  completion,
) {
  final planned = planNextPushEffect(snapshot, effectId: pushEffectId(102));
  snapshot = commitPushRuntime(snapshot, planned);
  return commitPushRuntime(
    snapshot,
    completePushEffect(
      snapshot,
      completion(effect: planned.effect! as UnregisterPushFromNextcloudEffect),
    ),
  );
}
