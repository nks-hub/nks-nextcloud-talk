import 'dart:collection';
import 'dart:convert';

import '../identifiers.dart';
import '../protocol_exception.dart';
import 'crypto_material.dart';
import 'identifiers.dart';
import 'models.dart';
import 'runtime.dart';

enum PushRsaPadding { oaepSha1, pkcs1v15 }

enum PushCryptoCandidateStatus { signatureMismatch, decryptFailed, valid }

enum PushRouteOutcome { routed, unmatched, ambiguous }

final class PushCryptoCandidate {
  const PushCryptoCandidate({
    required this.accountId,
    required this.keyHandle,
    required this.keyGeneration,
    required this.userPublicKey,
    required this.registrationRevision,
    required this.providerTokenGeneration,
  });

  final AccountId accountId;
  final PushKeyHandle keyHandle;
  final int keyGeneration;
  final PushRsaPublicKey userPublicKey;
  final int registrationRevision;
  final int providerTokenGeneration;

  bool bindingEquals(PushCryptoCandidate other) =>
      accountId == other.accountId &&
      keyHandle == other.keyHandle &&
      keyGeneration == other.keyGeneration &&
      userPublicKey == other.userPublicKey &&
      registrationRevision == other.registrationRevision &&
      providerTokenGeneration == other.providerTokenGeneration;

  @override
  String toString() => 'PushCryptoCandidate(<redacted>)';
}

final class PushCryptoBatchEffect {
  PushCryptoBatchEffect({
    required this.effectId,
    required this.envelope,
    required List<PushCryptoCandidate> candidates,
  }) : candidates = UnmodifiableListView<PushCryptoCandidate>(
         List<PushCryptoCandidate>.of(candidates),
       ) {
    if (candidates.isEmpty ||
        candidates.map((candidate) => candidate.accountId).toSet().length !=
            candidates.length) {
      _cryptoResultFailure(r'$.cryptoEffect.candidates');
    }
  }

  final PushEffectId effectId;
  final PushEnvelope envelope;
  final List<PushCryptoCandidate> candidates;

