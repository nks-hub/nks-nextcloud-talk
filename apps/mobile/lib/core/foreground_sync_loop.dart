import 'dart:async';
import 'dart:math';

typedef ForegroundSyncTask = Future<void> Function(Future<void> cancellation);
typedef ForegroundSyncWait =
    Future<void> Function(Duration duration, Future<void> cancellation);

/// Runs one account-scoped foreground synchronization task at a time.
///
/// The task receives a cancellation future that must also be forwarded to any
/// abortable network request. A successful fast response is rate limited, and
/// failures use bounded exponential backoff.
final class ForegroundSyncLoop {
  ForegroundSyncLoop({
    required this.task,
    required this.successInterval,
    required this.retryBaseDelay,
    required this.retryMaximumDelay,
    this.onCycleStarted,
    this.onSuccess,
    this.onError,
    ForegroundSyncWait? wait,
    double Function()? randomDouble,
  }) : _wait = wait ?? _waitForCancellationOrDelay,
       _randomDouble = randomDouble ?? Random().nextDouble {
    if (successInterval.isNegative ||
        retryBaseDelay <= Duration.zero ||
        retryMaximumDelay < retryBaseDelay) {
      throw ArgumentError('Invalid foreground synchronization timing');
    }
  }

  final ForegroundSyncTask task;
  final Duration successInterval;
  final Duration retryBaseDelay;
  final Duration retryMaximumDelay;
  final void Function()? onCycleStarted;
  final void Function()? onSuccess;
  final void Function(Object error)? onError;
  final ForegroundSyncWait _wait;
  final double Function() _randomDouble;

  Completer<void>? _cancellation;
  Future<void>? _runner;

  bool get isRunning => _runner != null;

  void start() {
    if (_runner != null) {
      return;
    }
    final cancellation = Completer<void>();
    _cancellation = cancellation;
    final runner = _run(cancellation);
    _runner = runner;
    // `unawaited` only silences the analyzer; it attaches no error handler, so
    // anything escaping the loop would sit on a future nobody listens to and
    // reach `PlatformDispatcher.onError` as a FATAL crash. The loop already
    // reports every failure of the task through `onError` and retries it —
    // what can still escape is a throw from that callback itself, or from the
    // wait between attempts, and neither is worth ending the application for.
    // `stop()` still awaits `_runner` and still sees the error.
    unawaited(
      runner
          .whenComplete(() {
            if (identical(_runner, runner)) {
              _runner = null;
              _cancellation = null;
            }
          })
          .catchError((Object _, StackTrace _) {}),
    );
  }

  Future<void> stop() async {
    final cancellation = _cancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    final runner = _runner;
    if (runner != null) {
      await runner;
    }
  }

  Future<void> _run(Completer<void> cancellation) async {
    var consecutiveFailures = 0;
    while (!cancellation.isCompleted) {
      final elapsed = Stopwatch()..start();
      try {
        onCycleStarted?.call();
        await task(cancellation.future);
        if (cancellation.isCompleted) {
          return;
        }
        consecutiveFailures = 0;
        onSuccess?.call();
        elapsed.stop();
        final remaining = successInterval - elapsed.elapsed;
        if (remaining > Duration.zero) {
          await _wait(remaining, cancellation.future);
        }
      } on Object catch (error) {
        if (cancellation.isCompleted) {
          return;
        }
        consecutiveFailures++;
        onError?.call(error);
        await _wait(_retryDelay(consecutiveFailures), cancellation.future);
      }
    }
  }

  Duration _retryDelay(int consecutiveFailures) {
    var delay = retryBaseDelay;
    for (
      var attempt = 1;
      attempt < consecutiveFailures && delay < retryMaximumDelay;
      attempt++
    ) {
      final doubled = delay.inMicroseconds * 2;
      delay = Duration(
        microseconds: doubled > retryMaximumDelay.inMicroseconds
            ? retryMaximumDelay.inMicroseconds
            : doubled,
      );
    }
    final randomValue = _randomDouble();
    if (randomValue < 0 || randomValue > 1) {
      throw StateError('Foreground synchronization jitter is out of range');
    }
    final jitteredMicroseconds =
        (delay.inMicroseconds * (0.8 + (randomValue * 0.4))).round();
    return Duration(
      microseconds: jitteredMicroseconds > retryMaximumDelay.inMicroseconds
          ? retryMaximumDelay.inMicroseconds
          : jitteredMicroseconds,
    );
  }
}

Future<void> _waitForCancellationOrDelay(
  Duration duration,
  Future<void> cancellation,
) async {
  final completed = Completer<void>();
  final timer = Timer(duration, completed.complete);
  cancellation.then<void>((_) {
    timer.cancel();
    if (!completed.isCompleted) {
      completed.complete();
    }
  }).ignore();
  await completed.future;
  timer.cancel();
}
