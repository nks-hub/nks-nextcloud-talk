import 'package:sentry_flutter/sentry_flutter.dart';

import 'performance_telemetry.dart';

/// Sends a finished measurement to Sentry as an ordinary event.
///
/// Deliberately NOT Sentry's own tracing. Turning `tracesSampleRate` up would
/// switch on the SDK's automatic instrumentation, whose HTTP and navigation
/// spans are described by the URL they hit and the route they opened — server
/// address and room token, exactly what this app's telemetry is built to keep
/// on the device. An event carrying three closed values costs one request and
/// cannot carry content in the first place.
SentryEvent buildPerformanceSpanSentryEvent(TracedSpan span) => SentryEvent(
  message: SentryMessage('performance-${span.operation.spanName}'),
  logger: 'performance',
  level: SentryLevel.info,
  tags: span.tags,
  // Grouped by operation and outcome, not by duration: a bucket in the
  // fingerprint would split one operation into five issues.
  fingerprint: <String>[
    'performance',
    span.operation.spanName,
    span.outcome.name,
  ],
  breadcrumbs: const <Breadcrumb>[],
  request: null,
  user: null,
);

/// The sink [installPerformanceTelemetry] is given once crash reporting is on.
///
/// The scope is cleared for the same reason the attachment diagnostics clear
/// it: the ambient scope collects breadcrumbs from wherever the app happens to
/// be, and a measurement has no business carrying them.
void reportPerformanceSpanToSentry(TracedSpan span) {
  Sentry.captureEvent(
    buildPerformanceSpanSentryEvent(span),
    withScope: (scope) async {
      await scope.clear();
    },
  ).ignore();
}
