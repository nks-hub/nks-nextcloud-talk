import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// App Store Connect rejects an iOS upload whose `Info.plist` has no
/// `CFBundleIconName`, and it does so only after `altool` has already reported
/// a successful upload — the build simply never appears in TestFlight. That
/// happened once here, so the key is asserted rather than trusted.
void main() {
  test('iOS Info.plist carries every purpose string the plugins need', () {
    final contents = _plist().readAsStringSync();
    // App Store Connect rejected two uploads with `90683: Missing purpose
    // string` for exactly one absent key, and only after altool had already
    // reported success. Every sensitive API the bundled plugins touch is
    // listed here so the next gap is a failing test, not a failed upload.
    const required = <String>[
      // image_picker, camera source
      'NSCameraUsageDescription',
      // record, voice messages
      'NSMicrophoneUsageDescription',
      // image_picker, picking an existing picture
      'NSPhotoLibraryUsageDescription',
      // gal, saving an attachment to the library
      'NSPhotoLibraryAddUsageDescription',
    ];
    for (final key in required) {
      final at = contents.indexOf('<key>$key</key>');
      expect(at, isNonNegative, reason: '$key is missing');
      final value = contents.substring(at);
      expect(
        RegExp(r'<string>\s*\S[^<]*</string>').firstMatch(value)?.start,
        isNotNull,
        reason: '$key needs a non-empty user-facing explanation',
      );
    }
  });

  test('iOS Info.plist answers the export compliance question up front', () {
    // Without this key every upload lands in TestFlight as "Missing
    // Compliance" and cannot be handed to a tester until somebody answers the
    // encryption question by hand. The iOS build only talks HTTPS and uses the
    // system keychain, both exempt, so the answer is a standing false.
    final contents = _plist().readAsStringSync();
    final at = contents.indexOf('<key>ITSAppUsesNonExemptEncryption</key>');
    expect(at, isNonNegative, reason: 'export compliance must be declared');
    expect(
      contents.substring(at, at + 120).contains('<false/>'),
      isTrue,
      reason: 'the iOS build carries no non-exempt encryption',
    );
  });

  test('the iOS deployment target meets the App Store floor', () {
    // Apple warns with `ITMS-90068 MinimumOSVersion too low` below 15.0 and
    // stops accepting such uploads in spring 2027, so the floor is asserted
    // rather than left to whoever next regenerates the project.
    final project = File(
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner.xcodeproj'
      '${Platform.pathSeparator}project.pbxproj',
    );
    final targets = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);')
        .allMatches(project.readAsStringSync())
        .map((match) => double.parse(match.group(1)!))
        .toList(growable: false);
    expect(targets, isNotEmpty);
    for (final target in targets) {
      expect(target, greaterThanOrEqualTo(15.0));
    }
  });

  test('iOS Info.plist names the asset catalog app icon', () {
    final plist = _plist();
    expect(plist.existsSync(), isTrue);

    final contents = plist.readAsStringSync();
    final iconKey = contents.indexOf('<key>CFBundleIconName</key>');
    expect(
      iconKey,
      isNonNegative,
      reason: 'CFBundleIconName is required for App Store Connect ingestion',
    );
    expect(
      contents.substring(iconKey).contains('<string>AppIcon</string>'),
      isTrue,
      reason: 'CFBundleIconName must name the AppIcon asset catalog entry',
    );

    final iconSet = Directory(
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner${Platform.pathSeparator}Assets.xcassets'
      '${Platform.pathSeparator}AppIcon.appiconset',
    );
    expect(
      iconSet.existsSync(),
      isTrue,
      reason: 'the named asset catalog entry has to exist',
    );
    expect(
      iconSet
          .listSync()
          .whereType<File>()
          .any((file) => file.path.endsWith('1024x1024@1x.png')),
      isTrue,
      reason: 'App Store submission needs the 1024 marketing icon',
    );
  });
}

File _plist() => File(
  '${Directory.current.path}${Platform.pathSeparator}ios'
  '${Platform.pathSeparator}Runner${Platform.pathSeparator}Info.plist',
);
