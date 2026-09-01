import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// Pinned certificate of one account, or `null` when it trusts nothing extra.
typedef PinnedCertificateLookup = String? Function(String accountId);

/// Called when a host presents an untrusted certificate nobody pinned yet, so
/// the user can be shown the fingerprint and decide.
typedef CertificateTrustPrompt =
    void Function({
      required String accountId,
      required String host,
      required String fingerprint,
    });

/// Builds every HTTP client the app uses for one account.
///
/// It exists because certificate trust cannot be bolted onto call sites: the
/// app created `http.Client()` in eight independent places, so a pin added to
/// one of them would leave the rest verifying differently. Everything that
/// talks to an account's server has to come from here.
final class AccountHttpClientFactory {
  const AccountHttpClientFactory({
    required this.pinnedFingerprint,
    this.onUntrustedCertificate,
  });

  final PinnedCertificateLookup pinnedFingerprint;
  final CertificateTrustPrompt? onUntrustedCertificate;

  /// A client bound to [accountId]. A pin of one account never applies to
  /// another, even on the same server.
  http.Client forAccount(String accountId) {
    final client = HttpClient()
      ..badCertificateCallback = (certificate, host, port) =>
          _accepts(accountId: accountId, certificate: certificate, host: host);
    return IOClient(client);
  }

  /// A client for requests that belong to no account, such as reaching a
  /// server before it is added. Nothing is ever pinned for these, so an
  /// untrusted certificate simply fails.
  http.Client withoutAccount() => IOClient(HttpClient());

  bool _accepts({
    required String accountId,
    required X509Certificate certificate,
    required String host,
  }) {
    final fingerprint = certificateFingerprint(certificate.der);
    final outcome = decideCertificateTrust(
      requestedHost: host,
      certificateHost: certificateSubjectHost(certificate.subject) ?? '',
      presentedFingerprint: fingerprint,
      pinnedFingerprint: pinnedFingerprint(accountId),
    );
    if (outcome.decision == CertificateTrustDecision.ask) {
      onUntrustedCertificate?.call(
        accountId: accountId,
        host: host,
        fingerprint: fingerprint,
      );
    }
    // Only an exact, already stored pin continues the handshake. Asking is not
    // accepting: the request fails now and succeeds after the user pins it.
    return outcome.decision == CertificateTrustDecision.allow;
  }
}

/// Lowercase SHA-256 of the DER encoding, the form a pin is stored in.
String certificateFingerprint(List<int> der) =>
    sha256.convert(der).toString().toLowerCase();

/// Pulls `CN=` out of an X.509 subject.
///
/// Returns `null` when there is no common name, which the trust decision then
/// treats as a host mismatch rather than guessing.
String? certificateSubjectHost(String subject) {
  for (final part in subject.split(RegExp('[,/]'))) {
    final trimmed = part.trim();
    if (trimmed.length > 3 && trimmed.substring(0, 3).toUpperCase() == 'CN=') {
      final value = trimmed.substring(3).trim();
      return value.isEmpty ? null : value;
    }
  }
  return null;
}
