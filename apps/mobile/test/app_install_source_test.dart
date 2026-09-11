import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/app_install_source.dart';

/// Who installed a build decides whether it is ever told about a newer one.
/// Getting this wrong in one direction costs a missing line in settings; in
/// the other it breaks a shop's rules, so every answer is pinned down here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading a package name', () {
    test('a shop that keeps its builds up to date is recognised', () {
      for (final shop in storeInstallerPackages) {
        expect(
          classifyInstaller(shop),
          AppInstallSource.store,
          reason: shop,
        );
      }
    });

    test('anything else is a build somebody installed by hand', () {
      expect(
        classifyInstaller('com.google.android.packageinstaller'),
        AppInstallSource.sideloaded,
      );
      expect(classifyInstaller('com.example.sideloader'), AppInstallSource.sideloaded);
    });

    test('no answer stays unknown rather than being guessed at', () {
      expect(classifyInstaller(null), AppInstallSource.unknown);
      expect(classifyInstaller(''), AppInstallSource.unknown);
      expect(classifyInstaller('   '), AppInstallSource.unknown);
    });
  });

  group('asking the platform', () {
    const channel = MethodChannel(AppInstallSourceReader.channelName);
    final calls = <MethodCall>[];

    void answer(Object? Function() reply) {
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return reply();
          });
    }

    setUp(calls.clear);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('reads the installer on Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      answer(() => 'com.android.vending');

      expect(
        await const AppInstallSourceReader().read(),
        AppInstallSource.store,
      );
      expect(
        calls.single.method,
        AppInstallSourceReader.installingPackageMethod,
      );
    });

    test('a build installed by hand says so', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      answer(() => 'com.example.files');

      expect(
        await const AppInstallSourceReader().read(),
        AppInstallSource.sideloaded,
      );
    });

    test('a platform that fails the call is not guessed at', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      answer(() => throw PlatformException(code: 'nope'));

      expect(
        await const AppInstallSourceReader().read(),
        AppInstallSource.unknown,
      );
    });

    test('no other platform is even asked', () async {
      answer(() => 'com.example.files');
      for (final platform in const [
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          await const AppInstallSourceReader().read(),
          AppInstallSource.unknown,
          reason: '$platform',
        );
      }
      expect(calls, isEmpty, reason: 'the question only arises on Android');
    });
  });
}
