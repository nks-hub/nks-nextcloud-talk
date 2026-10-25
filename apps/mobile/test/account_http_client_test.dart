import 'dart:io';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/network/account_http_client.dart';
import 'package:nextcloudtalk/network/certificate_host.dart';
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

Uint8List _certificateDer({
  List<String> dnsNames = const ['cloud.example.invalid'],
  List<String> ipAddresses = const [],
  int serial = 1,
  bool includeSan = true,
}) {
  final names = ASN1Sequence();
  for (final name in dnsNames) {
    names.add(ASN1OctetString(name, tag: 0x82));
  }
  for (final address in ipAddresses) {
    names.add(ASN1OctetString(InternetAddress(address).rawAddress, tag: 0x87));
  }
  final extension = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('2.5.29.17'))
    ..add(ASN1OctetString(names.encodedBytes));
  final extensions = ASN1Sequence()..add(extension);
  final tbs = ASN1Sequence()..add(ASN1Integer(BigInt.from(serial)));
  if (includeSan) {
    tbs.add(ASN1Sequence(tag: 0xa3)..add(extensions));
  }
  // The gate parses SAN fields; HttpClient owns signature verification.
  return (ASN1Sequence()..add(tbs)).encodedBytes;
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

  group('certificateMatchesHost', () {
    test('matches any DNS SAN without treating an IP literal as DNS', () {
      final der = _certificateDer(
        dnsNames: ['other.example.invalid', 'Cloud.Example.Invalid', '127.0.0.1'],
      );
      expect(certificateMatchesHost(der, 'cloud.example.invalid'), isTrue);
      expect(certificateMatchesHost(der, 'unknown.example.invalid'), isFalse);
      expect(certificateMatchesHost(der, '127.0.0.1'), isFalse);
    });

    test('matches binary IPv4 and IPv6 SANs', () {
      final der = _certificateDer(
        dnsNames: [],
        ipAddresses: ['127.0.0.1', '2001:db8::1'],
      );
      expect(certificateMatchesHost(der, '127.0.0.1'), isTrue);
      expect(certificateMatchesHost(der, '2001:db8:0:0:0:0:0:1'), isTrue);
      expect(certificateMatchesHost(der, '127.0.0.2'), isFalse);
    });

    test('a wildcard covers exactly one leftmost DNS label', () {
      final der = _certificateDer(dnsNames: ['*.example.invalid']);
      expect(certificateMatchesHost(der, 'cloud.example.invalid'), isTrue);
      expect(certificateMatchesHost(der, 'example.invalid'), isFalse);
      expect(certificateMatchesHost(der, 'a.cloud.example.invalid'), isFalse);
      expect(
        certificateMatchesHost(
          _certificateDer(dnsNames: ['*.invalid']),
          'cloud.invalid',
        ),
        isFalse,
      );
    });
  });

  group('CertificateTrustGate', () {
    const host = 'cloud.example.invalid';
    final certificate = _FakeCertificate(
      subject: 'CN=$host',
      der: _certificateDer(),
    );
    final renewed = _FakeCertificate(
      subject: 'CN=$host',
      der: _certificateDer(serial: 2),
    );

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
      // A pin cannot override the certificate's SAN host restriction.
      expect(gate.accepts(certificate: certificate, host: host), isTrue);
    });

    test('a matching SAN passes even when the CN names another host', () {
      final certificate = _FakeCertificate(
        subject: 'CN=other.example.invalid',
        der: _certificateDer(),
      );
      final gate = CertificateTrustGate()
        ..confirm(
          host: host,
          fingerprint: certificateFingerprint(certificate.der),
        );

      expect(gate.accepts(certificate: certificate, host: host), isTrue);
    });

    for (final entry in {
      'mismatched SAN': _certificateDer(dnsNames: ['other.example.invalid']),
      'missing SAN': _certificateDer(includeSan: false),
      'malformed DER': <int>[1, 2],
    }.entries) {
      test('a matching CN and pin cannot bypass ${entry.key}', () {
        final certificate = _FakeCertificate(
          subject: 'CN=$host',
          der: entry.value,
        );
        final gate = CertificateTrustGate()
          ..confirm(
            host: host,
            fingerprint: certificateFingerprint(certificate.der),
          );

        expect(gate.accepts(certificate: certificate, host: host), isFalse);
        expect(
          gate.lastEncounter?.outcome.refusal,
          CertificateRefusal.hostMismatch,
        );
      });
    }
  });
}
