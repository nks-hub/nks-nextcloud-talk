import 'package:flutter/widgets.dart';
import 'package:rybbit_flutter_sdk/rybbit_flutter_sdk.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app_version.dart';
import 'attachment_upload_telemetry.dart';
import 'performance_span_telemetry.dart';
import 'performance_telemetry.dart';
import 'runtime_health_telemetry.dart';
import 'telemetry.dart';

/// Starts the app, with crash reporting and analytics attached only when the
/// build carries the corresponding configuration.
///
/// A build without a DSN or a Rybbit host never touches either SDK, so a
/// third-party build of this client reports nowhere. Neither SDK is allowed to
/// fail the launch: telemetry is diagnostics, not a feature the user asked for.
Future<void> runWithTelemetry({
  required TelemetryConfig config,
  required Widget Function(List<NavigatorObserver> observers) appBuilder,
  InstallationIdStore installationIds = const InstallationIdStore(),
}) async {
  final launchStarted = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();

  if (!config.crashReportingEnabled && !config.analyticsEnabled) {
    runApp(appBuilder(const []));
    return;
  }

  final installation = await installationIds.read();
  final observers = <NavigatorObserver>[];

  if (config.analyticsEnabled) {
    try {
      await Rybbit.init(
        host: config.rybbitHost,
        siteId: config.rybbitSiteId,
        anonymousId: installation?.value,
        // Errors belong to Sentry, which scrubs them first. Rybbit's own
        // handler would ship the raw message and claim FlutterError.onError
        // from under the Sentry integration.
        autoTrackErrors: false,
        globalProperties: {'environment': config.environment},
      );
      observers.add(RybbitNavigatorObserver());
    } on Object {
      // Analytics is never worth a failed launch.
    }
  }

  if (!config.crashReportingEnabled) {
    runApp(appBuilder(observers));
    return;
  }

  observers.add(SentryNavigatorObserver());
  // Installed before the app runs, so the very first sync and the first room
  // opened are measured instead of falling into the no-op sink.
  installPerformanceTelemetry(reportPerformanceSpanToSentry);
  await SentryFlutter.init((options) {
    configureSentryOptions(options, config: config);
  }, appRunner: () => runApp(appBuilder(observers)));
  // Measured to the first frame the app schedules, which is what a user calls
  // "the app started" — not to the end of this function.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    performanceTelemetry.record(
      operation: TracedOperation.appStart,
      started: launchStarted,
      outcome: TracedOutcome.completed,
    );
  });

  if (installation != null) {
    await Sentry.configureScope(
      (scope) => scope.setUser(SentryUser(id: installation.value)),
    );
  }
  final runtimeHealth = RuntimeHealthTelemetry(
    runKind: config.releaseGateEnabled
        ? RuntimeHealthRunKind.releaseGate
        : RuntimeHealthRunKind.ordinary,
    reportTags: _reportRuntimeHealthTags,
  );
  await runtimeHealth.start();
  if (config.releaseGateEnabled) {
    await captureTelemetryReleaseGate(runtimeTags: runtimeHealth.tags);
  }
}

void configureSentryOptions(
  SentryFlutterOptions options, {
  required TelemetryConfig config,
}) {
  options
    ..dsn = config.sentryDsn
    ..environment = config.environment
    ..release = 'com.nkshub.nextcloudtalk@$appVersionName+$appBuildNumber'
    // A 2 s hang is reported separately instead of becoming a watchdog guess.
    ..enableWatchdogTerminationTracking = true
    ..enableAppHangTracking = true
    ..appHangTimeoutInterval = const Duration(seconds: 2)
    ..enableAutoNativeBreadcrumbs = true
    ..enableMemoryPressureBreadcrumbs = false
    ..enableScopeSync = true
    // Everything below keeps content on the device. The user consented to
    // crashes without content, so anything that could carry a message body,
    // a room token or a server address is either off or scrubbed.
    ..sendDefaultPii = false
    ..attachScreenshot = false
    // Stays off deliberately, and turning it on is not how this app reports
    // performance. Sentry's own tracing auto-instruments HTTP and navigation,
    // and those spans are DESCRIBED by the URL they hit and the route they
    // opened — server address and room token, the two things this telemetry
    // exists to keep on the device. Measurements go out through
    // `performance_span_telemetry.dart` instead, as events built from a closed
    // set of names, outcomes and duration buckets.
    ..tracesSampleRate = 0
    ..beforeBreadcrumb = scrubSentryBreadcrumb
    ..beforeSend = (event, hint) => scrubSentryEvent(event);
}

Future<void> _reportRuntimeHealthTags(Map<String, String> tags) async {
  await Sentry.configureScope((scope) async {
    for (final entry in tags.entries) {
      await scope.setTag(entry.key, entry.value);
    }
  });
}

