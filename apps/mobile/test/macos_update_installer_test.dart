import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/update_check_service.dart';
import 'package:nextcloudtalk/features/settings/update_installer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.nkshub.nextcloudtalk/updater');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'macOS delegates the selected update to Sparkle without a Dart download',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'cancelled';
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await container
          .read(updateInstallStateProvider.notifier)
          .downloadAndInstall(
            UpdateAvailable(
              buildNumber: 83,
              name: 'Update',
              releaseUri: Uri.parse(
                'https://github.com/example/app/releases/tag/v1.0.17+83',
              ),
              // No download URLs: the native updater fetches the signed appcast itself.
            ),
          );
      expect(calls.single.method, 'install');
      expect(calls.single.arguments, {'build': 83});
      expect(result, isA<UpdateInstallCancelled>());
      expect(
        container.read(updateInstallStateProvider),
        isA<UpdateInstallIdle>(),
      );
    },
  );

  test(
    'a native installation error clears the busy state and allows retry',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'update-failed',
          message: 'Invalid signature',
        );
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await container
          .read(updateInstallStateProvider.notifier)
          .downloadAndInstall(
            UpdateAvailable(
              buildNumber: 83,
              name: 'Update',
              releaseUri: Uri.parse('https://github.com/example/app'),
            ),
          );
      expect(result, isA<UpdateInstallStartFailed>());
      expect(
        container.read(updateInstallStateProvider),
        isA<UpdateInstallIdle>(),
      );
    },
  );
  test('macOS never falls back to the shell bundle replacement', () async {
    final service = UpdateInstallerService(
      bundleDirectory: () =>
          throw StateError('Must not inspect an installation'),
    );
    expect(
      await service.runInstaller(UpdateInstallReady(File('update.zip'))),
      isFalse,
    );
  });
}
