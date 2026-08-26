import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart' show MissingPluginException;

/// Emits hints that a usable network transport may have appeared.
///
/// A hint is never treated as proof of internet access. Callers must still
/// perform their own authenticated network read before mutating an outbox.
final class ConnectivityWakeSource {
  ConnectivityWakeSource({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity() {
    events = _readEvents().asBroadcastStream();
  }

  final Connectivity _connectivity;
  late final Stream<void> events;

  Stream<void> _readEvents() async* {
    try {
      // Probe through the regular method channel first. Unlike EventChannel,
      // this reports MissingPluginException to the caller, so pure Dart/widget
      // runners can stop before Flutter registers an uncaught services error.
      await _connectivity.checkConnectivity();
      await for (final results in _connectivity.onConnectivityChanged) {
        if (results.any((result) => result != ConnectivityResult.none)) {
          yield null;
        }
      }
    } on MissingPluginException {
      // Pure widget/unit tests do not register platform plugins. The regular
      // foreground loop remains the fallback when no event channel exists.
    }
  }
}
