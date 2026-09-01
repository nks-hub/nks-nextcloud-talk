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
    },
    timeout: const Timeout(Duration(minutes: 2)),
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