  bool bindingEquals(PushCryptoBatchEffect other) {
    if (effectId != other.effectId ||
        envelope.envelopeId != other.envelope.envelopeId ||
        !_constantBytesEqual(envelope.ciphertext, other.envelope.ciphertext) ||
        !_constantBytesEqual(envelope.signature, other.envelope.signature) ||
        candidates.length != other.candidates.length) {
      return false;
    }
    for (var index = 0; index < candidates.length; index++) {
      if (!candidates[index].bindingEquals(other.candidates[index])) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() => 'PushCryptoBatchEffect(<redacted>)';
}

final class PushEnvelopeRoutePlan {
  const PushEnvelopeRoutePlan._({required this.effect});

  final PushCryptoBatchEffect? effect;

  @override
  String toString() => 'PushEnvelopeRoutePlan(<redacted>)';
}

final class PushCryptoCandidateCompletion {
  const PushCryptoCandidateCompletion.signatureMismatch({
    required this.candidate,
  }) : status = PushCryptoCandidateStatus.signatureMismatch,
       padding = null,
       plaintextUtf8 = null;

  const PushCryptoCandidateCompletion.decryptFailed({required this.candidate})
    : status = PushCryptoCandidateStatus.decryptFailed,
      padding = null,
      plaintextUtf8 = null;

  PushCryptoCandidateCompletion.valid({
    required this.candidate,
    required PushRsaPadding this.padding,
    required String plaintextUtf8,
  }) : status = PushCryptoCandidateStatus.valid,
       plaintextUtf8 = plaintextUtf8 {
    final encoded = utf8.encode(plaintextUtf8);
    if (encoded.length > PushWireLimits.maximumPlaintextBytes ||
        utf8.decode(encoded, allowMalformed: false) != plaintextUtf8) {
      _cryptoResultFailure(r'$.cryptoResult.plaintext');
    }
  }

  final PushCryptoCandidate candidate;
  final PushCryptoCandidateStatus status;
  final PushRsaPadding? padding;
  final String? plaintextUtf8;

  @override
  String toString() =>
      'PushCryptoCandidateCompletion(${status.name}, <redacted>)';
}

final class PushCryptoBatchCompletion {
  PushCryptoBatchCompletion({
    required this.effect,
    required List<PushCryptoCandidateCompletion> candidates,
  }) : candidates = UnmodifiableListView<PushCryptoCandidateCompletion>(
         List<PushCryptoCandidateCompletion>.of(candidates),
       );

  final PushCryptoBatchEffect effect;
  final List<PushCryptoCandidateCompletion> candidates;

  @override
  String toString() => 'PushCryptoBatchCompletion(<redacted>)';
}

final class PushRoutedWakeUp {
  const PushRoutedWakeUp({required this.accountId, required this.payload});

  final AccountId accountId;
  final PushWakeUpPayload payload;

  @override
  String toString() => 'PushRoutedWakeUp(<redacted>)';
}

final class PushRouteResult {
  const PushRouteResult._({required this.outcome, required this.routed});

  final PushRouteOutcome outcome;
  final PushRoutedWakeUp? routed;

  @override
  String toString() => 'PushRouteResult(outcome: ${outcome.name}, <redacted>)';
}

PushEnvelopeRoutePlan planPushEnvelopeRoute(
  PushRuntimeSnapshot snapshot, {
  required PushEnvelope envelope,
  required PushEffectId effectId,
}) {
  final providerGeneration = snapshot.providerToken?.generation;
  if (providerGeneration == null) {
    return const PushEnvelopeRoutePlan._(effect: null);
  }
  final candidates = <PushCryptoCandidate>[];
  final entries = snapshot.accounts.entries.toList()
    ..sort((left, right) => left.key.value.compareTo(right.key.value));
  for (final entry in entries) {
    final account = entry.value;
    final key = account.key;
    final registration = account.registration;
    if (account.phase != PushAccountPhase.registered ||
        account.registeredProviderGeneration != providerGeneration ||
        key == null ||
        registration == null ||
        account.registrationRevision < 1) {
      continue;
    }
    candidates.add(
      PushCryptoCandidate(
        accountId: entry.key,
        keyHandle: key.handle,
        keyGeneration: key.generation,
        userPublicKey: registration.userPublicKey,
        registrationRevision: account.registrationRevision,
        providerTokenGeneration: providerGeneration,
      ),
    );
  }
  return PushEnvelopeRoutePlan._(
    effect: candidates.isEmpty
        ? null
        : PushCryptoBatchEffect(
            effectId: effectId,
            envelope: envelope,
            candidates: candidates,
          ),
  );
}

PushRouteResult completePushEnvelopeRoute(
  PushRuntimeSnapshot current,
  PushEnvelopeRoutePlan plan,
  PushCryptoBatchCompletion completion,
) {
  final effect = plan.effect;
  if (effect == null || !effect.bindingEquals(completion.effect)) {
    _cryptoResultFailure(r'$.cryptoResult.effect');
  }
  final currentEffect = planPushEnvelopeRoute(
    current,
    envelope: effect.envelope,
    effectId: effect.effectId,
  ).effect;
  if (currentEffect == null || !effect.bindingEquals(currentEffect)) {
    return const PushRouteResult._(
      outcome: PushRouteOutcome.unmatched,
      routed: null,
    );
  }
  if (completion.candidates.length != effect.candidates.length) {
    _cryptoResultFailure(r'$.cryptoResult.candidates');
  }
  final byAccount = <AccountId, PushCryptoCandidateCompletion>{};
  for (final completionCandidate in completion.candidates) {
    final accountId = completionCandidate.candidate.accountId;
    if (byAccount.containsKey(accountId)) {
      _cryptoResultFailure(r'$.cryptoResult.candidates');
    }
    byAccount[accountId] = completionCandidate;
  }

  final routed = <PushRoutedWakeUp>[];
  for (final expected in effect.candidates) {
    final result = byAccount[expected.accountId];
    if (result == null || !expected.bindingEquals(result.candidate)) {
      _cryptoResultFailure(r'$.cryptoResult.candidates');
    }
    if (result.status != PushCryptoCandidateStatus.valid) {
      continue;
    }
    final padding = result.padding;
    final plaintext = result.plaintextUtf8;
    if (padding == null || plaintext == null) {
      _cryptoResultFailure(r'$.cryptoResult.candidates');
    }
    try {
      routed.add(
        PushRoutedWakeUp(
          accountId: expected.accountId,
          payload: decodePushWakeUpPayload(plaintext),
        ),
      );
    } on TalkProtocolException {
      continue;
    }
  }
  if (routed.length == 1) {
    return PushRouteResult._(
      outcome: PushRouteOutcome.routed,
      routed: routed.single,
    );
  }
  return PushRouteResult._(
    outcome: routed.isEmpty
        ? PushRouteOutcome.unmatched
        : PushRouteOutcome.ambiguous,
    routed: null,
  );
}

bool _constantBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

Never _cryptoResultFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidPushCryptoResult, path);
