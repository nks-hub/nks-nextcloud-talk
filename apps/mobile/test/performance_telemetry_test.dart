import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/performance_telemetry.dart';

void main() {
  late List<TracedSpan> reported;
  late DateTime now;

  PerformanceTelemetry build({
    Duration interval = const Duration(minutes: 1),
  }) => PerformanceTelemetry(
    report: reported.add,
    interval: interval,
    clock: () => now,
  );

  setUp(() {
    reported = <TracedSpan>[];
    now = DateTime.utc(2026, 9, 2, 12);
  });

  test('a measurement carries no content, only closed values', () async {
    final telemetry = build();

    await telemetry.trace(TracedOperation.roomOpen, () async {
      now = now.add(const Duration(milliseconds: 250));
      // The values below are exactly what must never reach telemetry.
      return 'account-a/roomtoken/https://cloud.example.invalid/photo.jpg';
    });

    final span = reported.single;
    final serialised = '${span.operation.spanName} ${span.tags}';
    for (final secret in const <String>[
      'account-a',
      'roomtoken',
      'cloud.example.invalid',
      'photo.jpg',
    ]) {
      expect(serialised, isNot(contains(secret)), reason: secret);
    }
    expect(span.tags, {
      'operation': 'room.open',
      'outcome': 'completed',
      'duration': '<500ms',
    });
  });

  test('durations are bucketed, never reported to the millisecond', () {
    const cases = <(int, String)>[
      (0, '<100ms'),
      (99, '<100ms'),
      (100, '<500ms'),
      (1999, '<2s'),
      (2000, '<10s'),
      (10000, '>=10s'),
    ];

    for (final (milliseconds, bucket) in cases) {
      expect(
        TracedSpan(
          operation: TracedOperation.appStart,
          outcome: TracedOutcome.completed,
          duration: Duration(milliseconds: milliseconds),
        ).durationBucket,
        bucket,
        reason: '$milliseconds ms',
      );
    }
  });

  test('a failure is an outcome, and the error still reaches the caller', () {
    final telemetry = build();

    expect(
      () => telemetry.trace(
        TracedOperation.conversationSync,
        () async => throw StateError('server said no'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('a failed measurement says so without the error text', () async {
    final telemetry = build();

    try {
      await telemetry.trace(
        TracedOperation.conversationSync,
        () async => throw StateError('https://cloud.example.invalid refused'),
      );
    } on StateError {
      // Expected; the assertion is about what was reported.
    }

    expect(reported.single.outcome, TracedOutcome.failed);
    expect(
      reported.single.tags.toString(),
      isNot(contains('cloud.example.invalid')),
    );
  });

  test(
    'the budget holds a chatty operation to one span per interval',
    () async {
      final telemetry = build();

      for (var index = 0; index < 60; index++) {
        await telemetry.trace(TracedOperation.roomOpen, () async {
          now = now.add(const Duration(seconds: 1));
        });
      }

      // Sixty opens across a minute of fake time, one span.
      expect(reported, hasLength(1));
    },
  );

  test(
    'the budget is per operation, so one does not silence another',
    () async {
      final telemetry = build();

      Future<void> slowSync() => telemetry.trace(
        TracedOperation.conversationSync,
        () async => now = now.add(const Duration(seconds: 3)),
      );
      await slowSync();
      await telemetry.trace(TracedOperation.roomOpen, () async {});
      await slowSync();

      expect(reported.map((span) => span.operation), <TracedOperation>[
        TracedOperation.conversationSync,
        TracedOperation.roomOpen,
      ]);
    },
  );

  test('a routine fast sync is silent, a slow or failed one is not', () async {
    // Measured on the emulator on 2026-09-03: fast completed syncs were ~50
    // of ~52 performance events an hour. They say nothing; they only cost.
    final telemetry = build();

    await telemetry.trace(TracedOperation.conversationSync, () async {
      now = now.add(const Duration(milliseconds: 300));
    });
    expect(reported, isEmpty);

    now = now.add(const Duration(minutes: 2));
    await telemetry.trace(TracedOperation.conversationSync, () async {
      now = now.add(const Duration(seconds: 3));
    });
    expect(reported.single.durationBucket, '<10s');

    now = now.add(const Duration(minutes: 2));
    await expectLater(
      telemetry.trace<void>(
        TracedOperation.conversationSync,
        () async => throw StateError('server unreachable'),
      ),
      throwsStateError,
    );
    expect(reported.last.outcome, TracedOutcome.failed);
  });

  test('a cancelled operation is reported as cancelled', () {
    final telemetry = build();
    final started = now;
    now = now.add(const Duration(seconds: 3));

    telemetry.recordCancelled(TracedOperation.attachmentUpload, started);

    expect(reported.single.outcome, TracedOutcome.cancelled);
    expect(reported.single.durationBucket, '<10s');
  });
}
