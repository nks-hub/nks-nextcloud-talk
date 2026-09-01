import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/network/account_http_client.dart';

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
}
