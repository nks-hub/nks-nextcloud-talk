import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/network/account_http_client.dart';
import 'package:talk_protocol/talk_protocol.dart';

final class _FakeCertificate implements X509Certificate {
  _FakeCertificate({required this.subject, required List<int> der})
    : der = Uint8List.fromList(der);

  @override
  final String subject;

  @override
  final Uint8List der;

  @override
  DateTime get endValidity => DateTime.utc(2030);

  @override
  DateTime get startValidity => DateTime.utc(2020);

  @override
  String get issuer => subject;

  @override
  String get pem => '';

  @override
  Uint8List get sha1 => Uint8List(0);
}

void main() {
  group('certificateFingerprint', () {
    test('is the lowercase SHA-256 of the DER bytes', () {
      // Known digest of the empty input, so the algorithm is pinned by a
      // value rather than by re-running the same code in the test.
      expect(
        certificateFingerprint(const <int>[]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        certificateFingerprint(const <int>[0x61]),
        'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb',
      );
    });

    test('a different certificate gives a different pin', () {
      expect(
        certificateFingerprint(const <int>[1, 2, 3]),
        isNot(certificateFingerprint(const <int>[1, 2, 4])),
      );
    });
  });

  group('certificateSubjectHost', () {
    test('reads the common name out of a subject', () {
      expect(
        certificateSubjectHost('/C=CZ/O=NKS/CN=cloud.example.invalid'),
        'cloud.example.invalid',
      );
      expect(
        certificateSubjectHost('C=CZ, O=NKS Hub, CN=cloud.example.invalid'),
        'cloud.example.invalid',
      );
      expect(
        certificateSubjectHost('cn=cloud.example.invalid'),
        'cloud.example.invalid',
      );
    });

    test('says nothing rather than guessing when there is no common name', () {
      // The trust decision turns a null host into a refusal, so an unreadable
      // subject can never be silently accepted.
      expect(certificateSubjectHost('/C=CZ/O=NKS'), isNull);
      expect(certificateSubjectHost('CN='), isNull);
      expect(certificateSubjectHost(''), isNull);
    });

    test('does not mistake another field for the common name', () {
      expect(certificateSubjectHost('/OU=CN-team/O=NKS'), isNull);
    });
  });

  group('CertificateTrustGate', () {
    const host = 'cloud.example.invalid';
    final certificate = _FakeCertificate(
      subject: 'CN=$host',
      der: const [1, 2],
    );
    final renewed = _FakeCertificate(subject: 'CN=$host', der: const [3, 4]);

    test('an unknown certificate is refused and reported for confirmation', () {
      final seen = <CertificateEncounter>[];
      final gate = CertificateTrustGate(onEncounter: seen.add);

      expect(gate.accepts(certificate: certificate, host: host), isFalse);
      expect(seen.single.host, host);
      expect(seen.single.fingerprint, certificateFingerprint(certificate.der));
      expect(seen.single.outcome.decision, CertificateTrustDecision.ask);
    });

    test('a confirmed certificate passes and can be handed to an account', () {
      final gate = CertificateTrustGate();
      final fingerprint = certificateFingerprint(certificate.der);

      gate.confirm(host: 'Cloud.Example.Invalid', fingerprint: fingerprint);

      expect(gate.accepts(certificate: certificate, host: host), isTrue);
      expect(gate.confirmedFor(host), fingerprint);
    });

    test('a certificate stored by an account passes without asking again', () {
      final seen = <CertificateEncounter>[];
      final gate = CertificateTrustGate(onEncounter: seen.add)
        ..storedPins = {
          host: {certificateFingerprint(certificate.der)},
        };

      expect(gate.accepts(certificate: certificate, host: host), isTrue);
      expect(seen, isEmpty);
    });

    test('a changed certificate is refused as a mismatch, not re-asked', () {
      final seen = <CertificateEncounter>[];
      final gate = CertificateTrustGate(onEncounter: seen.add)
        ..storedPins = {
          host: {certificateFingerprint(certificate.der)},
        };

      expect(gate.accepts(certificate: renewed, host: host), isFalse);
      expect(
        seen.single.outcome.refusal,
        CertificateRefusal.pinnedFingerprintMismatch,
      );
    });

    test('what one host trusts never covers another host', () {
      final gate = CertificateTrustGate()
        ..storedPins = {
          host: {certificateFingerprint(certificate.der)},
        };

      expect(
        gate.accepts(certificate: certificate, host: 'other.example.invalid'),
        isFalse,
      );
      // Same certificate, same pin, different server: the subject decides.
      expect(gate.accepts(certificate: certificate, host: host), isTrue);
    });
  });
}
