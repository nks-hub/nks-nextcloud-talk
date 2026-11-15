import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/foreground_sync_loop.dart';

void main() {
  test(
    'stop cancels an active foreground task and prevents another cycle',
    () async {
      final entered = Completer<void>();
      var cycles = 0;
      final loop = ForegroundSyncLoop(
        task: (cancellation) async {
          cycles++;
          if (!entered.isCompleted) {
            entered.complete();
          }
          await cancellation;
        },
        successInterval: const Duration(seconds: 1),
        retryBaseDelay: const Duration(seconds: 1),
        retryMaximumDelay: const Duration(seconds: 8),
      );

      loop.start();
      await entered.future;
      await loop.stop();

      expect(cycles, 1);
      expect(loop.isRunning, isFalse);
    },
  );

  test('successful fast task waits for its minimum cycle interval', () async {
    final delayEntered = Completer<void>();
    final delays = <Duration>[];
    var cycles = 0;
    final loop = ForegroundSyncLoop(
      task: (_) async => cycles++,
      successInterval: const Duration(seconds: 2),
      retryBaseDelay: const Duration(seconds: 1),
      retryMaximumDelay: const Duration(seconds: 8),
      wait: (duration, cancellation) {
        delays.add(duration);
        if (!delayEntered.isCompleted) {
          delayEntered.complete();
        }
        return cancellation;
      },
    );

    loop.start();
    await delayEntered.future;

    expect(cycles, 1);
    expect(delays.single, greaterThan(Duration.zero));
    expect(delays.single, lessThanOrEqualTo(const Duration(seconds: 2)));
    await loop.stop();
    expect(cycles, 1);
  });

  testWidgets('stop cancels the default interval timer', (tester) async {
    final completed = Completer<void>();
    final loop = ForegroundSyncLoop(
      task: (_) async {},
      successInterval: const Duration(minutes: 1),
      retryBaseDelay: const Duration(seconds: 1),
      retryMaximumDelay: const Duration(seconds: 8),
      onSuccess: completed.complete,
    );

    loop.start();
    await completed.future;
    await loop.stop();
    await tester.pump();

    expect(loop.isRunning, isFalse);
  });

  test(
    'failure uses bounded exponential retry and reports the error',
    () async {
      final delayEntered = Completer<void>();
      final delays = <Duration>[];
      final errors = <Object>[];
      final loop = ForegroundSyncLoop(
        task: (_) => Future<void>.error(StateError('synthetic failure')),
        successInterval: const Duration(seconds: 2),
        retryBaseDelay: const Duration(seconds: 3),
        retryMaximumDelay: const Duration(seconds: 8),
        onError: errors.add,
        randomDouble: () => 0.5,
        wait: (duration, cancellation) {
          delays.add(duration);
          if (!delayEntered.isCompleted) {
            delayEntered.complete();
          }
          return cancellation;
        },
      );

      loop.start();
      await delayEntered.future;

      expect(errors, hasLength(1));
      expect(delays, [const Duration(seconds: 3)]);
      await loop.stop();
    },
  );

  test('wake ends a retry wait and restarts the backoff', () async {
    final delays = <Duration>[];
    var immediateWaits = 1;
    var blocked = Completer<void>();
    late final ForegroundSyncLoop loop;
    loop = ForegroundSyncLoop(
      task: (_) => Future<void>.error(StateError('synthetic failure')),
      successInterval: const Duration(seconds: 1),
      retryBaseDelay: const Duration(seconds: 3),
      retryMaximumDelay: const Duration(minutes: 1),
      randomDouble: () => 0.5,
      wait: (duration, cancellation) {
        delays.add(duration);
        if (immediateWaits > 0) {
          immediateWaits--;
          return Future<void>.value();
        }
        blocked.complete();
        return cancellation;
      },
    );

    loop.start();
    await blocked.future;
    expect(delays, const [Duration(seconds: 3), Duration(seconds: 6)]);

    blocked = Completer<void>();
    loop.wake();
    await blocked.future;

    expect(delays.last, const Duration(seconds: 3));
    expect(delays, hasLength(3));
    await loop.stop();
  });

  test('wake from inside a cycle skips only the wait after it', () async {
    final delays = <Duration>[];
    final blocked = Completer<void>();
    var cycles = 0;
    late final ForegroundSyncLoop loop;
    loop = ForegroundSyncLoop(
      task: (_) async {
        cycles++;
        if (cycles == 1) {
          loop.wake();
        }
      },
      successInterval: const Duration(minutes: 1),
      retryBaseDelay: const Duration(seconds: 1),
      retryMaximumDelay: const Duration(seconds: 8),
      wait: (duration, cancellation) {
        delays.add(duration);
        blocked.complete();
        return cancellation;
      },
    );

    loop.start();
    await blocked.future;

    expect(cycles, 2);
    expect(delays, hasLength(1));
    await loop.stop();
  });

  test('wake on a stopped loop is ignored', () async {
    final delays = <Duration>[];
    var blocked = Completer<void>();
    var cycles = 0;
    final loop = ForegroundSyncLoop(
      task: (_) async => cycles++,
      successInterval: const Duration(minutes: 1),
      retryBaseDelay: const Duration(seconds: 1),
      retryMaximumDelay: const Duration(seconds: 8),
      wait: (duration, cancellation) {
        delays.add(duration);
        blocked.complete();
        return cancellation;
      },
    );

    loop.wake();
    loop.start();
    await blocked.future;
    await loop.stop();
    loop.wake();
    expect(cycles, 1);

    blocked = Completer<void>();
    loop.start();
    await blocked.future;
    expect(cycles, 2);
    expect(delays, hasLength(2));
    await loop.stop();
  });

  testWidgets('wake ends the default retry timer and stop leaves none', (
    tester,
  ) async {
    var cycles = 0;
    final loop = ForegroundSyncLoop(
      task: (cancellation) async {
        cycles++;
        if (cycles == 1) {
          throw StateError('synthetic failure');
        }
        await cancellation;
      },
      successInterval: const Duration(seconds: 1),
      retryBaseDelay: const Duration(minutes: 1),
      retryMaximumDelay: const Duration(minutes: 1),
    );

    loop.start();
    await tester.pump();
    expect(cycles, 1);

    loop.wake();
    await tester.pump();
    expect(cycles, 2);

    await loop.stop();
    await tester.pump();
    expect(loop.isRunning, isFalse);
  });
}
