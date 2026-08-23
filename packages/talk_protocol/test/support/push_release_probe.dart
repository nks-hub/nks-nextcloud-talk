import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';

import 'push_test_support.dart';

void main() {
  try {
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

    final encoded = base64Encode(List<int>.filled(256, 11));
    final routePlan = planPushEnvelopeRoute(
      snapshot,
      envelope: PushEnvelope.parse(
        envelopeId: PushEnvelopeId.parse('release-envelope'),
        subjectBase64: encoded,
        signatureBase64: encoded,
      ),
      effectId: pushEffectId(100),
    );
    final route = completePushEnvelopeRoute(
      snapshot,
      routePlan,
      PushCryptoBatchCompletion(
        effect: routePlan.effect!,
        candidates: <PushCryptoCandidateCompletion>[
          PushCryptoCandidateCompletion.valid(
            candidate: routePlan.effect!.candidates.single,
            padding: PushRsaPadding.oaepSha1,
            plaintextUtf8: '{"delete-all":true}',
          ),
        ],
      ),
    );
    if (route.outcome != PushRouteOutcome.routed ||
        route.routed?.accountId != pushAccountA) {
      throw StateError('Release push route invariant failed.');
    }

    snapshot = commitPushRuntime(
      snapshot,
      requestPushAccountRemoval(snapshot, authority),
    );
    var planned = planNextPushEffect(snapshot, effectId: pushEffectId(101));
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
    planned = planNextPushEffect(snapshot, effectId: pushEffectId(102));
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
    planned = planNextPushEffect(snapshot, effectId: pushEffectId(103));
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
    if (snapshot.accounts[pushAccountA]!.phase != PushAccountPhase.removed) {
      throw StateError('Release push removal invariant failed.');
    }
  } on Object catch (error) {
    stderr.writeln('Release push probe failed: ${error.runtimeType}');
    exitCode = 1;
  }
}
