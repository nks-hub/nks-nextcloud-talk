import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/apple_push_foreground_dedup.dart';

void main() {
  test('suppresses within the window right after a wake-up', () {
    final deduplicator = ForegroundPushDeduplicator(
      window: const Duration(seconds: 5),
    );
    final wakeUp = DateTime(2026, 1, 1, 12, 0, 0);

    deduplicator.markWakeUp(now: wakeUp);

    expect(
      deduplicator.shouldSuppress(now: wakeUp.add(const Duration(seconds: 3))),
      isTrue,
    );
  });

  test('stops suppressing once the window has passed', () {
    final deduplicator = ForegroundPushDeduplicator(
      window: const Duration(seconds: 5),
    );
    final wakeUp = DateTime(2026, 1, 1, 12, 0, 0);

    deduplicator.markWakeUp(now: wakeUp);

    expect(
      deduplicator.shouldSuppress(now: wakeUp.add(const Duration(seconds: 6))),
      isFalse,
    );
  });

  test('never suppresses before any wake-up was recorded', () {
    final deduplicator = ForegroundPushDeduplicator();

    expect(deduplicator.shouldSuppress(), isFalse);
  });
}
