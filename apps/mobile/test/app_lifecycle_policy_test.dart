import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_lifecycle_policy.dart';

void main() {
  test('desktop keeps live sync while inactive or hidden', () {
    for (final platform in const <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      expect(
        shouldRunForegroundSync(
          AppLifecycleState.inactive,
          targetPlatform: platform,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        shouldRunForegroundSync(
          AppLifecycleState.hidden,
          targetPlatform: platform,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        shouldRunForegroundSync(
          AppLifecycleState.paused,
          targetPlatform: platform,
          isWeb: false,
        ),
        isFalse,
      );
    }
  });

  test('mobile and web require the resumed state', () {
    for (final platform in const <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      expect(
        shouldRunForegroundSync(
          AppLifecycleState.hidden,
          targetPlatform: platform,
          isWeb: false,
        ),
        isFalse,
      );
      expect(
        shouldRunForegroundSync(
          AppLifecycleState.resumed,
          targetPlatform: platform,
          isWeb: false,
        ),
        isTrue,
      );
    }
    expect(
      shouldRunForegroundSync(
        AppLifecycleState.inactive,
        targetPlatform: TargetPlatform.windows,
        isWeb: true,
      ),
      isFalse,
    );
  });
}
