import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// A certificate the platform refused that the user has not answered for yet.
final class CertificateEncounter {
  const CertificateEncounter({
    required this.host,
    required this.fingerprint,
    required this.outcome,
  });

  final String host;
  final String fingerprint;
  final CertificateTrustOutcome outcome;

  @override
  bool operator ==(Object other) =>
      other is CertificateEncounter &&
      other.host == host &&
      other.fingerprint == fingerprint &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(host, fingerprint, outcome);
}

/// Builds every HTTP client the app uses and gates the ones the platform
/// rejects on what the user has explicitly trusted.
///
/// It exists because certificate trust cannot be bolted onto call sites: the
/// app created `http.Client()` in eight independent places, so a rule added to
/// one of them would leave the rest verifying differently. Everything that
/// leaves the app has to come from here.
final class CertificateTrustGate {
  CertificateTrustGate({this.loadStoredPins, this.onEncounter}) {
    unawaited(refresh());
  }

  /// Reads what the accounts trust. Pulled rather than watched: a live
  /// database stream held for the life of the app leaves a pending close
  /// timer whenever the tree is torn down, and pins only ever change when an
  /// account is added or removed.
  final Future<Map<String, Set<String>>> Function()? loadStoredPins;

  /// Told about every rejected certificate, so the user can be shown the
  /// fingerprint. Called during a handshake, so it must not block.
  final void Function(CertificateEncounter encounter)? onEncounter;

  Map<String, Set<String>> _stored = const {};
  final Map<String, String> _confirmed = {};

  /// The most recent certificate that did not pass, so a request that failed
  /// with a bare handshake error can still be explained to the user.
  CertificateEncounter? lastEncounter;

  /// Rereads the stored pins. Cheap enough to run whenever a client is made,
  /// which is what keeps a removed account's trust from outliving it.
  Future<void> refresh() async {
    final load = loadStoredPins;
    if (load == null) {
      return;
    }
    try {
      storedPins = await load();
    } on Object {
      // Nothing stored means nothing extra is trusted, which is the safe
      // answer; the user is asked again instead of a request being let
      // through on a stale snapshot.
    }
  }

  /// Replaces what the accounts have trusted so far. Fingerprints the user
  /// confirmed in this session survive, because the account that will own them
  /// may not exist yet.
  set storedPins(Map<String, Set<String>> pins) {
    _stored = {
      for (final entry in pins.entries)
        entry.key.toLowerCase(): Set.unmodifiable(entry.value),
    };
  }

  /// Records that the user accepted [fingerprint] for [host]. It only lasts
  /// for this session until an account on that host persists it; abandoning
  /// the login therefore leaves nothing trusted behind.
  void confirm({required String host, required String fingerprint}) {
    _confirmed[host.toLowerCase()] = fingerprint;
  }

  /// The fingerprint the user confirmed for [host] but no account owns yet.
  String? confirmedFor(String host) => _confirmed[host.toLowerCase()];

  http.Client createClient() {
    unawaited(refresh());
    final client = HttpClient()
      ..badCertificateCallback = (certificate, host, port) =>
          accepts(certificate: certificate, host: host);
    return IOClient(client);
  }

  /// Visible for testing: the whole handshake decision minus the socket.
  bool accepts({required X509Certificate certificate, required String host}) {
    final fingerprint = certificateFingerprint(certificate.der);
    final key = host.toLowerCase();
    final outcome = decideCertificateTrust(
      requestedHost: host,
      certificateHost: certificateSubjectHost(certificate.subject) ?? '',
      presentedFingerprint: fingerprint,
      pinnedFingerprints: {...?_stored[key], ?_confirmed[key]},
    );
    if (outcome.decision == CertificateTrustDecision.allow) {
      return true;
    }
    // Asking is not accepting: the request fails now and succeeds once the
    // user has answered. A refusal is reported too, because a changed
    // fingerprint is the one thing the user has to be told about.
    final encounter = CertificateEncounter(
      host: host,
      fingerprint: fingerprint,
      outcome: outcome,
    );
    lastEncounter = encounter;
    onEncounter?.call(encounter);
    return false;
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
