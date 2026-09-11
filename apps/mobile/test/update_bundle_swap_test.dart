import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/update_bundle_swap.dart';

/// Where a build lives and how its path survives the shell. The script that
/// uses both is run for real in `update_bundle_swap_script_test.dart`, which
/// needs a shell and so cannot run on Windows; these can and do.
void main() {
  group('the directory a build occupies', () {
    test('on Linux is the one holding the executable', () {
      final found = runningBundleDirectory(
        executablePath: '/opt/nks-talk/bundle/nextcloudtalk',
        platform: TargetPlatform.linux,
      );

      expect(found?.path, '/opt/nks-talk/bundle');
    });

    test('on macOS is the bundle, three levels above the executable', () {
      final found = runningBundleDirectory(
        executablePath:
            '/Applications/NKS Talk.app/Contents/MacOS/nextcloudtalk',
        platform: TargetPlatform.macOS,
      );

      expect(found?.path, '/Applications/NKS Talk.app');
    });

    test('on macOS is nothing when the layout is not a bundle', () {
      // What a build run straight out of a development tree looks like.
      expect(
        runningBundleDirectory(
          executablePath: '/work/build/macos/Release/nextcloudtalk',
          platform: TargetPlatform.macOS,
        ),
        isNull,
      );
    });

    test('is nothing on a platform that never swaps', () {
      for (final platform in const [
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        expect(
          runningBundleDirectory(
            executablePath: '/somewhere/nextcloudtalk',
            platform: platform,
          ),
          isNull,
          reason: '$platform',
        );
      }
    });
  });

  group('quoting', () {
    test('carries a path with a space through the shell', () {
      expect(shellQuote('/Applications/NKS Talk.app'), "'/Applications/NKS Talk.app'");
    });

    test('carries a path holding a single quote', () {
      expect(shellQuote("/opt/o'brien/app"), r"'/opt/o'\''brien/app'");
    });
  });
}
