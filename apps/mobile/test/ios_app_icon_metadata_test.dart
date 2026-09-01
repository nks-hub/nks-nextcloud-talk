import 'dart:io';

import 'package:crypto/crypto.dart';
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
      // geolocator, only while the app is visible
      'NSLocationWhenInUseUsageDescription',
      // local_auth, app-lock authentication
      'NSFaceIDUsageDescription',
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

  test('iOS purpose strings follow the device language', () {
    final runner = Directory(
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner',
    );
    final czech = _localizedInfoPlist(
      File(
        '${runner.path}${Platform.pathSeparator}cs.lproj'
        '${Platform.pathSeparator}InfoPlist.strings',
      ),
    );
    final english = _localizedInfoPlist(
      File(
        '${runner.path}${Platform.pathSeparator}en.lproj'
        '${Platform.pathSeparator}InfoPlist.strings',
      ),
    );

    expect(
      czech['NSLocationWhenInUseUsageDescription'],
      'NKS Talk použije vaši aktuální polohu pouze tehdy, když ji sami sdílíte '
      'v konverzaci.',
    );
    expect(
      english['NSLocationWhenInUseUsageDescription'],
      'NKS Talk uses your current location only when you choose to share it in '
      'a conversation.',
    );
    expect(
      czech['NSFaceIDUsageDescription'],
      'NKS Talk používá Face ID k odemknutí vašich konverzací, když je zapnutý '
      'zámek aplikace.',
    );
    expect(
      english['NSFaceIDUsageDescription'],
      'NKS Talk uses Face ID to unlock your conversations when app lock is '
      'enabled.',
    );

    final project = File(
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner.xcodeproj'
      '${Platform.pathSeparator}project.pbxproj',
    ).readAsStringSync();
    final variant = _pbxObject(
      project,
      'A17C3E9B2F00000000000007',
      'InfoPlist.strings',
    );
    expect(variant, contains('A17C3E9B2F00000000000005 /* cs */'));
    expect(variant, contains('A17C3E9B2F00000000000006 /* en */'));
    expect(variant, contains('isa = PBXVariantGroup'));

    final buildFile = _pbxObject(
      project,
      'A17C3E9B2F00000000000004',
      'InfoPlist.strings in Resources',
    );
    expect(
      buildFile,
      contains('fileRef = A17C3E9B2F00000000000007 /* InfoPlist.strings */'),
    );
    final runnerGroup = _pbxObject(
      project,
      '97C146F01CF9000F007C117D',
      'Runner',
    );
    expect(
      runnerGroup,
      contains('A17C3E9B2F00000000000007 /* InfoPlist.strings */'),
    );
    final resources = _pbxObject(
      project,
      '97C146EC1CF9000F007C117D',
      'Resources',
    );
    expect(
      resources,
      contains('A17C3E9B2F00000000000004 /* InfoPlist.strings in Resources */'),
    );
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

  test('iOS CocoaPods lock contains the location plugin', () {
    final ios = '${Directory.current.path}${Platform.pathSeparator}ios';
    final podfile = File('$ios${Platform.pathSeparator}Podfile');
    final lock = File(
      '$ios${Platform.pathSeparator}Podfile.lock',
    ).readAsStringSync();
    expect(lock, contains('geolocator_apple (1.2.0)'));
    expect(
      lock,
      contains('geolocator_apple: ab36aa0e8b7d7a2d7639b3b4e48308394e8cef5e'),
    );
    expect(
      lock,
      contains('PODFILE CHECKSUM: ${sha1.convert(podfile.readAsBytesSync())}'),
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
      iconSet.listSync().whereType<File>().any(
        (file) => file.path.endsWith('1024x1024@1x.png'),
      ),
      isTrue,
      reason: 'App Store submission needs the 1024 marketing icon',
    );
  });
}

File _plist() => File(
  '${Directory.current.path}${Platform.pathSeparator}ios'
  '${Platform.pathSeparator}Runner${Platform.pathSeparator}Info.plist',
);

String _pbxObject(String project, String id, String comment) {
  final match = RegExp(
    '${RegExp.escape(id)} /\\* ${RegExp.escape(comment)} \\*/ = \\{.*?\\};',
    dotAll: true,
  ).firstMatch(project);
  expect(match, isNotNull, reason: '$comment is not wired into the project');
  return match!.group(0)!;
}

Map<String, String> _localizedInfoPlist(File file) {
  return <String, String>{
    for (final match in RegExp(
      r'^"([^"]+)"\s*=\s*"([^"]*)";$',
      multiLine: true,
    ).allMatches(file.readAsStringSync()))
      match.group(1)!: match.group(2)!,
  };
}
