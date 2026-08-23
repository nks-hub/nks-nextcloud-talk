import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/push_test_support.dart';

void main() {
  group('push effect binding', () {
    test('a stale completion cannot mutate a refreshed token generation', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authority,
      );
      final planned = planNextPushEffect(snapshot, effectId: pushEffectId(40));
      snapshot = commitPushRuntime(snapshot, planned);
      final staleEffect = planned.effect! as EnsurePushDeviceKeyEffect;
      snapshot = commitPushRuntime(
        snapshot,
        installPushProviderToken(snapshot, pushProviderToken(generation: 2)),
      );

      final stale = completePushEffect(
        snapshot,
        PushDeviceKeyCompletion.success(
          effect: staleEffect,
          key: pushDeviceKey(pushAccountA),
        ),
      );

      expect(stale.outcome, PushRuntimeOutcome.rejected);
      expect(stale.canCommit, isFalse);
    });

    test('two accounts cannot share one device key identity', () {
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
      final planned = planNextPushEffect(snapshot, effectId: pushEffectId(50));
      snapshot = commitPushRuntime(snapshot, planned);
      final duplicate = completePushEffect(
        snapshot,
        PushDeviceKeyCompletion.success(
          effect: planned.effect! as EnsurePushDeviceKeyEffect,
          key: PushDeviceKeyBinding(
            handle: PushKeyHandle.parse('different-handle'),
            publicKey: PushRsaPublicKey.parse(pushPublicKeyA),
            generation: 1,
          ),
        ),
      );

      expect(duplicate.outcome, PushRuntimeOutcome.rejected);
      expect(duplicate.canCommit, isFalse);
    });
  });

  group('exactly-one push routing', () {
    late PushRuntimeSnapshot snapshot;

    setUp(() {
      final authorityA = pushAuthority(pushAccountA);
      final authorityB = pushAuthority(
        pushAccountB,
        server: 'https://cloud-b.example.invalid',
        cloudId: 'demo@cloud-b.example.invalid',
      );
      snapshot = addPushAccountAndToken(
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
        registration: pushServerRegistration(userPublicKey: pushPublicKeyA),
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authorityB,
        key: pushDeviceKey(pushAccountB),
        registration: pushServerRegistration(userPublicKey: pushPublicKeyA),
        effectSeed: 10,
      );
    });

    PushEnvelope envelope() {
      final encoded = base64Encode(List<int>.filled(256, 9));
      return PushEnvelope.parse(
        envelopeId: PushEnvelopeId.parse('route-envelope'),
        subjectBase64: encoded,
        signatureBase64: encoded,
      );
    }

    test('signature sharing still routes only by one valid device decrypt', () {
      final plan = planPushEnvelopeRoute(
        snapshot,
        envelope: envelope(),
        effectId: pushEffectId(60),
      );
      final effect = plan.effect!;
      final result = completePushEnvelopeRoute(
        snapshot,
        plan,
        PushCryptoBatchCompletion(
          effect: effect,
          candidates: <PushCryptoCandidateCompletion>[
            PushCryptoCandidateCompletion.decryptFailed(
              candidate: effect.candidates[0],
            ),
            PushCryptoCandidateCompletion.valid(
              candidate: effect.candidates[1],
              padding: PushRsaPadding.oaepSha1,
              plaintextUtf8:
                  '{"app":"spreed","subject":"Synthetic",'
                  '"type":"chat","id":"roomb123","nid":42}',
            ),
          ],
        ),
      );

      expect(result.outcome, PushRouteOutcome.routed);
      expect(result.routed!.accountId, pushAccountB);
      expect(result.routed!.payload.notificationId, 42);
    });

    test('zero or multiple valid decrypts never trigger account sync', () {
      final zeroPlan = planPushEnvelopeRoute(
        snapshot,
        envelope: envelope(),
        effectId: pushEffectId(61),
      );
      final zero = completePushEnvelopeRoute(
        snapshot,
        zeroPlan,
        PushCryptoBatchCompletion(
          effect: zeroPlan.effect!,
          candidates: zeroPlan.effect!.candidates
              .map(
                (candidate) => PushCryptoCandidateCompletion.decryptFailed(
                  candidate: candidate,
                ),
              )
              .toList(),
        ),
      );
      expect(zero.outcome, PushRouteOutcome.unmatched);
      expect(zero.routed, isNull);

      final multiplePlan = planPushEnvelopeRoute(
        snapshot,
        envelope: envelope(),
        effectId: pushEffectId(62),
      );
      final multiple = completePushEnvelopeRoute(
        snapshot,
        multiplePlan,
        PushCryptoBatchCompletion(
          effect: multiplePlan.effect!,
          candidates: multiplePlan.effect!.candidates
              .map(
                (candidate) => PushCryptoCandidateCompletion.valid(
                  candidate: candidate,
                  padding: PushRsaPadding.pkcs1v15,
                  plaintextUtf8: '{"delete-all":true}',
                ),
              )
              .toList(),
        ),
      );
      expect(multiple.outcome, PushRouteOutcome.ambiguous);
      expect(multiple.routed, isNull);
    });

    test('missing or foreign candidate results are rejected', () {
      final plan = planPushEnvelopeRoute(
        snapshot,
        envelope: envelope(),
        effectId: pushEffectId(63),
      );
      expect(
        () => completePushEnvelopeRoute(
          snapshot,
          plan,
          PushCryptoBatchCompletion(
            effect: plan.effect!,
            candidates: <PushCryptoCandidateCompletion>[
              PushCryptoCandidateCompletion.decryptFailed(
                candidate: plan.effect!.candidates.first,
              ),
            ],
          ),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test(
      'same envelope ID cannot substitute ciphertext or signature bytes',
      () {
        final plan = planPushEnvelopeRoute(
          snapshot,
          envelope: envelope(),
          effectId: pushEffectId(64),
        );
        final effect = plan.effect!;
        final substitutedBytes = base64Encode(List<int>.filled(256, 10));
        final substituted = PushCryptoBatchEffect(
          effectId: effect.effectId,
          envelope: PushEnvelope.parse(
            envelopeId: effect.envelope.envelopeId,
            subjectBase64: substitutedBytes,
            signatureBase64: substitutedBytes,
          ),
          candidates: effect.candidates,
        );

        expect(
          () => completePushEnvelopeRoute(
            snapshot,
            plan,
            PushCryptoBatchCompletion(
              effect: substituted,
              candidates: effect.candidates
                  .map(
                    (candidate) => PushCryptoCandidateCompletion.decryptFailed(
                      candidate: candidate,
                    ),
                  )
                  .toList(),
            ),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      },
    );

    test('the same candidate completion cannot be supplied twice', () {
      final plan = planPushEnvelopeRoute(
        snapshot,
        envelope: envelope(),
        effectId: pushEffectId(65),
      );
      final first = PushCryptoCandidateCompletion.decryptFailed(
        candidate: plan.effect!.candidates.first,
      );

      expect(
        () => completePushEnvelopeRoute(
          snapshot,
          plan,
          PushCryptoBatchCompletion(
            effect: plan.effect!,
            candidates: <PushCryptoCandidateCompletion>[first, first],
          ),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.path,
            'path',
            r'$.cryptoResult.candidates',
          ),
        ),
      );
    });

    test('state changes invalidate a completed crypto route', () {
      final plan = planPushEnvelopeRoute(
        snapshot,
        envelope: envelope(),
        effectId: pushEffectId(66),
      );
      final effect = plan.effect!;
      final completion = PushCryptoBatchCompletion(
        effect: effect,
        candidates: <PushCryptoCandidateCompletion>[
          PushCryptoCandidateCompletion.valid(
            candidate: effect.candidates.first,
            padding: PushRsaPadding.oaepSha1,
            plaintextUtf8:
                '{"app":"spreed","subject":"Synthetic",'
                '"type":"chat","id":"rooma123","nid":42}',
          ),
          PushCryptoCandidateCompletion.decryptFailed(
            candidate: effect.candidates.last,
          ),
        ],
      );
      final authorityA = snapshot.accounts[pushAccountA]!.authority;
      final logoutSnapshot = commitPushRuntime(
        snapshot,
        requestPushAccountRemoval(snapshot, authorityA),
      );
      final tokenSnapshot = commitPushRuntime(
        snapshot,
        installPushProviderToken(snapshot, pushProviderToken(generation: 2)),
      );
      final authoritySnapshot = commitPushRuntime(
        snapshot,
        refreshPushAccountAuthority(
          snapshot,
          pushAuthority(
            pushAccountA,
            credentialGeneration: 2,
            capabilityGeneration: 2,
          ),
        ),
      );
      final keySnapshot = _replacePushAccount(
        snapshot,
        snapshot.accounts[pushAccountA]!.copyWith(
          key: pushDeviceKey(pushAccountA, generation: 2),
        ),
      );
      final revisionSnapshot = _replacePushAccount(
        snapshot,
        snapshot.accounts[pushAccountA]!.copyWith(
          registrationRevision:
              snapshot.accounts[pushAccountA]!.registrationRevision + 1,
        ),
      );

      for (final entry in <String, PushRuntimeSnapshot>{
        'logout': logoutSnapshot,
        'provider token rotation': tokenSnapshot,
        'authority refresh': authoritySnapshot,
        'key rotation': keySnapshot,
        'registration revision': revisionSnapshot,
      }.entries) {
        final result = completePushEnvelopeRoute(entry.value, plan, completion);
        expect(result.outcome, PushRouteOutcome.unmatched, reason: entry.key);
        expect(result.routed, isNull, reason: entry.key);
      }
    });
  });
}

PushRuntimeSnapshot _replacePushAccount(
  PushRuntimeSnapshot snapshot,
  PushAccountState account,
) {
  final accounts = Map<AccountId, PushAccountState>.of(snapshot.accounts);
  accounts[account.authority.accountId] = account;
  return PushRuntimeSnapshot(
    accounts: accounts,
    providerToken: snapshot.providerToken,
    registrationQueue: snapshot.registrationQueue,
    activeAccountId: snapshot.activeAccountId,
  );
}
