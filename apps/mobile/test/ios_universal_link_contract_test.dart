import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final separator = Platform.pathSeparator;
  final runner = '${Directory.current.path}${separator}ios${separator}Runner';

  test('the iOS target associates the documented Nextcloud host', () {
    final entitlements = File(
      '$runner${separator}Runner.entitlements',
    ).readAsStringSync();

    expect(
      entitlements,
      contains('<key>com.apple.developer.associated-domains</key>'),
    );
    expect(
      entitlements,
      contains('<string>applinks:cloud.example.invalid</string>'),
    );
    expect(
      RegExp(
        r'<string>applinks:[^<]+</string>',
      ).allMatches(entitlements).length,
      1,
      reason: 'Only a documented host may be entitled.',
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
