import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final pinned = 'a' * 64;
  final other = 'b' * 64;

  CertificateTrustOutcome decide({
    String requestedHost = 'cloud.example.invalid',
    String certificateHost = 'cloud.example.invalid',
    String? presented,
    String? stored,
  }) => decideCertificateTrust(
    requestedHost: requestedHost,
    certificateHost: certificateHost,
    presentedFingerprint: presented ?? pinned,
    pinnedFingerprint: stored,
  );

  test('an exact pin for this account is the only thing that passes', () {
    expect(decide(stored: pinned), const CertificateTrustOutcome.allow());
  });

  test('nothing pinned yet means the user decides, not the app', () {
    expect(decide(), const CertificateTrustOutcome.ask());
  });

  test('a changed certificate is refused, never re-asked', () {
    // A renewal and an attack look identical from here, so the pin has to be
    // removed deliberately rather than silently replaced.
    expect(
      decide(presented: other, stored: pinned),
      const CertificateTrustOutcome.refuse(
        CertificateRefusal.pinnedFingerprintMismatch,
      ),
    );
  });

  test('a pin cannot wave through a certificate for another host', () {
    expect(
      decide(
        requestedHost: 'cloud.example.invalid',
        certificateHost: 'attacker.example.invalid',
        stored: pinned,
      ),
      const CertificateTrustOutcome.refuse(CertificateRefusal.hostMismatch),
    );
    expect(
      decide(requestedHost: '', certificateHost: '', stored: pinned),
      const CertificateTrustOutcome.refuse(CertificateRefusal.hostMismatch),
    );
  });

  test('host comparison ignores case but nothing else', () {
    expect(
      decide(
        requestedHost: 'Cloud.Example.Invalid',
        certificateHost: 'cloud.example.invalid',
        stored: pinned,
      ),
      const CertificateTrustOutcome.allow(),
    );
    expect(
      decide(
        requestedHost: 'cloud.example.invalid',
        certificateHost: 'sub.cloud.example.invalid',
        stored: pinned,
      ),
      const CertificateTrustOutcome.refuse(CertificateRefusal.hostMismatch),
    );
  });

  test('a fingerprint that is not a SHA-256 digest is refused', () {
    expect(
      decide(presented: 'not-a-digest', stored: pinned),
      const CertificateTrustOutcome.refuse(
        CertificateRefusal.malformedFingerprint,
      ),
    );
    expect(
      decide(stored: 'A' * 64),
      const CertificateTrustOutcome.refuse(
        CertificateRefusal.malformedFingerprint,
      ),
    );
  });
}
