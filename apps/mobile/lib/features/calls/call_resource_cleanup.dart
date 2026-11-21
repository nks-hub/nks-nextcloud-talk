import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_media_engine.dart';

/// Records the first failure while allowing each independent release to run.
final class CallResourceCleanup {
  (Object, StackTrace)? _firstFailure;

  Future<void> run(FutureOr<void> Function()? release, {String? label}) async {
    if (release == null) return;
    try {
      await release();
    } on Object catch (error, stackTrace) {
      _firstFailure ??= (error, stackTrace);
      if (label != null) {
        final reason = error is CallMediaException
            ? error.code.name
            : error.runtimeType;
        debugPrint('[call] $label cleanup failed: $reason');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace, maxFrames: 5);
      }
    }
  }

  void rethrowFailure() {
    if (_firstFailure case (final error, final stackTrace)) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}
