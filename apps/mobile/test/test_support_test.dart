import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'pumpUntilCondition bounds its real-clock wait',
    (tester) async {
      Object? failure;
      try {
        await pumpUntilCondition(
          tester,
          () => false,
          reason: 'stalled real-clock probe',
          timeout: const Duration(milliseconds: 20),
          step: const Duration(hours: 1),
        );
      } on Object catch (error) {
        failure = error;
      }

      expect(
        failure,
        isA<TestFailure>().having(
          (error) => error.message,
          'message',
          contains('stalled real-clock probe'),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 5)),
  );

  testWidgets('pumpUntilCondition can flush before its first check', (
    tester,
  ) async {
    var frameDrawn = false;
    tester.binding.scheduleFrame();
    tester.binding.addPostFrameCallback((_) => frameDrawn = true);
    final fakeTime = tester.binding.clock.now();

    await pumpUntilCondition(
      tester,
      () => true,
      pumpBeforeChecking: true,
      frame: null,
    );

    expect(frameDrawn, isTrue);
    expect(tester.binding.clock.now(), fakeTime);
  });
}
