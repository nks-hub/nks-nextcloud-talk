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
  test('a replacement signed by nobody in particular is refused', () async {
    if (!Platform.isMacOS) {
      return;
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    Future<Directory> signedBundle(String name) async {
      final bundle = Directory('${root.path}/$name.app');
      await Directory('${bundle.path}/Contents/MacOS').create(recursive: true);
      await File(
        '${bundle.path}/Contents/MacOS/nextcloudtalk',
      ).writeAsString('#!/bin/sh\n');
      // codesign refuses anything it cannot read as a bundle.
      await File('${bundle.path}/Contents/Info.plist').writeAsString(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        '<key>CFBundleExecutable</key><string>nextcloudtalk</string>\n'
        '<key>CFBundleIdentifier</key><string>test.nkstalk</string>\n'
        '<key>CFBundlePackageType</key><string>APPL</string>\n'
        '<key>CFBundleName</key><string>nextcloudtalk</string>\n'
        '<key>CFBundleVersion</key><string>1</string>\n'
        '</dict></plist>\n',
      );
      // Ad-hoc: a real signature, but one that names no team at all.
      final signed = await Process.run('/usr/bin/codesign', <String>[
        '--force',
        '--sign',
        '-',
        bundle.path,
      ]);
      expect(signed.exitCode, 0, reason: signed.stderr.toString());
      return bundle;
    }

    final install = await signedBundle('installed');
    final replacement = await signedBundle('make/nextcloudtalk');
    final archive = File('${root.path}/release.zip');
    final zipped = await Process.run('/usr/bin/ditto', <String>[
      '-c',
      '-k',
      '--sequesterRsrc',
      '--keepParent',
      replacement.path,
      archive.path,
    ]);
    expect(zipped.exitCode, 0, reason: zipped.stderr.toString());

    final harness = service(install);

    expect(
      await harness.service.runInstaller(UpdateInstallReady(archive)),
      isFalse,
      reason: 'a signature naming no team proves nothing about who made it',
    );
    expect(harness.quits, isEmpty);
  });

  test('a staging directory a killed run left behind is cleared', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final install = await installed('old');
    // What a process killed between unpacking and the swap leaves behind.
    final stale = Directory('${install.parent.path}/.nks-talk-update-stale');
    await Directory('${stale.path}/bundle').create(recursive: true);
    await File('${stale.path}/bundle/big').writeAsString('a whole build');
    // Something else living beside the build must be left exactly alone.
    final neighbour = Directory('${install.parent.path}/keep-me');
    await neighbour.create(recursive: true);

    final archive = await linuxArchive();
    final harness = service(install);

    expect(
      await harness.service.runInstaller(UpdateInstallReady(archive)),
      isTrue,
    );

    expect(stale.existsSync(), isFalse, reason: 'the leftover has to go');
    expect(neighbour.existsSync(), isTrue, reason: 'and nothing else may');
  });

}
