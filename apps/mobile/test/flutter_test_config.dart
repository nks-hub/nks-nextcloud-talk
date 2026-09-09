import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Runs once per test file, before the tests in it.
///
/// A tap that lands on nothing is only a warning by default, so a test that
/// taps a row below the test surface goes on to wait for something that will
/// never happen and then fails as a timeout, pointing at the wrong cause. That
/// cost two workers an afternoon on 9 September 2026. Here a missed hit test is
/// an error where it happens.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await testMain();
}
