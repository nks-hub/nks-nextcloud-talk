import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final separator = Platform.pathSeparator;
  final runner = '${Directory.current.path}${separator}ios${separator}Runner';

  test(
    'the iOS target carries no associated domain until the profile does',
    () {
      // The App Store profile predates the entitlement and export refuses an
      // archive that claims it. The custom scheme carries deep links meanwhile;
      // the applinks entry returns together with a regenerated profile.
      final entitlements = File(
        '$runner${separator}Runner.entitlements',
      ).readAsStringSync();

      expect(
        entitlements,
        isNot(contains('<key>com.apple.developer.associated-domains</key>')),
      );
      expect(
        RegExp(r'<string>applinks:[^<]+</string>').hasMatch(entitlements),
        isFalse,
        reason: 'An applinks entry without profile support breaks the export.',
      );
    },
  );

  test('the reference server artifact permits only supported room routes', () {
    final repository = Directory.current.parent.parent;
    final file = File(
      '${repository.path}${separator}deploy${separator}reference-server'
      '${separator}apple-app-site-association',
    );
    final document =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final applinks = document['applinks']! as Map<String, Object?>;
    final details = applinks['details']! as List<Object?>;

    expect(details, hasLength(1));
    final detail = details.single! as Map<String, Object?>;
    expect(detail['appIDs'], <String>['TEAMID0000.com.nkshub.nextcloudtalk']);
    final components = (detail['components']! as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(components.map((component) => component['/']), <String>[
      '/call/*',
      '/index.php/call/*',
    ]);
    expect(
      components.any((component) => component['exclude'] == true),
      isFalse,
    );
  });

  test('scene lifecycle sends browsing activities through one validator', () {
    final sceneDelegate = File(
      '$runner${separator}SceneDelegate.swift',
    ).readAsStringSync();

    expect(
      RegExp(
        r'deepLinks\?\.open\((?:activity|userActivity)\)',
      ).allMatches(sceneDelegate).length,
      2,
      reason: 'Cold and warm Universal Links must use the same validator.',
    );
    expect(
      sceneDelegate,
      isNot(contains('deepLinks?.open(url)')),
      reason: 'SceneDelegate must not bypass NSUserActivity type validation.',
    );
  });

  test('native delivery accepts only HTTPS browsing activities', () {
    final appDelegate = File(
      '$runner${separator}AppDelegate.swift',
    ).readAsStringSync();

    expect(
      appDelegate,
      contains('func open(_ userActivity: NSUserActivity) -> Bool'),
    );
    expect(
      appDelegate,
      contains('userActivity.activityType == NSUserActivityTypeBrowsingWeb'),
    );
    expect(appDelegate, contains('userActivity.webpageURL'));
    expect(appDelegate, contains('targetURL.scheme?.lowercased() == "https"'));
    expect(appDelegate, contains('targetURL.user == nil'));
    expect(appDelegate, contains('targetURL.password == nil'));
    expect(appDelegate, isNot(contains('NSLog(targetURL')));
    expect(appDelegate, isNot(contains('NSLog(incomingURL')));
  });
}
