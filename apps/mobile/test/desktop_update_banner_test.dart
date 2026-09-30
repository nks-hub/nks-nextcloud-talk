import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/desktop_update_banner.dart';
import 'package:nextcloudtalk/features/settings/update_check_preference.dart';
import 'package:nextcloudtalk/features/settings/update_check_service.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

import 'test_support.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test(
      '$platform checks by default and preserves an explicit opt-out',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final directory = await Directory.systemTemp.createTemp(
          'update-preference-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = FileUpdateCheckPreferenceStore(directory: directory);
        expect(await store.read(), isTrue);
        await store.write(false);
        expect(
          await FileUpdateCheckPreferenceStore(directory: directory).read(),
          isFalse,
        );
      },
    );
  }

  test('a missing mobile preference does not enable GitHub requests', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final directory = await Directory.systemTemp.createTemp(
      'update-preference-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    expect(
      await FileUpdateCheckPreferenceStore(directory: directory).read(),
      isFalse,
    );
  });

  testWidgets('offers and dismisses an update without opening settings', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var checks = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          latestBuildProvider.overrideWith((ref) async {
            checks++;
            return _release;
          }),
        ],
        child: localizedTestApp(
          home: const DesktopUpdateBanner(
            child: Scaffold(body: Text('Conversation')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(checks, 1);
    expect(find.byKey(const Key('desktop-update-banner')), findsOneWidget);
    expect(find.text('Update and restart'), findsOneWidget);
    expect(find.text('Conversation'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop-update-banner')), findsNothing);
    expect(find.text('Conversation'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an update offer preserves the open route and its draft', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final pending = Completer<UpdateCheckResult>();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [latestBuildProvider.overrideWith((ref) => pending.future)],
        child: MaterialApp(
          locale: const Locale('en'),
          navigatorKey: navigator,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) => DesktopUpdateBanner(child: child!),
          home: const Scaffold(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: TextField()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unfinished message');
    pending.complete(_release);
    await tester.pumpAndSettle();
    expect(find.text('unfinished message'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('unfinished message'), findsOneWidget);
    expect(navigator.currentState!.canPop(), isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile never checks through the desktop banner', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          latestBuildProvider.overrideWith((ref) async {
            fail('A store build must not request desktop updates');
          }),
        ],
        child: localizedTestApp(
          home: const DesktopUpdateBanner(child: Scaffold()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop-update-banner')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the update offer fits a narrow window with large text', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [latestBuildProvider.overrideWith((ref) async => _release)],
        child: localizedTestApp(
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: DesktopUpdateBanner(child: Scaffold()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Update and restart'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

final _release = UpdateAvailable(
  buildNumber: 999,
  name: 'OwnTalk 2.0.0',
  releaseUri: Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/tag/v2.0.0%2B999',
  ),
  installerAssetUri: Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/v2.0.0%2B999/NKS-Talk-2.0.0-999-windows-x64-setup.exe',
  ),
  sha256SumsAssetUri: Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/v2.0.0%2B999/SHA256SUMS',
  ),
);
