import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The iOS push surface is native, so what a Dart test can hold onto is the
/// project configuration it depends on. Without these the app builds and runs
/// and simply never asks for permission, which is exactly how the gap went
/// unnoticed until a user reported it.
void main() {
  final iosRoot =
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}';
  final ios = '${iosRoot}Runner';

  test('the iOS target declares the push entitlement', () {
    final entitlements = File(
      '$ios${Platform.pathSeparator}Runner.entitlements',
    );
    expect(entitlements.existsSync(), isTrue);
    final contents = entitlements.readAsStringSync();
    final key = contents.indexOf('<key>aps-environment</key>');
    expect(key, isNonNegative, reason: 'APNs needs aps-environment');
    expect(
      contents.substring(key),
      contains(r'<string>$(APS_ENVIRONMENT)</string>'),
      reason: 'the entitlement must follow the active build configuration',
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
    expect(
      'APS_ENVIRONMENT = development;'.allMatches(project).length,
      1,
      reason: 'only Debug uses the APNs sandbox',
    );
    expect(
      'APS_ENVIRONMENT = production;'.allMatches(project).length,
      2,
      reason: 'Profile and Release must use production APNs',
    );
  });

  test('the iOS app embeds CocoaPods frameworks', () {
    expect(File('${iosRoot}Podfile').existsSync(), isTrue);
    expect(File('${iosRoot}Podfile.lock').existsSync(), isTrue);
    final project = File(
      '${iosRoot}Runner.xcodeproj${Platform.pathSeparator}project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('[CP] Embed Pods Frameworks'));
    expect(project, contains('Pods_Runner.framework in Frameworks'));
  });

  test('the app delegate asks for permission and registers with APNs', () {
    final delegate = File(
      '$ios${Platform.pathSeparator}AppDelegate.swift',
    ).readAsStringSync();
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
      RegExp(
        '/\\* ${RegExp.escape(fileName)} in Sources \\*/,',
      ).hasMatch(project),
      isTrue,
      reason:
          '$fileName is not listed in the Sources build phase, so Xcode '
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
    expectCompiled(project, 'PushEnvelopeDecryptor.swift');
    expectCompiled(project, 'PushNotificationRouteStore.swift');
    expectCompiled(project, 'CallPushKit.swift');
  });

  test('the app can be woken by a call and keep its audio in the background',
      () {
    // PushKit refuses to hand out a VoIP token to an app that does not
    // declare the `voip` background mode, so without it the proxy never
    // learns a PushKit token and a call simply never rings. `audio` is what
    // lets a joined call keep running once the user leaves the app.
    final info = File(
      '$ios${Platform.pathSeparator}Info.plist',
    ).readAsStringSync();
    final key = info.indexOf('<key>UIBackgroundModes</key>');
    expect(key, isNonNegative);
    final modes = info.substring(key, info.indexOf('</array>', key));
    expect(modes, contains('<string>voip</string>'));
    expect(modes, contains('<string>audio</string>'));
  });

  test('the app delegate builds the CallKit bridge before Flutter exists', () {
    // A VoIP push reaches a terminated app, and iOS requires the incoming
    // call to be reported from inside that delivery. Building the bridge
    // with the Flutter engine instead would miss exactly the case PushKit
    // exists for.
    final delegate = File(
      '$ios${Platform.pathSeparator}AppDelegate.swift',
    ).readAsStringSync();
    expect(delegate, contains('let callPushKit = CallPushKit()'));
    expect(delegate, contains('callPushKit.attach(messenger:'));
  });

  test('PushNotificationRouteStore.swift is compiled into both the Runner and '
      'NotificationServiceExtension targets, since both processes use it', () {
    final projectFile = File(
      '${Directory.current.path}${Platform.pathSeparator}ios'
      '${Platform.pathSeparator}Runner.xcodeproj'
      '${Platform.pathSeparator}project.pbxproj',
    );
    final project = projectFile.readAsStringSync();

    final sourcesEntries = RegExp(
      '/\\* PushNotificationRouteStore\\.swift in Sources \\*/,',
    ).allMatches(project).length;
    expect(
      sourcesEntries,
      2,
      reason:
          'PushNotificationRouteStore.swift must be listed in exactly two '
          'Sources build phases (Runner and NotificationServiceExtension), '
          'found $sourcesEntries',
    );
  });

  test('device keys and routes use Keychain, not the share App Group', () {
    final entitlements = File(
      '$ios${Platform.pathSeparator}Runner.entitlements',
    ).readAsStringSync();
    for (final needle in const ['keychain-access-groups']) {
      expect(
        entitlements.contains(needle),
        isTrue,
        reason: 'Runner.entitlements is missing $needle',
      );
    }
    // The App Group exists for the share extension inbox only. Push keys and
    // routes stay in the Keychain access group, which the checks below pin.
    expect(
      entitlements,
      contains('<string>group.com.nkshub.nextcloudtalk</string>'),
      reason: 'the share extension hands its inbox over through this group',
    );
    final keyStoreSource = File(
      '$ios${Platform.pathSeparator}PushDeviceKeyStore.swift',
    ).readAsStringSync();
    expect(keyStoreSource, isNot(contains('group.com.nkshub.nextcloudtalk')));

    final keyStore = File(
      '$ios${Platform.pathSeparator}PushDeviceKeyStore.swift',
    ).readAsStringSync();
    expect(
      keyStore.contains('kSecAttrAccessGroup') &&
          keyStore.contains('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly'),
      isTrue,
      reason:
          'PushDeviceKeyStore must pin its keys to the shared Keychain access '
          'group, or a Notification Service Extension can never see them',
    );

    final routeStore = File(
      '$ios${Platform.pathSeparator}PushNotificationRouteStore.swift',
    ).readAsStringSync();
    expect(routeStore, contains('kSecClassGenericPassword'));
    expect(
      routeStore,
      contains('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly'),
    );
    expect(routeStore, isNot(contains('pushNotificationRoutes')));
    expect(routeStore, isNot(contains('group.com.nkshub.nextcloudtalk')));
    expect(
      routeStore,
      isNot(contains('defaults?.set(')),
      reason: 'room tokens must never be written back to an App Group plist',
    );

    final service = File(
      '$ios${Platform.pathSeparator}..${Platform.pathSeparator}'
      'NotificationServiceExtension${Platform.pathSeparator}'
      'NotificationService.swift',
    ).readAsStringSync();
    expect(service, contains('PushNotificationRouteStore.production.remember'));
    expect(service, isNot(contains('content.userInfo["accountId"]')));
    expect(service, isNot(contains('content.userInfo["roomToken"]')));
  });
}
