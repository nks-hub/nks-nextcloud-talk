// ignore_for_file: prefer_initializing_formals

import 'dart:async';

/// The operations the app is allowed to time.
///
/// A closed set on purpose. A free-form name is how a room token, a server
/// address or a file name ends up in telemetry: somebody writes
/// `'open $roomToken'` and it ships. Nothing outside this enum can be traced,
/// so there is no place for a caller to put content in the first place.
enum TracedOperation {
  appStart('app.start'),
  conversationSync('conversation.sync'),
  roomOpen('room.open'),
  timelineRender('timeline.render'),
  attachmentUpload('attachment.upload'),
  backgroundWake('background.wake');

  const TracedOperation(this.spanName);

  /// The literal name reported for this operation. Never interpolated.
  final String spanName;
}

/// How an operation ended. Reported instead of an error message, which could
/// carry a server address or a file name.
enum TracedOutcome { completed, failed, cancelled }

/// One finished measurement, ready to report.
final class TracedSpan {
  const TracedSpan({
    required this.operation,
    required this.outcome,
    required this.duration,
  });

  final TracedOperation operation;
  final TracedOutcome outcome;
  final Duration duration;

  /// Durations are reported as a bucket rather than a millisecond count.
  ///
  /// A precise duration on a rare operation is close to an identifier: it
  /// links two events of the same user across a session. Buckets keep the
  /// signal that matters — is this fast, slow or hopeless — and drop the rest.
  String get durationBucket {
    final milliseconds = duration.inMilliseconds;
    if (milliseconds < 100) {
      return '<100ms';
    }
    if (milliseconds < 500) {
      return '<500ms';
    }
    if (milliseconds < 2000) {
      return '<2s';
    }
    if (milliseconds < 10000) {
      return '<10s';
    }
    return '>=10s';
  }

  /// Everything this measurement is allowed to carry. Deliberately built from
  /// closed enums and a bucket, so there is no field an account id, a room
  /// token, a URL or a file name could travel in.
  Map<String, String> get tags => <String, String>{
    'operation': operation.spanName,
    'outcome': outcome.name,
    'duration': durationBucket,
  };
}

typedef TracedSpanSink = void Function(TracedSpan span);

/// Times the operations named in [TracedOperation] and hands finished spans to
/// a sink, under a fixed budget.
///
/// The budget is what keeps this from becoming a second telemetry firehose:
/// each operation reports at most once per [interval], so a chat that syncs
/// every second contributes one span a minute, not sixty.
final class PerformanceTelemetry {
  PerformanceTelemetry({
    required TracedSpanSink report,
    Duration interval = const Duration(minutes: 1),
    DateTime Function() clock = DateTime.now,
  }) : _report = report,
       _interval = interval,
       _clock = clock;

  final TracedSpanSink _report;
  final Duration _interval;
  final DateTime Function() _clock;
  final Map<TracedOperation, DateTime> _lastReported = {};

  /// Runs [action], times it, and reports the result if the budget allows.
  ///
  /// The measurement never changes what the caller sees: a thrown error is
  /// rethrown untouched after being recorded as an outcome, and the error
  /// itself is not reported here — that is the crash reporter's job, with its
  /// own scrubbing.
  Future<T> trace<T>(
    TracedOperation operation,
    Future<T> Function() action,
  ) async {
    final started = _clock();
    try {
      final result = await action();
      _finish(operation, started, TracedOutcome.completed);
      return result;
    } on Object {
      _finish(operation, started, TracedOutcome.failed);
      rethrow;
    }
  }

  /// Records an operation whose start and end are not one call — an upload,
  /// for instance, which is enqueued in one place and reaches its terminal
  /// phase in another.
  void record({
    required TracedOperation operation,
    required DateTime started,
    required TracedOutcome outcome,
  }) => _finish(operation, started, outcome);

  /// Records an operation that ended without running to completion, such as a
  /// sync abandoned because the room was closed.
  void recordCancelled(TracedOperation operation, DateTime started) =>
      _finish(operation, started, TracedOutcome.cancelled);

  void _finish(
    TracedOperation operation,
    DateTime started,
    TracedOutcome outcome,
  ) {
    final now = _clock();
    final last = _lastReported[operation];
    if (last != null && now.difference(last) < _interval) {
      return;
    }
    _lastReported[operation] = now;
    _report(
      TracedSpan(
        operation: operation,
        outcome: outcome,
        duration: now.difference(started),
      ),
    );
  }
}

/// The process-wide measurement.
///
/// Ambient on purpose. The crash reporter it feeds is ambient too, and
/// threading a measurement through the constructor of every service — and
/// therefore through the provider graph — would touch far more code than the
/// measurement is worth. It reports nothing until [installPerformanceTelemetry]
/// gives it a sink, so a test or a build with crash reporting off measures
/// into a hole rather than into a stub that pretends to work.
PerformanceTelemetry get performanceTelemetry => _ambient;

PerformanceTelemetry _ambient = PerformanceTelemetry(report: _discard);

void _discard(TracedSpan span) {}

/// Points the ambient measurement at [report]. Returns a callback that puts
/// the previous one back, so a test never leaks its sink into the next one.
void Function() installPerformanceTelemetry(
  TracedSpanSink report, {
  Duration interval = const Duration(minutes: 1),
  DateTime Function() clock = DateTime.now,
}) {
  final previous = _ambient;
  _ambient = PerformanceTelemetry(
    report: report,
    interval: interval,
    clock: clock,
  );
  return () => _ambient = previous;
}
