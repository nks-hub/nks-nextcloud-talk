import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('profile VM cannot enable debug HTTP', () async {
    final packageRoot = Directory.current.absolute;
    final probe = File(
      '${packageRoot.path}/test/support/server_origin_policy_probe.dart',
    );
    expect(probe.existsSync(), isTrue);

    final execution = await Process.run(Platform.resolvedExecutable, [
      'run',
      '--define=dart.vm.profile=true',
      probe.path,
    ], workingDirectory: packageRoot.path);
    expect(
      execution.exitCode,
      0,
      reason: '${execution.stdout}\n${execution.stderr}',
    );
  });

  test('release executable cannot enable debug HTTP', () async {
    final packageRoot = Directory.current.absolute;
    final probe = File(
      '${packageRoot.path}/test/support/server_origin_policy_probe.dart',
    );
    expect(probe.existsSync(), isTrue);

    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'talk_protocol_policy_',
    );
    try {
      final executable = File(
        '${temporaryDirectory.path}/server_origin_policy_probe'
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
