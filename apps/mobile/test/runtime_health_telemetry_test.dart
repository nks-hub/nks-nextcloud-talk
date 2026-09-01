import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/runtime_health_telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reports only allowlisted bucketed runtime health tags', () async {
    final reports = <Map<String, String>>[];
    final timers = <_PeriodicTimer>[];
    final monitor = RuntimeHealthTelemetry(
      runKind: RuntimeHealthRunKind.releaseGate,
      readRssBytes: () => 300 * 1024 * 1024,
      reportTags: (tags) async => reports.add(tags),
      lifecycleState: () => AppLifecycleState.resumed,
      createTimer: (duration, callback) {
        final timer = _PeriodicTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );

    await monitor.start();

    expect(timers.single.duration, const Duration(seconds: 15));
    expect(reports.single, <String, String>{
      'runtime.run_kind': 'release_gate',
      'runtime.lifecycle': 'foreground',
      'runtime.rss_bucket': '256-384m',
      'runtime.memory_pressure_seen': 'false',
    });
    expect(reports.expand((report) => report.keys).toSet(), <String>{
      'runtime.run_kind',
      'runtime.lifecycle',
      'runtime.rss_bucket',
      'runtime.memory_pressure_seen',
    });

    monitor.dispose();
  });

  test('RSS values are reduced to fixed buckets', () async {
    final cases = <(int, String)>[
      (0, 'unknown'),
      (127 * 1024 * 1024, '<128m'),
      (128 * 1024 * 1024, '128-256m'),
      (256 * 1024 * 1024, '256-384m'),
      (384 * 1024 * 1024, '384-512m'),
      (512 * 1024 * 1024, '512-768m'),
      (768 * 1024 * 1024, '768m+'),
    ];

    for (final (bytes, expected) in cases) {
      final reports = <Map<String, String>>[];
      final monitor = RuntimeHealthTelemetry(
        runKind: RuntimeHealthRunKind.ordinary,
        readRssBytes: () => bytes,
        reportTags: (tags) async => reports.add(tags),
        lifecycleState: () => AppLifecycleState.paused,
      );

      await monitor.start();
      expect(
        reports.single['runtime.rss_bucket'],
        expected,
        reason: '$bytes bytes',
      );
      monitor.dispose();
    }
  });

  test('samples only in foreground and stops after dispose', () async {
    var rss = 100 * 1024 * 1024;
    final reports = <Map<String, String>>[];
    final timers = <_PeriodicTimer>[];
    final monitor = RuntimeHealthTelemetry(
      runKind: RuntimeHealthRunKind.ordinary,
      readRssBytes: () => rss,
      reportTags: (tags) async => reports.add(tags),
      lifecycleState: () => AppLifecycleState.resumed,
      createTimer: (duration, callback) {
        final timer = _PeriodicTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );

    await monitor.start();
    expect(timers, hasLength(1));
    rss = 200 * 1024 * 1024;
    timers.single.fire();
    await monitor.settle();
    expect(reports.last['runtime.rss_bucket'], '128-256m');
    final countAfterBucketChange = reports.length;
    timers.single.fire();
    await monitor.settle();
    expect(reports, hasLength(countAfterBucketChange));

    monitor.didChangeAppLifecycleState(AppLifecycleState.paused);
    await monitor.settle();
    expect(timers.single.isActive, isFalse);
    expect(reports.last['runtime.lifecycle'], 'background');
    final countWhilePaused = reports.length;
    timers.single.fire();
    await monitor.settle();
    expect(reports, hasLength(countWhilePaused));

    monitor.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await monitor.settle();
    expect(timers, hasLength(2));
    expect(timers.last.isActive, isTrue);
    expect(reports.last['runtime.lifecycle'], 'foreground');

    monitor.dispose();
    expect(timers.last.isActive, isFalse);
    final countAfterDispose = reports.length;
    timers.last.fire();
    monitor.didHaveMemoryPressure();
    await monitor.settle();
    expect(reports, hasLength(countAfterDispose));
  });

  test('detached records its phase and permanently stops sampling', () async {
    final reports = <Map<String, String>>[];
    final timers = <_PeriodicTimer>[];
    final monitor = RuntimeHealthTelemetry(
      runKind: RuntimeHealthRunKind.ordinary,
      readRssBytes: () => 100 * 1024 * 1024,
      reportTags: (tags) async => reports.add(tags),
      lifecycleState: () => AppLifecycleState.resumed,
      createTimer: (duration, callback) {
        final timer = _PeriodicTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );

    await monitor.start();
    monitor.didChangeAppLifecycleState(AppLifecycleState.detached);
    await monitor.settle();

    expect(reports.last['runtime.lifecycle'], 'detached');
    expect(timers.single.isActive, isFalse);
    final countAfterDetach = reports.length;
    monitor.didChangeAppLifecycleState(AppLifecycleState.resumed);
    timers.single.fire();
    await monitor.settle();
    expect(reports, hasLength(countAfterDetach));
  });

  test('records memory pressure once without a raw memory value', () async {
    final reports = <Map<String, String>>[];
    final monitor = RuntimeHealthTelemetry(
      runKind: RuntimeHealthRunKind.ordinary,
      readRssBytes: () => 700 * 1024 * 1024,
      reportTags: (tags) async => reports.add(tags),
      lifecycleState: () => AppLifecycleState.paused,
    );

    await monitor.start();
    monitor.didHaveMemoryPressure();
    monitor.didHaveMemoryPressure();
    await monitor.settle();

    expect(reports, hasLength(2));
    expect(reports.last['runtime.memory_pressure_seen'], 'true');
    expect(reports.last['runtime.rss_bucket'], '512-768m');
    monitor.dispose();
  });
}

final class _PeriodicTimer implements Timer {
  _PeriodicTimer(this.duration, this.callback);

  final Duration duration;
  final void Function(Timer timer) callback;
  var _active = true;

  void fire() {
    if (_active) callback(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;
}
