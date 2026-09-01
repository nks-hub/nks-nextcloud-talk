import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('Android app lock uses the documented local_auth host contract', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    final activity = _read(
      'android/app/src/main/kotlin/com/nkshub/nextcloudtalk/push/'
      'AndroidWebPushActivity.kt',
    );
    final lightStyles = _read('android/app/src/main/res/values/styles.xml');
    final darkStyles = _read(
      'android/app/src/main/res/values-night/styles.xml',
    );

    expect(manifest, contains('android.permission.USE_BIOMETRIC'));
    expect(
      activity,
      contains('import io.flutter.embedding.android.FlutterFragmentActivity'),
    );
    expect(
      activity,
      contains('AndroidWebPushActivity : FlutterFragmentActivity()'),
    );
    expect(lightStyles, contains('Theme.AppCompat.DayNight.NoActionBar'));
    expect(darkStyles, contains('Theme.AppCompat.DayNight.NoActionBar'));
    expect(manifest, contains('android:name=".push.AndroidWebPushActivity"'));
    expect(manifest, contains('android.intent.action.SEND'));
  });

  test('iOS declares and localizes the Face ID purpose string', () {
    final plist = _read('ios/Runner/Info.plist');
    final english = _read('ios/Runner/en.lproj/InfoPlist.strings');
    final czech = _read('ios/Runner/cs.lproj/InfoPlist.strings');

    expect(plist, contains('<key>NSFaceIDUsageDescription</key>'));
    expect(english, contains('"NSFaceIDUsageDescription"'));
    expect(czech, contains('"NSFaceIDUsageDescription"'));
  });
}
