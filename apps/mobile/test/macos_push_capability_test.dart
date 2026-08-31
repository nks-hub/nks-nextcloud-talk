import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final separator = Platform.pathSeparator;
  final macos = '$root${separator}macos';
  final runner = '$macos${separator}Runner';

  String read(String path) => File(path).readAsStringSync();

  test('macOS Runner entitlements allow APNs and Keychain sharing', () {
    for (final name in const [
      'DebugProfile.entitlements',
      'Release.entitlements',
    ]) {
      final contents = read('$runner$separator$name');
      for (final needle in const [
        '<key>com.apple.developer.aps-environment</key>',
        r'<string>$(APS_ENVIRONMENT)</string>',
        'keychain-access-groups',
      ]) {
        expect(contents, contains(needle), reason: '$name is missing $needle');
      }
      expect(
        contents,
        isNot(contains('<key>aps-environment</key>')),
        reason: 'the unprefixed entitlement is valid on iOS, not macOS',
      );
    }

    final project = read(
      '$macos${separator}Runner.xcodeproj${separator}project.pbxproj',
    );
    expect('APS_ENVIRONMENT = development;'.allMatches(project).length, 1);
    expect('APS_ENVIRONMENT = production;'.allMatches(project).length, 2);
    expect(
      project,
      isNot(contains('CODE_SIGN_IDENTITY = "-";')),
      reason: 'restricted APNs entitlements cannot use an ad-hoc signature',
    );
    expect(
      'DEVELOPMENT_TEAM = TEAMID0000;'.allMatches(project).length,
      6,
      reason: 'Runner and its extension must be signed by the same team',
    );
  });

  test('the macOS Podfile supports every native plugin', () {
    final podfile = read('$macos${separator}Podfile');
    expect(podfile, contains("platform :osx, '11.0'"));
    expect(
      File('$macos${separator}Podfile.lock').existsSync(),
      isTrue,
      reason: 'macOS dependency versions must be reproducible',
    );

    final project = read(
      '$macos${separator}Runner.xcodeproj${separator}project.pbxproj',
    );
    expect(project, contains('[CP] Embed Pods Frameworks'));
    expect(project, contains('Pods_Runner.framework in Frameworks'));
  });

  test('macOS location access is foreground and sandbox scoped', () {
    final info = read('$runner${separator}Info.plist');
    expect(info, contains('<key>NSLocationUsageDescription</key>'));
    for (final name in const [
      'DebugProfile.entitlements',
      'Release.entitlements',
    ]) {
      final contents = read('$runner$separator$name');
      expect(
        contents,
        contains('<key>com.apple.security.personal-information.location</key>'),
        reason: '$name is missing the location sandbox entitlement',
      );
    }
    final podfile = File('$macos${separator}Podfile');
    final lock = read('$macos${separator}Podfile.lock');
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

  test(
    'macOS AppDelegate registers with APNs and exposes the push channel',
    () {
      final delegate = read('$runner${separator}AppDelegate.swift');
      for (final needle in const [
        'UNUserNotificationCenter.current().requestAuthorization',
        'NSApplication.shared.registerForRemoteNotifications()',
        'didRegisterForRemoteNotificationsWithDeviceToken',
        'com.nkshub.nextcloudtalk/apple_push',
        'generateDeviceKey',
        'recordDeviceKeyAccount',
        'getLaunchNotificationOpen',
        'notificationAction',
      ]) {
        expect(
          delegate,
          contains(needle),
          reason: 'AppDelegate is missing $needle',
        );
      }

      final window = read('$runner${separator}MainFlutterWindow.swift');
      expect(window, contains('configurePushChannel'));
    },
  );

  test('macOS embeds a real Notification Service Extension', () {
    final extension =
        '$macos${separator}NotificationServiceExtension$separator';
    final info = read('${extension}Info.plist');
    expect(info, contains('com.apple.usernotifications.service'));
    expect(info, contains('NSExtensionService_Subsystem'));

    final entitlements = read(
      '${extension}NotificationServiceExtension.entitlements',
    );
    for (final needle in const [
      'com.apple.security.app-sandbox',
      'keychain-access-groups',
    ]) {
      expect(entitlements, contains(needle));
    }

    final project = read(
      '$macos${separator}Runner.xcodeproj${separator}project.pbxproj',
    );
    for (final needle in const [
      'NotificationServiceExtension.appex in Embed App Extensions',
      'PRODUCT_BUNDLE_IDENTIFIER = '
          'com.nkshub.nextcloudtalk.NotificationService;',
      'APPLICATION_EXTENSION_API_ONLY = YES;',
    ]) {
      expect(project, contains(needle), reason: 'project is missing $needle');
    }
    expect(
      RegExp(
        r'isa = PBXNativeTarget;[\s\S]*?name = NotificationServiceExtension;',
      ).hasMatch(project),
      isTrue,
      reason: 'the extension must be a real PBXNativeTarget',
    );
  });

  test('macOS notification extension does not inherit Runner pods', () {
    final config = read(
      '$runner$separator'
      'Configs$separator'
      'NotificationServiceExtension.xcconfig',
    );
    expect(config, contains('Flutter-Generated.xcconfig'));
    expect(config, contains('Warnings.xcconfig'));
    expect(config, contains('OTHER_LDFLAGS ='));
    expect(config, contains('FRAMEWORK_SEARCH_PATHS ='));
    expect(config, isNot(contains('Pods-Runner')));
    expect(config, isNot(contains('Flutter-Release.xcconfig')));
    expect(config, isNot(contains('Flutter-Debug.xcconfig')));

    final project = read(
      '$macos${separator}Runner.xcodeproj${separator}project.pbxproj',
    );
    expect(
      RegExp(
        r'baseConfigurationReference = [^;]+ '
        r'/\* NotificationServiceExtension\.xcconfig \*/;',
      ).allMatches(project).length,
      3,
      reason: 'all three extension configurations need the isolated config',
    );
  });

  test('shared Apple push sources are compiled into the required targets', () {
    final project = read(
      '$macos${separator}Runner.xcodeproj${separator}project.pbxproj',
    );

    int sourceEntries(String fileName) => RegExp(
      '/\\* ${RegExp.escape(fileName)} in Sources \\*/,',
    ).allMatches(project).length;

    expect(sourceEntries('ApplePushDelivery.swift'), 1);
    expect(sourceEntries('NotificationService.swift'), 1);
    expect(sourceEntries('PushDeviceKeyStore.swift'), 2);
    expect(sourceEntries('PushEnvelopeDecryptor.swift'), 2);
    expect(sourceEntries('PushNotificationRouteStore.swift'), 2);
  });

  test('Dart enables Apple push registration on both Apple platforms', () {
    final providers = read(
      '$root${separator}lib${separator}app_providers_push.dart',
    );
    expect(
      RegExp(
        r'^\s*if \(!Platform\.isIOS\s*&&\s*!Platform\.isMacOS',
        multiLine: true,
      ).allMatches(providers).length,
      2,
      reason: 'both Apple push providers must allow macOS',
    );
  });
}