final class TelemetryReleaseGateError implements Exception {
  const TelemetryReleaseGateError();

  @override
  String toString() => 'TelemetryReleaseGateError';
}

Future<List<SentryId>> captureTelemetryReleaseGate({
  Map<String, String>? runtimeTags,
}) async {
  final gateTags =
      runtimeTags ?? currentRuntimeHealthTags(RuntimeHealthRunKind.releaseGate);
  final errorId = await Sentry.captureException(
    const TelemetryReleaseGateError(),
    stackTrace: StackTrace.current,
    withScope: (scope) async {
      await configureTelemetryReleaseGateScope(
        scope,
        gateKind: 'error',
        runtimeTags: gateTags,
      );
    },
  );
  final diagnosticId = await Sentry.captureEvent(
    buildAttachmentUploadSentryEvent(
      const AttachmentUploadDiagnostic(
        checkpoint: AttachmentUploadCheckpoint.releaseGate,
        durablePhase: AttachmentUploadDurablePhase.localPrepared,
        failure: AttachmentUploadFailure.none,
        sessionBound: true,
      ),
    ),
    withScope: (scope) async {
      await configureTelemetryReleaseGateScope(
        scope,
        gateKind: 'diagnostic',
        runtimeTags: gateTags,
      );
    },
  );
  return <SentryId>[errorId, diagnosticId];
}

Future<void> configureTelemetryReleaseGateScope(
  Scope scope, {
  required String gateKind,
  required Map<String, String> runtimeTags,
}) async {
  if (gateKind != 'error' && gateKind != 'diagnostic') {
    throw ArgumentError.value(gateKind, 'gateKind');
  }
  const lifecycleValues = <String>{'foreground', 'background', 'detached'};
  const rssValues = <String>{
    'unknown',
    '<128m',
    '128-256m',
    '256-384m',
    '384-512m',
    '512-768m',
    '768m+',
  };
  final lifecycle = runtimeTags['runtime.lifecycle'];
  final rssBucket = runtimeTags['runtime.rss_bucket'];
  final pressure = runtimeTags['runtime.memory_pressure_seen'];
  final safeTags = <String, String>{
    'runtime.run_kind': 'release_gate',
    'runtime.lifecycle': lifecycleValues.contains(lifecycle)
        ? lifecycle!
        : 'background',
    'runtime.rss_bucket': rssValues.contains(rssBucket)
        ? rssBucket!
        : 'unknown',
    'runtime.memory_pressure_seen': pressure == 'true' ? 'true' : 'false',
  };

  await scope.clear();
  for (final entry in safeTags.entries) {
    await scope.setTag(entry.key, entry.value);
  }
  await scope.setTag('telemetry.release_gate', gateKind);
}

const _scrubber = TelemetryScrubber();

/// Loggers whose events must reach Sentry carrying nothing but their own tags.
///
/// Stripping here rather than at the call site is the only thing that works.
/// Both of these build their event with empty breadcrumbs and capture it with
/// a cleared scope, and the SDK repopulates them anyway: native and lifecycle
/// breadcrumbs are merged after the scope is applied. Measured on the live
/// server, not assumed — build 43's `performance-conversation.sync` arrived
/// with three breadcrumbs (app lifecycle, battery, navigation) despite the
/// cleared scope, which is exactly the mistake the attachment logger had
/// already been fixed for.
const _contentFreeLoggers = <String>{'attachment.upload', 'performance'};

/// Removes URLs and credentials from everything an event carries as text.
///
/// [SentryEvent.request] goes entirely: a Talk request URL names the server
/// and the room, and the failing call is already identifiable from the stack.
SentryEvent scrubSentryEvent(SentryEvent event) {
  event.request = null;
  if (_contentFreeLoggers.contains(event.logger)) {
    event
      ..user = null
      ..breadcrumbs = const <Breadcrumb>[];
  }
  final message = event.message;
  if (message != null) {
    event.message = SentryMessage(_scrubber.scrub(message.formatted));
  }
  for (final exception in event.exceptions ?? const <SentryException>[]) {
    final value = exception.value;
    if (value != null) {
      exception.value = _scrubber.scrub(value);
    }
  }
  return event;
}

Breadcrumb? scrubSentryBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) {
    return null;
  }
  final message = breadcrumb.message;
  if (message != null) {
    breadcrumb.message = _scrubber.scrub(message);
  }
  final data = breadcrumb.data;
  if (data != null) {
    for (final entry in data.entries.toList()) {
      final value = entry.value;
      if (value is String) {
        data[entry.key] = _scrubber.scrub(value);
      }
    }
  }
  return breadcrumb;
}
