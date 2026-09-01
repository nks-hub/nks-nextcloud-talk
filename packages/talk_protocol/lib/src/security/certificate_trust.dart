/// What the client should do with a TLS certificate the system rejected.
enum CertificateTrustDecision {
  /// The account has pinned exactly this certificate. Continue.
  allow,

  /// Nothing is pinned yet. The user has to see the fingerprint and decide.
  ask,

  /// Refuse without asking. Something is wrong that a prompt cannot fix.
  refuse,
}

/// Why a certificate was refused outright, so the message can say which.
enum CertificateRefusal {
  /// The account already trusts a different certificate for this host.
  ///
  /// A renewed certificate looks the same as an attacker's, so this is never
  /// resolved by asking again: the pin has to be removed deliberately first.
  pinnedFingerprintMismatch,

  /// The certificate belongs to a different host than the one being reached.
  hostMismatch,

  /// The fingerprint is not a SHA-256 hex digest.
  malformedFingerprint,
}

/// Outcome of [decideCertificateTrust].
final class CertificateTrustOutcome {
  const CertificateTrustOutcome.allow()
    : decision = CertificateTrustDecision.allow,
      refusal = null;

  const CertificateTrustOutcome.ask()
    : decision = CertificateTrustDecision.ask,
      refusal = null;

  const CertificateTrustOutcome.refuse(CertificateRefusal reason)
    : decision = CertificateTrustDecision.refuse,
      refusal = reason;

  final CertificateTrustDecision decision;
  final CertificateRefusal? refusal;

  @override
  bool operator ==(Object other) =>
      other is CertificateTrustOutcome &&
      other.decision == decision &&
      other.refusal == refusal;

  @override
  int get hashCode => Object.hash(decision, refusal);

  @override
  String toString() =>
      'CertificateTrustOutcome(${decision.name}'
      '${refusal == null ? '' : ', ${refusal!.name}'})';
}

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// Decides whether a certificate the platform refused may still be used.
///
/// The trust is bound to one account and one host on purpose. Two accounts on
/// the same self-hosted server each answer for themselves, and a pin never
/// leaks to a different host the same account happens to talk to.
///
/// [presentedFingerprint] and [pinnedFingerprints] are lowercase SHA-256 hex
/// digests of the DER encoding. The whole certificate is deliberately not
/// stored: the digest is enough to recognise it and cannot be replayed.
///
/// [pinnedFingerprints] holds every digest already trusted for this host. It
/// is a set because two accounts can live on one self-hosted server; an empty
/// set means nothing is trusted there yet.
CertificateTrustOutcome decideCertificateTrust({
  required String requestedHost,
  required String certificateHost,
  required String presentedFingerprint,
  required Set<String> pinnedFingerprints,
}) {
  if (!_sha256Hex.hasMatch(presentedFingerprint)) {
    return const CertificateTrustOutcome.refuse(
      CertificateRefusal.malformedFingerprint,
    );
  }
  // Checked before the pin, so a stored pin can never be used to wave through
  // a certificate issued for somewhere else.
  if (requestedHost.isEmpty ||
      certificateHost.isEmpty ||
      requestedHost.toLowerCase() != certificateHost.toLowerCase()) {
    return const CertificateTrustOutcome.refuse(
      CertificateRefusal.hostMismatch,
    );
  }
  if (pinnedFingerprints.isEmpty) {
    return const CertificateTrustOutcome.ask();
  }
  if (pinnedFingerprints.any((pin) => !_sha256Hex.hasMatch(pin))) {
    return const CertificateTrustOutcome.refuse(
      CertificateRefusal.malformedFingerprint,
    );
  }
  if (!pinnedFingerprints.contains(presentedFingerprint)) {
    return const CertificateTrustOutcome.refuse(
      CertificateRefusal.pinnedFingerprintMismatch,
    );
  }
  return const CertificateTrustOutcome.allow();
}
