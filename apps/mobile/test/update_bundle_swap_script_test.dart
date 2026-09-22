import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/update_bundle_swap.dart';

/// The swap script is the one piece of this feature that can destroy a
/// working installation, so it is not enough to read it: these run it against
/// real directories and check what is on disk afterwards, including the paths
/// where it has to refuse and put everything back.
///
/// Git Bash runs these shell scenarios on Windows. Native bundle handling
/// still needs a Linux or macOS host.
void main() {
  final shell = Platform.isWindows
      ? r'C:\Program Files\Git\bin\bash.exe'
      : '/bin/sh';
  if (!File(shell).existsSync()) {
    test(
      'bundle swap requires a POSIX shell',
      () {},
      skip: 'Shell unavailable',
    );
    return;
  }
  group('the swap script', () {
    late Directory root;

    setUp(() async {
      final temporary = await Directory.systemTemp.createTemp('nks-swap-test-');
      root = Directory(temporary.path.replaceAll(r'\', '/'));
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    /// A directory standing in for an installed build, with one file whose
    /// contents say which build it is.
    Future<Directory> bundle(String name, String marker) async {
      final directory = Directory('${root.path}/$name');
      await directory.create(recursive: true);
      await File('${directory.path}/version.txt').writeAsString(marker);
      return directory;
    }

    Future<ProcessResult> run(String script) =>
        Process.run(shell, <String>['-c', script]);

    /// A real executable for the script to start, because the script quotes
    /// what it is given as one path — which is the point, so a build living
    /// under a path with a space still starts.
    Future<File> relauncher(File marker) async {
      final script = File('${root.path}/relaunch.sh');
      await script.writeAsString(
        '#!/bin/sh\ntouch ${shellQuote(marker.path.replaceAll(r'\', '/'))}\n',
      );
      await run('chmod +x ${shellQuote(script.path)}');
      return script;
    }

    test(
      'installs the new build and retains the previous working build',
      () async {
        final current = await bundle('current', 'old');
        final staging = await bundle('staging', 'staging');
        final replacement = await bundle('staging/new', 'new');
        final launched = File('${root.path}/launched');
        final relaunch = await relauncher(launched);

        final result = await run(
          buildSwapScript(
            // This process is alive, so a pid that is not tells the script the
            // build it waits for has already gone.
            pid: 999999,
            swap: BundleSwap(
              currentDirectory: current.path,
              newDirectory: replacement.path,
              relaunchExecutable: relaunch.path,
            ),
            stagingDirectory: staging.path,
            useOpen: false,
          ),
        );

        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(
          await File('${current.path}/version.txt').readAsString(),
          'new',
          reason: 'the new build should now be where the old one was',
        );
        expect(
          Directory('${current.path}$bundleBackupSuffix').existsSync(),
          isTrue,
          reason:
              'starting a process does not prove the new application is healthy',
        );
        expect(staging.existsSync(), isFalse);
        // Given a moment, because the relaunch is started in the background.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(launched.existsSync(), isTrue, reason: 'it should start again');
      },
    );

    test(
      'puts the previous build back when the new one cannot be moved',
      () async {
        final current = await bundle('current', 'old');
        final staging = await bundle('staging', 'staging');

        final result = await run(
          buildSwapScript(
            pid: 999999,
            swap: BundleSwap(
              currentDirectory: current.path,
              // Never unpacked, so the move of the replacement fails.
              newDirectory: '${staging.path}/absent',
              relaunchExecutable: '/usr/bin/true',
            ),
            stagingDirectory: staging.path,
            useOpen: false,
          ),
        );

        expect(result.exitCode, isNot(0));
        expect(
          await File('${current.path}/version.txt').readAsString(),
          'old',
          reason: 'a failed swap has to leave the working build in place',
        );
        expect(
          Directory('${current.path}$bundleBackupSuffix').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'restores the previous build when the Linux replacement fails to launch',
      () async {
        final current = await bundle('current', 'old');
        final staging = await bundle('staging', 'staging');
        final replacement = await bundle('staging/new', 'new');
        for (final directory in [current, replacement]) {
          final executable = File('${directory.path}/app');
          await executable.writeAsString(
            directory == current
                ? '#!/bin/sh\nexit 0\n'
                : '#!/bin/sh\nexit 17\n',
          );
          await run('chmod +x ${shellQuote(executable.path)}');
        }
        final result = await run(
          buildSwapScript(
            pid: 999999,
            swap: BundleSwap(
              currentDirectory: current.path,
              newDirectory: replacement.path,
              relaunchExecutable: '${current.path}/app',
            ),
            stagingDirectory: staging.path,
            useOpen: false,
          ),
        );
        expect(result.exitCode, 1);
        expect(await File('${current.path}/version.txt').readAsString(), 'old');
      },
    );

    test(
      'restores the previous bundle when macOS open rejects the replacement',
      () async {
        final current = await bundle('current.app', 'old');
        final staging = await bundle('staging', 'staging');
        final replacement = await bundle('staging/new.app', 'new');
        final script = buildSwapScript(
          pid: 999999,
          swap: BundleSwap(
            currentDirectory: current.path,
            newDirectory: replacement.path,
            relaunchExecutable: current.path,
          ),
          stagingDirectory: staging.path,
          useOpen: true,
        );
        final result = await run('open() { return 1; }\n$script');
        expect(result.exitCode, 1);
        expect(await File('${current.path}/version.txt').readAsString(), 'old');
      },
    );

    test('gives up rather than replacing a build that will not exit', () async {
      final current = await bundle('current', 'old');
      final staging = await bundle('staging', 'staging');
      await bundle('staging/new', 'new');

      final waitScript = buildSwapScript(
        // Our own process, which is not going to exit.
        pid: pid,
        swap: BundleSwap(
          currentDirectory: current.path,
          newDirectory: '${staging.path}/new',
          relaunchExecutable: '/usr/bin/true',
        ),
        stagingDirectory: staging.path,
        useOpen: false,
        waitSeconds: 1,
      );
      final result = await run(
        Platform.isWindows
            ? waitScript.replaceAll('kill -0 $pid', r'kill -0 $$')
            : waitScript,
      );

      expect(result.exitCode, 1);
      expect(await File('${current.path}/version.txt').readAsString(), 'old');
    });

    test('survives a path with a space in it', () async {
      final current = await bundle('NKS Talk.app', 'old');
      final staging = await bundle('staging area', 'staging');
      final replacement = await bundle('staging area/new build', 'new');

      final result = await run(
        buildSwapScript(
          pid: 999999,
          swap: BundleSwap(
            currentDirectory: current.path,
            newDirectory: replacement.path,
            relaunchExecutable: '/usr/bin/true',
          ),
          stagingDirectory: staging.path,
          useOpen: false,
        ),
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(await File('${current.path}/version.txt').readAsString(), 'new');
    });

    test('names the backup after the build it replaces, and nothing else', () {
      final script = buildSwapScript(
        pid: 1,
        swap: const BundleSwap(
          currentDirectory: '/Applications/NKS Talk.app',
          newDirectory: '/Applications/.staging/nextcloudtalk.app',
          relaunchExecutable: '/Applications/NKS Talk.app',
        ),
        stagingDirectory: '/Applications/.staging',
        useOpen: true,
      );

      expect(
        script,
        contains("backup='/Applications/NKS Talk.app$bundleBackupSuffix'"),
      );
      // Every delete in the script is of a path it named itself, guarded by
      // the suffix check above it.
      expect(script, contains('*$bundleBackupSuffix) ;;'));
      expect(script, contains(r'open -n "$relaunch"'));
    });
  });
}
