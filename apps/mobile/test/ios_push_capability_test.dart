import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The iOS push surface is native, so what a Dart test can hold onto is the
/// project configuration it depends on. Without these the app builds and runs
/// and simply never asks for permission, which is exactly how the gap went
/// unnoticed until a user reported it.
void main() {
  final ios =
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner';

  test('the iOS target declares the push entitlement', () {
    final entitlements = File('$ios${Platform.pathSeparator}Runner.entitlements');
    expect(entitlements.existsSync(), isTrue);
    final contents = entitlements.readAsStringSync();
    final key = contents.indexOf('<key>aps-environment</key>');
    expect(key, isNonNegative, reason: 'APNs needs aps-environment');
    expect(
      contents.substring(key).contains('<string>development</string>') ||
          contents.substring(key).contains('<string>production</string>'),
      isTrue,
    );

    final project = File(
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner.xcodeproj'
      '${Platform.pathSeparator}project.pbxproj',
    ).readAsStringSync();
    expect(
      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'
          .allMatches(project)
          .length,
      3,
      reason: 'every configuration has to sign with the entitlement',
    );
  });

  test('the app delegate asks for permission and registers with APNs', () {
    final delegate =
        File('$ios${Platform.pathSeparator}AppDelegate.swift').readAsStringSync();
    for (final needle in const [
      'UNUserNotificationCenter.current().requestAuthorization',
      'UIApplication.shared.registerForRemoteNotifications()',
      'didRegisterForRemoteNotificationsWithDeviceToken',
      'com.nkshub.nextcloudtalk/apple_push',
      'generateDeviceKey',
      'destroyDeviceKey',
    ]) {
      expect(
        delegate.contains(needle),
        isTrue,
        reason: 'AppDelegate is missing $needle',
      );
    }
  });

  // A Swift file that exists on disk but was never added to the Xcode
  // project's Sources build phase compiles nothing: Xcode simply never
  // sees it, and referencing its type fails with "Cannot find '<Type>' in
  // scope" the moment anything tries to build it. `flutter analyze` cannot
  // catch this — Dart has no idea Xcode exists — so this has to be read out
  // of the project file directly.
  void expectCompiled(String project, String fileName) {
    expect(
      RegExp(
        'PBXBuildFile;\\s*fileRef = [0-9A-F]{24} /\\* '
        '${RegExp.escape(fileName)} \\*/',
      ).hasMatch(project),
      isTrue,
      reason: '$fileName has no PBXBuildFile entry, so Xcode never compiles it',
    );
    expect(
      RegExp('/\\* ${RegExp.escape(fileName)} in Sources \\*/,').hasMatch(project),
      isTrue,
      reason: '$fileName is not listed in the Sources build phase, so Xcode '
          'never compiles it',
    );
  }

  test('ApplePushDelivery.swift and PushDeviceKeyStore.swift are compiled '
      'into the Runner target', () {
    final projectFile = File(
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner.xcodeproj'
      '${Platform.pathSeparator}project.pbxproj',
    );
    expect(projectFile.existsSync(), isTrue);
    final project = projectFile.readAsStringSync();

    expectCompiled(project, 'ApplePushDelivery.swift');
    expectCompiled(project, 'PushDeviceKeyStore.swift');
  });
}
