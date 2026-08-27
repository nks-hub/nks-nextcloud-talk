import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/telemetry.dart';

void main() {
  group('TelemetryConfig', () {
    test('a build without configuration reports nothing', () {
      // The default for anyone building this client for their own Nextcloud.
      const config = TelemetryConfig(
        sentryDsn: '',
        rybbitHost: '',
        rybbitSiteId: '',
        environment: 'development',
      );
      expect(config.crashReportingEnabled, isFalse);
      expect(config.analyticsEnabled, isFalse);
    });

    test('a malformed DSN disables crash reporting instead of guessing', () {
      for (final dsn in const ['not-a-url', 'https://', '://nowhere', ' ']) {
        final config = TelemetryConfig(
          sentryDsn: dsn,
          rybbitHost: '',
          rybbitSiteId: '',
          environment: 'production',
        );
        expect(
          config.crashReportingEnabled,
          isFalse,
          reason: 'DSN "$dsn" must not switch reporting on',
        );
      }
    });

    test('analytics needs both the host and the site', () {
      const host = 'https://rybbit.example.invalid';
      expect(
        const TelemetryConfig(
          sentryDsn: '',
          rybbitHost: host,
          rybbitSiteId: '',
          environment: 'production',
        ).analyticsEnabled,
        isFalse,
      );
      expect(
        const TelemetryConfig(
          sentryDsn: '',
          rybbitHost: '',
          rybbitSiteId: '7',
          environment: 'production',
        ).analyticsEnabled,
        isFalse,
      );
      expect(
        const TelemetryConfig(
          sentryDsn: '',
          rybbitHost: host,
          rybbitSiteId: '7',
          environment: 'production',
        ).analyticsEnabled,
        isTrue,
      );
    });

    test('a configured build reports', () {
      const config = TelemetryConfig(
        sentryDsn: 'https://key@sentry.example.invalid/1',
        rybbitHost: 'https://rybbit.example.invalid',
        rybbitSiteId: '7',
        environment: 'production',
      );
      expect(config.crashReportingEnabled, isTrue);
      expect(config.analyticsEnabled, isTrue);
    });
  });

  group('TelemetryScrubber', () {
    const scrubber = TelemetryScrubber();

    test('a Talk URL loses both the server and the room token', () {
      const message =
          'failed GET https://cloud.example.invalid/index.php/call/abc123xyz';
      final scrubbed = scrubber.scrub(message);
      expect(scrubbed, isNot(contains('cloud.example.invalid')));
      expect(scrubbed, isNot(contains('abc123xyz')));
      expect(scrubbed, contains('https://<host>'));
    });

    test('an OCS path never leaves the device', () {
      final scrubbed = scrubber.scrub(
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room',
      );
      expect(scrubbed, isNot(contains('spreed')));
      expect(scrubbed, isNot(contains('ocs')));
    });

    test('credentials are removed', () {
      for (final secret in const [
        'Authorization: Basic c2VjcmV0OnZhbHVl',
        'bearer abcdef123456',
      ]) {
        expect(scrubber.scrub(secret), contains('<redacted>'));
        expect(scrubber.scrub(secret), isNot(contains('abcdef123456')));
        expect(scrubber.scrub(secret), isNot(contains('c2VjcmV0OnZhbHVl')));
      }
    });

    test('ordinary text is left alone', () {
      const plain = 'RangeError: index 5 out of range';
      expect(scrubber.scrub(plain), plain);
      expect(scrubber.scrub(''), isEmpty);
    });
  });

  group('InstallationId', () {
    test('is random, opaque and not derived from anything', () {
      final first = InstallationId.generate(Random(1));
      final second = InstallationId.generate(Random(2));
      expect(first.isValid, isTrue);
      expect(second.isValid, isTrue);
      expect(first.value, isNot(second.value));
    });

    test('rejects a stored value that is not one of ours', () {
      const notHex = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
      for (final value in const ['', 'abc', notHex]) {
        expect(InstallationId(value).isValid, isFalse);
      }
    });
  });
}
