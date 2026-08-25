import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'source and merged Android manifests disable application backup',
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
        Platform.isWindows ? wrapper.path : 'sh',
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
    },
    timeout: const Timeout(Duration(minutes: 2)),
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
