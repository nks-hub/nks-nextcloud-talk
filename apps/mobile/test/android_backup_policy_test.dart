import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'source and merged Android manifests keep application policies',
    () async {
      final project = Directory.current;
      final android = Directory(
        '${project.path}${Platform.pathSeparator}android',
      );
      final sourceManifest = File(
        '${android.path}${Platform.pathSeparator}app${Platform.pathSeparator}'
        'src${Platform.pathSeparator}main${Platform.pathSeparator}'
        'AndroidManifest.xml',
      );
      _expectBackupDisabled(sourceManifest);
      _expectPredictiveBackEnabled(sourceManifest);
      _expectCallPictureInPicture(sourceManifest);
      _expectScreenShareService(sourceManifest);

      final wrapper = File(
        '${android.path}${Platform.pathSeparator}'
        '${Platform.isWindows ? 'gradlew.bat' : 'gradlew'}',
      );
      final gradleArguments = <String>[
        if (!Platform.isWindows) wrapper.path,
        ':app:processDebugMainManifest',
        '--quiet',
      ];
      final result = await Process.run(
        // `bash`, not `sh`: the committed wrapper declares a bash shebang and
        // uses bash arrays, so a POSIX shell dies on it at line 154. Windows
        // and this machine never noticed — Linux CI did.
        Platform.isWindows ? wrapper.path : 'bash',
        gradleArguments,
        workingDirectory: android.path,
      );
      expect(
        result.exitCode,
        0,
        reason: 'Android manifest merge failed: ${result.stderr}',
      );

      final mergedManifest = File(
        '${project.path}${Platform.pathSeparator}build${Platform.pathSeparator}'
        'app${Platform.pathSeparator}intermediates${Platform.pathSeparator}'
        'merged_manifest${Platform.pathSeparator}debug${Platform.pathSeparator}'
        'processDebugMainManifest${Platform.pathSeparator}AndroidManifest.xml',
      );
      _expectBackupDisabled(mergedManifest);
      _expectPredictiveBackEnabled(mergedManifest);
      _expectCallPictureInPicture(mergedManifest);
      _expectScreenShareService(mergedManifest);
    },
    // Ten, not two: this is the only test that runs Gradle, and on a fresh CI
    // machine that first invocation downloads the wrapper, AGP and Kotlin
    // before it merges anything. Two minutes is a warm-cache budget and timed
    // out on both the Ubuntu and the Windows runner.
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

void _expectPredictiveBackEnabled(File manifest) {
  expect(manifest.existsSync(), isTrue, reason: '${manifest.path} is missing');
  final application = RegExp(
    r'<application\b[\s\S]*?>',
  ).firstMatch(manifest.readAsStringSync())?.group(0);
  expect(application, isNotNull, reason: 'Application element is missing');
  expect(
    application,
    contains('android:enableOnBackInvokedCallback="true"'),
    reason: '${manifest.path} must opt into Android predictive back',
  );
}

void _expectBackupDisabled(File manifest) {
  expect(manifest.existsSync(), isTrue, reason: '${manifest.path} is missing');
  final application = RegExp(
    r'<application\b[\s\S]*?>',
  ).firstMatch(manifest.readAsStringSync())?.group(0);
  expect(application, isNotNull, reason: 'Application element is missing');
  expect(
    application,
    contains('android:allowBackup="false"'),
    reason: '${manifest.path} must disable backup explicitly',
  );
}

/// The launcher activity must allow the small window a call shrinks into,
/// and it must survive the size change without being recreated — otherwise
/// the Flutter engine, and with it the call, restarts on the way in.
void _expectCallPictureInPicture(File manifest) {
  final activity = RegExp(
    r'<activity\s[^>]*AndroidWebPushActivity[^>]*>',
  ).firstMatch(manifest.readAsStringSync())?.group(0);
  expect(activity, isNotNull, reason: 'Launcher activity is missing');
  expect(
    activity,
    contains('android:supportsPictureInPicture="true"'),
    reason: '${manifest.path} must allow picture-in-picture for calls',
  );
  for (final change in ['screenSize', 'smallestScreenSize', 'screenLayout']) {
    expect(
      activity,
      contains(change),
      reason: '${manifest.path} must handle $change without a restart',
    );
  }
}

/// Android 10+ grants a screen capture only to a running foreground service of
/// type mediaProjection, and Android 14 wants the matching permission for it;
/// without either the share dies with a SecurityException that takes the app
/// down (measured on the Android 14 emulator on 5 September 2026).
void _expectScreenShareService(File manifest) {
  final text = manifest.readAsStringSync();
  final service = RegExp(
    r'<service\s[^>]*ScreenShareService[^>]*>',
  ).firstMatch(text)?.group(0);
  expect(service, isNotNull, reason: 'ScreenShareService is missing');
  expect(
    service,
    contains('android:foregroundServiceType="mediaProjection"'),
    reason: '${manifest.path} must type the screen share service',
  );
  expect(
    text,
    contains('android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION'),
    reason: '${manifest.path} must declare the media projection permission',
  );
}
