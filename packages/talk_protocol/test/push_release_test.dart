import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('push runtime executes as a release AOT executable', () async {
    final packageRoot = Directory.current.absolute;
    final probe = File(
      '${packageRoot.path}/test/support/push_release_probe.dart',
    );
    expect(probe.existsSync(), isTrue);

    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'talk_protocol_push_',
    );
    try {
      final executable = File(
        '${temporaryDirectory.path}/push_release_probe'
        '${Platform.isWindows ? '.exe' : ''}',
      );
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        probe.path,
        '-o',
        executable.path,
      ], workingDirectory: packageRoot.path);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout}\n${compilation.stderr}',
      );

      final execution = await Process.run(executable.path, const []);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}\n${execution.stderr}',
      );
    } finally {
      await temporaryDirectory.delete(recursive: true);
    }
  });
}
