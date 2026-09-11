@TestOn('posix')
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/update_installer_service.dart';

/// Installing on macOS and Linux, end to end against a real archive.
///
/// The download and its checksum are covered elsewhere; what these prove is
/// the half that touches an existing installation — that a correctly shaped
/// archive really does end up in its place, and that a wrongly shaped one is
/// refused before anything is moved.
///
/// Windows never comes through here, so this file sits that platform out.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nks-install-test-');
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  /// A stand-in for the build already installed, holding a file that says so.
  Future<Directory> installed(String marker) async {
    final directory = Directory('${root.path}/installed');
    await directory.create(recursive: true);
    await File('${directory.path}/version.txt').writeAsString(marker);
    await File('${directory.path}/nextcloudtalk').writeAsString('#!/bin/sh\n');
    return directory;
  }

  /// A `.tar.gz` shaped exactly like the Linux release asset: one top-level
  /// `bundle` directory with the executable inside it.
  Future<File> linuxArchive({
    String marker = 'new',
    String rootName = 'bundle',
    bool withExecutable = true,
  }) async {
    final staging = Directory('${root.path}/make/$rootName');
    await staging.create(recursive: true);
    await File('${staging.path}/version.txt').writeAsString(marker);
    if (withExecutable) {
      await File('${staging.path}/nextcloudtalk').writeAsString('#!/bin/sh\n');
    }
    final archive = File('${root.path}/release.tar.gz');
    final result = await Process.run('/usr/bin/env', <String>[
      'tar',
      '-czf',
      archive.path,
      '-C',
      '${root.path}/make',
      rootName,
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return archive;
  }

  ({UpdateInstallerService service, List<String> quits}) service(
    Directory? install,
  ) {
    final quits = <String>[];
    final built = UpdateInstallerService(
      exitDelay: const Duration(milliseconds: 10),
      quit: () => quits.add('quit'),
      bundleDirectory: () => install,
    );
    addTearDown(built.close);
    return (service: built, quits: quits);
  }

  test('a Linux release replaces the build that is installed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final install = await installed('old');
    final archive = await linuxArchive();
    final harness = service(install);

    final started = await harness.service.runInstaller(
      UpdateInstallReady(archive),
    );

    expect(started, isTrue);
    // The script waits for this process, which is not going to exit, so the
    // swap itself is proven in update_bundle_swap_script_test.dart. What is
    // proven here is that the archive was accepted, unpacked and handed over.
    expect(
      install.parent.listSync().whereType<Directory>().map(
        (entry) => entry.path.split('/').last,
      ),
      contains(startsWith('.nks-talk-update-')),
      reason: 'the replacement should be staged beside the installation',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(harness.quits, <String>['quit'], reason: 'it has to make way');
  });

  test('an archive that is not shaped like a release is refused', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final install = await installed('old');
    final archive = await linuxArchive(rootName: 'something-else');
    final harness = service(install);

    final started = await harness.service.runInstaller(
      UpdateInstallReady(archive),
    );

    expect(started, isFalse);
    expect(
      await File('${install.path}/version.txt').readAsString(),
      'old',
      reason: 'nothing may be touched when the archive is not ours',
    );
    expect(harness.quits, isEmpty, reason: 'and it must not quit either');
  });

  test('an archive missing the executable is refused', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final install = await installed('old');
    final archive = await linuxArchive(withExecutable: false);
    final harness = service(install);

    expect(
      await harness.service.runInstaller(UpdateInstallReady(archive)),
      isFalse,
    );
    expect(await File('${install.path}/version.txt').readAsString(), 'old');
    expect(harness.quits, isEmpty);
  });

  test('a build whose location cannot be worked out installs nothing',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final archive = await linuxArchive();
    final harness = service(null);

    expect(
      await harness.service.runInstaller(UpdateInstallReady(archive)),
      isFalse,
    );
    expect(harness.quits, isEmpty);
  });

  test('a macOS bundle nobody signed is refused', () async {
    if (!Platform.isMacOS) {
      // The check runs `codesign`, which only exists here.
      return;
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final install = Directory('${root.path}/NKS Talk.app');
    await Directory('${install.path}/Contents/MacOS').create(recursive: true);

    final staging = Directory('${root.path}/make/nextcloudtalk.app');
    await Directory('${staging.path}/Contents/MacOS').create(recursive: true);
    await File(
      '${staging.path}/Contents/MacOS/nextcloudtalk',
    ).writeAsString('#!/bin/sh\n');
    final archive = File('${root.path}/release.zip');
    final zipped = await Process.run('/usr/bin/ditto', <String>[
      '-c',
      '-k',
      '--sequesterRsrc',
      '--keepParent',
      staging.path,
      archive.path,
    ]);
    expect(zipped.exitCode, 0, reason: zipped.stderr.toString());

    final harness = service(install);

    expect(
      await harness.service.runInstaller(UpdateInstallReady(archive)),
      isFalse,
      reason: 'an unsigned bundle must never replace a signed one',
    );
    expect(harness.quits, isEmpty);
  });
}
