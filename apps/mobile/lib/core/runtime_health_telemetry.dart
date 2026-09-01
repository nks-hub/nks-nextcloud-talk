import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

enum RuntimeHealthRunKind { ordinary, releaseGate }

typedef RuntimeHealthTagReporter =
    Future<void> Function(Map<String, String> tags);
typedef RuntimeHealthTimerFactory =
    Timer Function(Duration duration, void Function(Timer timer) callback);

final class RuntimeHealthTelemetry with WidgetsBindingObserver {
  factory RuntimeHealthTelemetry({
    required RuntimeHealthRunKind runKind,
    required RuntimeHealthTagReporter reportTags,
    int Function()? readRssBytes,
    AppLifecycleState? Function()? lifecycleState,
    RuntimeHealthTimerFactory createTimer = Timer.periodic,
  }) {
    return RuntimeHealthTelemetry._(
      runKind,
      reportTags,
      readRssBytes ?? (() => ProcessInfo.currentRss),
      lifecycleState ?? (() => WidgetsBinding.instance.lifecycleState),
      createTimer,
    );
  }

  RuntimeHealthTelemetry._(
    this.runKind,
    this._reportTags,
    this._readRssBytes,
    this._lifecycleState,
    this._createTimer,
  );

  static const sampleInterval = Duration(seconds: 15);

  final RuntimeHealthRunKind runKind;
  final RuntimeHealthTagReporter _reportTags;
  final int Function() _readRssBytes;
  final AppLifecycleState? Function() _lifecycleState;
  final RuntimeHealthTimerFactory _createTimer;

  Timer? _timer;
  Future<void> _reportTail = Future<void>.value();
  var _lifecycle = 'background';
  var _rss = 'unknown';
  var _memoryPressureSeen = false;
  var _started = false;
  var _disposed = false;

  Map<String, String> get tags => _runtimeHealthTags(
    runKind: runKind,
    lifecycle: _lifecycle,
    rssBucket: _rss,
    memoryPressureSeen: _memoryPressureSeen,
  );

  Future<void> start() async {
    if (_started) return;
    if (_disposed) throw StateError('Runtime health telemetry is disposed');
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final foreground = _isForeground(_lifecycleState());
    _lifecycle = foreground ? 'foreground' : 'background';
    _rss = _readRssBucket();
    _queueReport();
    if (foreground) _armTimer();
    await settle();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || !_started) return;
    if (state == AppLifecycleState.detached) {
      _lifecycle = 'detached';
      _cancelTimer();
      _queueReport();
      _disposed = true;
      _removeObserver();
      return;
    }
    final foreground = state == AppLifecycleState.resumed;
    final next = foreground ? 'foreground' : 'background';
    if (_lifecycle != next) {
      _lifecycle = next;
      if (foreground) _rss = _readRssBucket();
      _queueReport();
    }
    if (foreground) {
      _armTimer();
    } else {
      _cancelTimer();
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (_disposed || !_started || _memoryPressureSeen) return;
    _memoryPressureSeen = true;
    _rss = _readRssBucket();
    _queueReport();
  }

  Future<void> settle() => _reportTail;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelTimer();
    _removeObserver();
  }

  void _armTimer() {
    if (_disposed || _timer?.isActive == true) return;
    _timer = _createTimer(sampleInterval, (_) => _sample());
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _sample() {
    if (_disposed || _lifecycle != 'foreground') return;
    final next = _readRssBucket();
    if (next == _rss) return;
    _rss = next;
    _queueReport();
  }

  String _readRssBucket() {
    try {
      return runtimeHealthRssBucket(_readRssBytes());
    } on Object {
      // An unavailable OS metric must not affect application startup.
      return 'unknown';
    }
  }

  void _queueReport() {
    final tags = this.tags;
    _reportTail = _reportTail.then((_) async {
      try {
        await _reportTags(tags);
      } on Object {
        // Telemetry transport failure must not affect the application.
      }
    });
  }

  void _removeObserver() {
    if (!_started) return;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }
}

Map<String, String> currentRuntimeHealthTags(RuntimeHealthRunKind runKind) {
  var rssBucket = 'unknown';
  try {
    rssBucket = runtimeHealthRssBucket(ProcessInfo.currentRss);
  } on Object {
    // An unavailable OS metric must not affect release-gate reporting.
  }
  final state = WidgetsBinding.instance.lifecycleState;
  return _runtimeHealthTags(
    runKind: runKind,
    lifecycle: switch (state) {
      null || AppLifecycleState.resumed => 'foreground',
      AppLifecycleState.detached => 'detached',
      _ => 'background',
    },
    rssBucket: rssBucket,
    memoryPressureSeen: false,
  );
}

String runtimeHealthRssBucket(int bytes) => switch (bytes) {
  <= 0 => 'unknown',
  < 128 * 1024 * 1024 => '<128m',
  < 256 * 1024 * 1024 => '128-256m',
  < 384 * 1024 * 1024 => '256-384m',
  < 512 * 1024 * 1024 => '384-512m',
  < 768 * 1024 * 1024 => '512-768m',
  _ => '768m+',
};

bool _isForeground(AppLifecycleState? state) =>
    state == null || state == AppLifecycleState.resumed;

Map<String, String> _runtimeHealthTags({
  required RuntimeHealthRunKind runKind,
  required String lifecycle,
  required String rssBucket,
  required bool memoryPressureSeen,
}) => Map<String, String>.unmodifiable(<String, String>{
  'runtime.run_kind': switch (runKind) {
    RuntimeHealthRunKind.ordinary => 'ordinary',
    RuntimeHealthRunKind.releaseGate => 'release_gate',
  },
  'runtime.lifecycle': lifecycle,
  'runtime.rss_bucket': rssBucket,
  'runtime.memory_pressure_seen': memoryPressureSeen.toString(),
});
