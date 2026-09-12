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

/// The steps inside a traced operation.
///
/// A closed set for the same reason [TracedOperation] is one, and worth
/// having for a plainer reason: an operation timed as a whole says only that
/// it was slow. Ten seconds of "conversation.sync" could be the network, the
/// credential store or the database, and until 12 September 2026 there was no
/// way to tell which — every investigation had to guess and then measure by
/// hand on a machine nobody could reproduce the problem on.
enum TracedPhase {
  /// Reading the stored app password, which on some platforms talks to the
  /// operating system's own credential store.
  credentials('credentials'),

  /// Asking the server what it supports.
  capabilities('capabilities'),

  /// Reading what is already stored, before anything is asked of the server.
  localState('local_state'),

  /// The request that fetches the thing being synced.
  fetch('fetch'),

  /// Writing what came back.
  store('store');

  const TracedPhase(this.tagName);

  /// The literal name reported for this phase. Never interpolated.
  final String tagName;
}

/// One finished measurement, ready to report.
final class TracedSpan {
  const TracedSpan({
    required this.operation,
    required this.outcome,
    required this.duration,
    this.phases = const <TracedPhase, Duration>{},
  });

  final TracedOperation operation;
  final TracedOutcome outcome;
  final Duration duration;

  /// How long each step took, for the operations that record them. Empty for
  /// the ones that do not, which changes nothing about what they report.
  final Map<TracedPhase, Duration> phases;

  /// Durations are reported as a bucket rather than a millisecond count.
  ///
  /// A precise duration on a rare operation is close to an identifier: it
  /// links two events of the same user across a session. Buckets keep the
  /// signal that matters — is this fast, slow or hopeless — and drop the rest.
  String get durationBucket => bucketOf(duration);

  /// The step that took the longest, or null when none were recorded. The one
  /// tag worth reading first: it names where the time went.
  TracedPhase? get slowestPhase {
    TracedPhase? slowest;
    var longest = Duration.zero;
    for (final entry in phases.entries) {
      if (entry.value > longest) {
        longest = entry.value;
        slowest = entry.key;
      }
    }
    return slowest;
  }

  static String bucketOf(Duration duration) {
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
  Map<String, String> get tags {
    final tags = <String, String>{
      'operation': operation.spanName,
      'outcome': outcome.name,
      'duration': durationBucket,
    };
    for (final entry in phases.entries) {
      tags['phase.${entry.key.tagName}'] = bucketOf(entry.value);
    }
    final slowest = slowestPhase;
    if (slowest != null) {
      tags['slowest_phase'] = slowest.tagName;
    }
    return tags;
  }
}

/// Times the steps inside one traced operation.
///
/// A step entered more than once — a retry, a loop — adds to what it already
/// spent, so the total still says how much of the operation that step was.
final class PhaseRecorder {
  PhaseRecorder({DateTime Function() clock = DateTime.now}) : _clock = clock;

  final DateTime Function() _clock;
  final Map<TracedPhase, Duration> _spent = <TracedPhase, Duration>{};

  Map<TracedPhase, Duration> get measured =>
      Map<TracedPhase, Duration>.unmodifiable(_spent);

  /// Runs [step] and adds its time to [phase]. A thrown error is timed the
  /// same as a returned value and rethrown untouched: a step that fails
  /// slowly is exactly the one worth seeing.
  Future<T> record<T>(TracedPhase phase, Future<T> Function() step) async {
    final started = _clock();
    try {
      return await step();
    } finally {
      _spent[phase] = (_spent[phase] ?? Duration.zero) +
          _clock().difference(started);
    }
  }
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

  /// Runs [action], timing it and the steps it chooses to name.
  ///
  /// The recorder is handed in rather than taken from the ambient telemetry,
  /// so the phases belong to this one run and cannot be mixed with another
  /// sync happening at the same time.
  Future<T> traceInPhases<T>(
    TracedOperation operation,
    Future<T> Function(PhaseRecorder phases) action,
  ) async {
    final started = _clock();
    final recorder = PhaseRecorder(clock: _clock);
    try {
      final result = await action(recorder);
      _finish(operation, started, TracedOutcome.completed, recorder.measured);
      return result;
    } on Object {
      _finish(operation, started, TracedOutcome.failed, recorder.measured);
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
    Map<TracedPhase, Duration> phases = const <TracedPhase, Duration>{},
  }) => _finish(operation, started, outcome, phases);

  /// Records an operation that ended without running to completion, such as a
  /// sync abandoned because the room was closed.
  void recordCancelled(TracedOperation operation, DateTime started) =>
      _finish(operation, started, TracedOutcome.cancelled);

  void _finish(
    TracedOperation operation,
    DateTime started,
    TracedOutcome outcome, [
    Map<TracedPhase, Duration> phases = const <TracedPhase, Duration>{},
  ]) {
    final now = _clock();
    final duration = now.difference(started);
    // A sync that finished quickly is the expected state, and there is one
    // every few seconds: measured on 2026-09-03 it made up ~50 of ~52
    // events an hour, ~13 KB each, for a graph of "fine". Only a slow or
    // broken sync carries information; the other operations are rare enough
    // that their completions still say something.
    if (operation == TracedOperation.conversationSync &&
        outcome == TracedOutcome.completed &&
        duration < _routineSyncCeiling) {
      return;
    }
    final last = _lastReported[operation];
    if (last != null && now.difference(last) < _interval) {
      return;
    }
    _lastReported[operation] = now;
    _report(
      TracedSpan(
        operation: operation,
        outcome: outcome,
        duration: duration,
        phases: phases,
      ),
    );
  }

  /// Completed syncs below this are not reported; it is the lower edge of the
  /// `<10s` bucket, so what does get through is already "slow".
  static const _routineSyncCeiling = Duration(seconds: 2);
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
