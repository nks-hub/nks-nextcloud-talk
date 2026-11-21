part of 'attachment_service.dart';

extension _AttachmentServiceLifecycle on AttachmentService {
  Future<T> _trackOperation<T>(Future<T> Function() run) {
    final finished = Completer<void>();
    _activeOperations.add(finished.future);
    return Future<T>.sync(run).whenComplete(() {
      _activeOperations.remove(finished.future);
      finished.complete();
    });
  }

  Future<void> _closeRuntime() async {
    _steps.cancelWaiters();
    Object? activeFailure;
    StackTrace? activeFailureStack;
    Object? cleanupFailure;
    StackTrace? cleanupFailureStack;

    Future<void> captureActiveFailure(
      FutureOr<void> Function() operation,
    ) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        activeFailure ??= error;
        activeFailureStack ??= stackTrace;
      }
    }

    Future<void> captureCleanupFailure(
      FutureOr<void> Function() operation,
    ) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        cleanupFailure ??= error;
        cleanupFailureStack ??= stackTrace;
      }
    }

    try {
      await captureActiveFailure(() => _ready);
      final confirmationSubscription = _confirmationSubscription;
      _confirmationSubscription = null;
      await captureActiveFailure(() => confirmationSubscription?.cancel());
      await captureActiveFailure(() => _confirmationTail);
      await captureActiveFailure(() => _startupMaintenance);
      for (final timer in _retryTimers.values) {
        timer.cancel();
      }
      _retryTimers.clear();
      _retryDeadlines.clear();
      _syncTransferActivity();
      _credentialRetryCounts.clear();
      for (final timer in _confirmationRetryTimers.values) {
        timer.cancel();
      }
      _confirmationRetryTimers.clear();
      _roomRerunRequests.clear();
      for (final cancellation in _cancellations.values) {
        cancellation.cancel();
      }
      await captureActiveFailure(
        () => Future.wait<void>(_roomRuns.values.toList(growable: false)),
      );
      await captureActiveFailure(
        () => Future.wait<void>(
          _confirmationCatchUps.values.toList(growable: false),
        ),
      );
      // Admission and cancellation can write before or after a room run.
      await Future.wait(_activeOperations.toList(growable: false));
    } finally {
      _confirmationRetryCounts.clear();
      _deferredConfirmations.clear();
      _confirmationResumeRequests.clear();
      await captureCleanupFailure(
        () => _releaseVerifiedAttachmentSources(this),
      );
      await captureCleanupFailure(_transport.close);
    }
    final firstActiveFailure = activeFailure;
    if (firstActiveFailure != null) {
      Error.throwWithStackTrace(firstActiveFailure, activeFailureStack!);
    }
    final firstCleanupFailure = cleanupFailure;
    if (firstCleanupFailure != null) {
      Error.throwWithStackTrace(firstCleanupFailure, cleanupFailureStack!);
    }
  }
}
