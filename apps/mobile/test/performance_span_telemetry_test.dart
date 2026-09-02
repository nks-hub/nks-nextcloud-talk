import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/performance_span_telemetry.dart';
import 'package:nextcloudtalk/core/performance_telemetry.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// The transport half of the performance measurement.
///
/// The measuring layer already refuses to carry content; this checks that the
/// thing actually sent to Sentry carries no more than the measurement did, and
/// that it groups the way a reader of the issue list needs.
void main() {
  const span = TracedSpan(
    operation: TracedOperation.attachmentUpload,
    outcome: TracedOutcome.failed,
    duration: Duration(seconds: 3),
  );

  test('the event carries the three closed values and nothing else', () {
    final event = buildPerformanceSpanSentryEvent(span);

    expect(event.message?.formatted, 'performance-attachment.upload');
    expect(event.logger, 'performance');
    expect(event.level, SentryLevel.info);
    expect(event.tags, {
      'operation': 'attachment.upload',
      'outcome': 'failed',
      'duration': '<10s',
    });
    // The fields an SDK would otherwise fill from the ambient scope, and which
    // are exactly where a server address or a room token would ride along.
    expect(event.breadcrumbs, isEmpty);
    expect(event.request, isNull);
    expect(event.user, isNull);
    expect(event.contexts.device, isNull);
  });

  test('one operation is one issue, not one per duration bucket', () {
    final slow = buildPerformanceSpanSentryEvent(span);
    final fast = buildPerformanceSpanSentryEvent(
      const TracedSpan(
        operation: TracedOperation.attachmentUpload,
        outcome: TracedOutcome.failed,
        duration: Duration(milliseconds: 40),
      ),
    );

    expect(slow.fingerprint, fast.fingerprint);
    expect(slow.fingerprint, ['performance', 'attachment.upload', 'failed']);
    expect(slow.tags!['duration'], isNot(fast.tags!['duration']));
  });

  test('a different outcome is a different issue', () {
    final failed = buildPerformanceSpanSentryEvent(span);
    final completed = buildPerformanceSpanSentryEvent(
      const TracedSpan(
        operation: TracedOperation.attachmentUpload,
        outcome: TracedOutcome.completed,
        duration: Duration(seconds: 3),
      ),
    );

    expect(failed.fingerprint, isNot(completed.fingerprint));
  });

  test('every operation the app can measure survives the round trip', () {
    for (final operation in TracedOperation.values) {
      final event = buildPerformanceSpanSentryEvent(
        TracedSpan(
          operation: operation,
          outcome: TracedOutcome.completed,
          duration: const Duration(milliseconds: 10),
        ),
      );
      expect(event.tags!['operation'], operation.spanName);
      expect(
        event.message?.formatted,
        'performance-${operation.spanName}',
        reason: 'the message must name the operation, not interpolate a value',
      );
    }
  });

  test('the ambient measurement reports nowhere until it is installed', () {
    final reported = <TracedSpan>[];

    // No install: this is the state of a build without crash reporting, and
    // it has to be a hole, not a stub that pretends to have sent something.
    performanceTelemetry.record(
      operation: TracedOperation.appStart,
      started: DateTime.now(),
      outcome: TracedOutcome.completed,
    );
    expect(reported, isEmpty);

    final restore = installPerformanceTelemetry(reported.add);
    addTearDown(restore);
    performanceTelemetry.record(
      operation: TracedOperation.appStart,
      started: DateTime.now(),
      outcome: TracedOutcome.completed,
    );
    expect(reported.single.operation, TracedOperation.appStart);

    restore();
    performanceTelemetry.record(
      operation: TracedOperation.roomOpen,
      started: DateTime.now(),
      outcome: TracedOutcome.completed,
    );
    expect(
      reported,
      hasLength(1),
      reason: 'restoring must stop the sink, or a test leaks into the next',
    );
  });
}
