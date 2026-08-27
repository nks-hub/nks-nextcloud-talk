import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// Build-time telemetry configuration.
///
/// Values arrive through `--dart-define`, never from a file the app reads at
/// runtime and never from the repository: a self-hosted Sentry DSN and Rybbit
/// host are internal addresses, and this repository is public.
///
/// Absent values mean the corresponding SDK is never initialised at all. That
/// is the default for anyone building this client against their own Nextcloud,
/// which matters because this is a general multi-server client rather than a
/// white-label app — a third-party build must not report to our servers.
final class TelemetryConfig {
  const TelemetryConfig({
    required this.sentryDsn,
    required this.rybbitHost,
    required this.rybbitSiteId,
    required this.environment,
  });

  factory TelemetryConfig.fromEnvironment() {
    return const TelemetryConfig(
      sentryDsn: String.fromEnvironment('SENTRY_DSN'),
      rybbitHost: String.fromEnvironment('RYBBIT_HOST'),
      rybbitSiteId: String.fromEnvironment('RYBBIT_SITE_ID'),
      environment: String.fromEnvironment(
        'TELEMETRY_ENVIRONMENT',
        defaultValue: 'development',
      ),
    );
  }

  final String sentryDsn;
  final String rybbitHost;
  final String rybbitSiteId;
  final String environment;

  /// Crash reporting runs only with a DSN that is actually a URL. A malformed
  /// value disables it rather than letting the SDK decide what to do with it.
  bool get crashReportingEnabled {
    final uri = Uri.tryParse(sentryDsn);
    return uri != null && uri.hasScheme && uri.host.isNotEmpty;
  }

  /// Analytics needs both halves; one without the other is a misconfigured
  /// build, not a partially working one.
  bool get analyticsEnabled {
    final uri = Uri.tryParse(rybbitHost);
    return uri != null &&
        uri.hasScheme &&
        uri.host.isNotEmpty &&
        rybbitSiteId.isNotEmpty;
  }
}

/// Strips anything that identifies a person, a conversation or a server from
/// text on its way out of the device.
///
/// The app's own logs are already free of message bodies, tokens and
/// endpoints, verified against a live device. Telemetry sends data off the
/// device, so it must not undo that: a stack trace or a breadcrumb can quote a
/// URL, and a Talk URL carries both the user's server and a room token.
final class TelemetryScrubber {
  const TelemetryScrubber();

  static final _url = RegExp(r'https?://[^\s"' r"'" r']+', caseSensitive: false);
  // Two shapes, because one pattern got this wrong: an `Authorization:` header
  // must lose the WHOLE rest of its line, otherwise `Authorization: Basic
  // <token>` only loses the word "Basic" and ships the credential.
  static final _credential = RegExp(
    r'(authorization|proxy-authorization)\s*[:=]\s*.+'
    r'|(bearer|basic)\s+[A-Za-z0-9+/=._~-]+',
    caseSensitive: false,
  );

  /// Replaces every absolute URL with its scheme and a placeholder host, and
  /// removes anything that looks like a credential.
  ///
  /// Paths go too: `…/call/<token>` and `…/ocs/v2.php/apps/spreed/…` name a
  /// room and a server layout, neither of which helps diagnose a crash.
  String scrub(String value) {
    if (value.isEmpty) {
      return value;
    }
    return value
        .replaceAll(_credential, '<redacted>')
        .replaceAllMapped(_url, (match) {
          final uri = Uri.tryParse(match[0]!);
          return uri == null ? '<url>' : '${uri.scheme}://<host>';
        });
  }
}

/// A random identifier for this installation.
///
/// Counts installs without naming anyone: it is generated locally and is not
/// derived from any account, server or device property, so it can never be
/// joined to a person or to which Nextcloud they use. It lives as long as the
/// app's data does and does not survive a reinstall.
final class InstallationId {
  const InstallationId(this.value);

  static const storageKey = 'telemetry_installation_id.txt';

  factory InstallationId.generate([Random? random]) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => source.nextInt(256));
    return InstallationId(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
  }

  final String value;

  bool get isValid =>
      value.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
}


/// Reads this installation's id, creating it on first run.
///
/// A plain file next to the other local preferences: the id is deliberately
/// not a secret, and putting it in the keychain would tie it to a vault whose
/// whole point is per-account credentials.
final class InstallationIdStore {
  const InstallationIdStore({this._directory});

  final Directory? _directory;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/${InstallationId.storageKey}');
  }

  /// Returns null when the id can neither be read nor written, so telemetry
  /// stays anonymous rather than falling back to anything device-derived.
  Future<InstallationId?> read() async {
    try {
      final file = await _file();
      if (file.existsSync()) {
        final stored = InstallationId((await file.readAsString()).trim());
        if (stored.isValid) {
          return stored;
        }
      }
      final generated = InstallationId.generate();
      await file.parent.create(recursive: true);
      await file.writeAsString(generated.value);
      return generated;
    } on Object {
      return null;
    }
  }
}
