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

  /// Asks for one drain as soon as a network is there, for text that is
  /// waiting while the app is not in front. The recurring wake may be a
  /// quarter of an hour away.
  ///
  /// Android only. The caller asks only while something is pending, and the
  /// platform keeps a request it already holds.
  Future<void> requestOnce() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await channel.invokeMethod<void>('scheduleOnce');
    } on MissingPluginException {
      // A build without the native side, or a plain widget test binding.
    } on PlatformException {
      // The platform refused the wake; the recurring one still stands.
    }
  }

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

/// How long the process is kept reachable after the app was left with text
/// still waiting to be sent.
const unsentTextHoldWindow = Duration(minutes: 3);

/// Keeps the process reachable for a while after the app is left with text
/// waiting to be sent.
///
/// In battery saver Android cuts a background app off the network, so the
/// scheduled wake never sees one and a message written in a tunnel waits for
/// the app to be opened. A process holding a foreground service keeps its
/// network, and its own retry timer and connectivity wake then deliver.
///
/// Bounded twice: released as soon as nothing is waiting, and after [window]
/// at the latest, when [onWindowEnd] hands the rest to the scheduled wake.
/// Only [paused] may take the hold. The platform refuses a service started
/// once the app is in the background, so text admitted later is not held.
final class UnsentTextHold {
  UnsentTextHold({
    required this.watchPending,
    required this.hold,
    required this.onWindowEnd,
    this.window = unsentTextHoldWindow,
  });

  final Stream<bool> Function() watchPending;
  final void Function(bool active) hold;
  final void Function() onWindowEnd;
  final Duration window;

  StreamSubscription<bool>? _pending;
  Timer? _windowEnd;
  bool _held = false;
  int _generation = 0;

  /// The app left the screen.
  void paused() {
    _release();
    final generation = _generation;
    var first = true;
    _pending = watchPending().listen((pending) {
      if (generation != _generation) {
        return;
      }
      if (first && pending) {
        _held = true;
        hold(true);
        _windowEnd = Timer(window, () {
          _release();
          onWindowEnd();
        });
      } else if (!pending || !_held) {
        _release();
      }
      first = false;
    }, onError: (Object _) => _release());
  }

  /// The app is back in front, where sending needs no help.
  void resumed() => _release();

  void dispose() => _release();

  void _release() {
    _generation++;
    unawaited(_pending?.cancel());
    _pending = null;
    _windowEnd?.cancel();
    _windowEnd = null;
    if (_held) {
      _held = false;
      hold(false);
    }
  }
}

/// How long one headless drain may take before the wake is rescheduled.
///
/// Shorter than the window Android and iOS give a background job, so the app
/// gets to say "try again" rather than being killed mid-drain.
const Duration backgroundDrainDeadline = Duration(seconds: 25);

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
    // Bounded, because the drain reaches the network three times and a socket
    // that never answers would leave the platform waiting for a result that
    // never comes: the job then dies on the system's own watchdog instead of
    // being rescheduled, which is the one outcome that loses the wake.
    await drain().timeout(backgroundDrainDeadline);
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
