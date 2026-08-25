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
}
