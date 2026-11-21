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
}
