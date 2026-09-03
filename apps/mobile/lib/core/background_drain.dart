import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel the platform's own background scheduler shares with the app:
/// Android `JobScheduler` and iOS `BGTaskScheduler`.
///
/// Everything before this only woke the outbox in the foreground — the
/// connectivity and lifecycle hints in `outboxDrainProvider` — so a phone that
/// left the tunnel in a pocket delivered nothing until its owner opened the
/// app again. The platform side wakes us instead once the network is back.
///
/// Dart calls `ensureScheduled` outwards; the platform calls `runDrain`
/// inwards and, in a headless isolate, is answered with `finished`.
const backgroundDrainChannel = MethodChannel(
  'com.nkshub.nextcloudtalk/background_drain',
);

/// Registers the recurring wake with the platform, at most once per process.
///
/// Scheduling an already registered periodic job restarts its period, so a
/// caller that asked again on every rebuild would push the next run further
/// away every time and the job would never fire at all. The platform side
/// checks its own pending job too; this keeps the channel quiet either way.
class BackgroundDrainSchedule {
  BackgroundDrainSchedule({this.channel = backgroundDrainChannel});

  final MethodChannel channel;
  Future<void>? _requested;

  Future<void> ensure() => _requested ??= _request();

  Future<void> _request() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        break;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        // Desktop keeps the app running; there is nothing to be woken from.
        return;
    }
    try {
      await channel.invokeMethod<void>('ensureScheduled');
    } on MissingPluginException {
      // A build without the native side, or a plain widget test binding.
    } on PlatformException {
      // The platform refused the wake; the foreground hints still stand.
    }
  }
}

/// Runs one drain in the headless isolate the platform started, then reports
/// the outcome so the job can be finished or rescheduled.
///
/// A failure asks for a reschedule rather than swallowing itself: the rows are
/// still in the outbox, and the wake that found no network is exactly the one
/// worth repeating.
Future<void> runBackgroundDrainIsolate({
  required Future<void> Function() drain,
  MethodChannel channel = backgroundDrainChannel,
}) async {
  var retry = false;
  try {
    await drain();
  } on Object {
    retry = true;
  }
  try {
    await channel.invokeMethod<void>('finished', <String, Object?>{
      'retry': retry,
    });
  } on Object {
    // Nothing is listening any more; the job times out on its own.
  }
}
