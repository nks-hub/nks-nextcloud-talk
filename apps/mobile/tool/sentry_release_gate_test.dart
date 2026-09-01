import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_version.dart';
import 'package:nextcloudtalk/core/telemetry.dart';
import 'package:nextcloudtalk/core/telemetry_bootstrap.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('release configuration sends error and diagnostic events', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _ReleaseGateHttpOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final config = TelemetryConfig.fromEnvironment();
    expect(config.crashReportingEnabled, isTrue);
    expect(config.environment, 'production');
    expect(config.releaseGateEnabled, isTrue);

    await SentryFlutter.init((options) {
      options
        ..dsn = config.sentryDsn
        ..environment = config.environment
        ..release = 'com.nkshub.nextcloudtalk@$appVersionName+$appBuildNumber'
        ..sendDefaultPii = false
        ..attachScreenshot = false
        ..tracesSampleRate = 0
        ..beforeBreadcrumb = scrubSentryBreadcrumb
        ..beforeSend = (event, hint) => scrubSentryEvent(event);
    });
    expect(Sentry.isEnabled, isTrue);

    final eventIds = await captureTelemetryReleaseGate();
    // Event IDs are the release gate output consumed by the ASC/Sentry script.
    // ignore: avoid_print
    print('SENTRY_ERROR_EVENT_ID=${eventIds.first}');
    // ignore: avoid_print
    print('SENTRY_DIAGNOSTIC_EVENT_ID=${eventIds.last}');
    expect(eventIds, everyElement(isNot(SentryId.empty())));
    await Sentry.close();
  });
}

final class _ReleaseGateHttpOverrides extends HttpOverrides {
  @override
  // TestWidgets installs a 400-only client; super restores dart:io networking.
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}
