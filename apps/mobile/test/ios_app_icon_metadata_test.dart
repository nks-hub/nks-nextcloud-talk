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
