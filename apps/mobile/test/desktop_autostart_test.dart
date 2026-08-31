import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/platform/desktop_autostart.dart';

import 'test_support.dart';

final class _MemoryDesktopAutostart implements DesktopAutostart {
  _MemoryDesktopAutostart({this.supported = true});

  bool supported;
  bool enabled = false;
  bool applyChanges = true;
  int setCount = 0;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> setEnabled(bool requested) async {
    setCount++;
    if (applyChanges) {
      enabled = requested;
    }
    return enabled;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'method channel passes the requested state and returns native state',
    () async {
      const channel = MethodChannel(
        'com.nkshub.nextcloudtalk/test_desktop_autostart',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'isSupported' => true,
              'isEnabled' => false,
              'setEnabled' => true,
              _ => null,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const platform = MethodChannelDesktopAutostart(channel: channel);

      expect(await platform.isSupported(), isTrue);
      expect(await platform.isEnabled(), isFalse);
      expect(await platform.setEnabled(true), isTrue);
      expect(calls.map((call) => call.method), [
        'isSupported',
        'isEnabled',
        'setEnabled',
      ]);
      expect(calls.last.arguments, <String, Object?>{'enabled': true});
    },
  );

  test('controller verifies the state after every native change', () async {
    final platform = _MemoryDesktopAutostart();
    final container = ProviderContainer(
      overrides: [
        desktopAutostartHostProvider.overrideWithValue(true),
        desktopAutostartProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(container.dispose);

    container.read(desktopAutostartStateProvider);
    while (container.read(desktopAutostartStateProvider).busy) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(desktopAutostartStateProvider).enabled, isFalse);

    expect(
      await container
          .read(desktopAutostartStateProvider.notifier)
          .setEnabled(true),
      isTrue,
    );
    expect(platform.setCount, 1);
    expect(container.read(desktopAutostartStateProvider).enabled, isTrue);

    platform.applyChanges = false;
    expect(
      await container
          .read(desktopAutostartStateProvider.notifier)
          .setEnabled(false),
      isFalse,
    );
    final failed = container.read(desktopAutostartStateProvider);
    expect(failed.enabled, isTrue);
    expect(failed.failed, isTrue);
  });

  testWidgets('desktop setting changes the account-neutral OS preference', (
    tester,
  ) async {
    final platform = _MemoryDesktopAutostart();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) => Stream.value(const [])),
          desktopAutostartHostProvider.overrideWithValue(true),
          desktopAutostartProvider.overrideWithValue(platform),
        ],
        child: localizedTestApp(home: const SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-desktop-autostart')),
      200,
      scrollable: find.byType(Scrollable),
    );

    expect(find.byKey(const Key('settings-desktop-autostart')), findsOneWidget);
    final initial = tester.widget<Switch>(
      find.byKey(const Key('settings-desktop-autostart-switch')),
    );
    expect(initial.value, isFalse);

    await tester.tap(
      find.byKey(const Key('settings-desktop-autostart-switch')),
    );
    await tester.pump();
    await tester.pump();

    expect(platform.enabled, isTrue);
    final updated = tester.widget<Switch>(
      find.byKey(const Key('settings-desktop-autostart-switch')),
    );
    expect(updated.value, isTrue);
    expect(
      find.text('NKS Talk opens automatically after you sign in.'),
      findsOneWidget,
    );
  });

  testWidgets('unsupported desktop does not advertise autostart', (
    tester,
  ) async {
    final platform = _MemoryDesktopAutostart(supported: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) => Stream.value(const [])),
          desktopAutostartHostProvider.overrideWithValue(true),
          desktopAutostartProvider.overrideWithValue(platform),
        ],
        child: localizedTestApp(home: const SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('settings-desktop-autostart')), findsNothing);
  });
}
