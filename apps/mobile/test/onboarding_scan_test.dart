import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/onboarding/onboarding_screen.dart';

import 'test_support.dart';

final class _ScannerPushes extends NavigatorObserver {
  int count = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == '/onboarding/qr') {
      count++;
    }
  }
}

void main() {
  testWidgets('a double tap opens one scanner, not two cameras', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final pushes = _ScannerPushes();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      ProviderScope(
        child: localizedTestApp(
          navigatorObservers: [pushes],
          home: const OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Sentry recorded a second scanner pushed on top of the first 108 ms
    // later, while the first was still zooming in. Hit testing during a route
    // transition is not reproducible here, so the button fires directly.
    final scan = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('onboarding-scan-login-code')),
    );
    scan.onPressed!();
    await tester.pump(const Duration(milliseconds: 100));
    scan.onPressed!();
    // The scanner shows a spinner while the camera opens, so it never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(pushes.count, 1);
    debugDefaultTargetPlatformOverride = null;
    await tester.binding.setSurfaceSize(null);
  });
}
