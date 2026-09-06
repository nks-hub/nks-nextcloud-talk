import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/update_check_preference.dart';
import 'package:nextcloudtalk/features/settings/update_check_service.dart';
import 'package:nextcloudtalk/features/settings/update_check_tile.dart';
import 'package:nextcloudtalk/features/settings/update_installer_service.dart';

import 'test_support.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('the check is off until it is switched on, and asks nothing', (
    tester,
  ) async {
    final store = _Store();
    var checks = 0;
    await tester.pumpWidget(
      _tile(
        store: store,
        answer: () async {
          checks++;
          return const UpdateUpToDate();
        },
      ),
    );
    await tester.pump();

    expect(tester.widget<SwitchListTile>(_switch).value, isFalse);
    expect(find.byKey(const Key('settings-update-check-result')), findsNothing);
    expect(checks, 0);

    await tester.tap(_switch);
    await tester.pump();
    await tester.pump();

    expect(store.writes, <bool>[true]);
    expect(checks, 1);
    expect(
      find.byKey(const Key('settings-update-check-result')),
      findsOneWidget,
    );
  });

  testWidgets('a stored yes asks on its own and reports the newest build', (
    tester,
  ) async {
    await tester.pumpWidget(
      _tile(
        store: _Store(enabled: true),
        answer: () async => UpdateAvailable(
          buildNumber: 63,
          name: 'Build 63',
          releaseUri: Uri.parse(
            'https://github.com/nks-hub/nks-nextcloud-talk/releases/latest',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Build 63 is out: Build 63'), findsOneWidget);
    expect(find.byKey(const Key('settings-update-check-open')), findsOneWidget);
  });

  testWidgets('the button opens the release page and never installs it', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      _tile(
        store: _Store(enabled: true),
        answer: () async => UpdateAvailable(
          buildNumber: 63,
          name: 'Build 63',
          releaseUri: Uri.parse(
            'https://github.com/nks-hub/nks-nextcloud-talk/releases/latest',
          ),
        ),
        launcher: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings-update-check-open')));
    await tester.pump();

    expect(opened, <Uri>[
      Uri.parse(
        'https://github.com/nks-hub/nks-nextcloud-talk/releases/latest',
      ),
    ]);
  });

  testWidgets('a check that could not be made says so, with no button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _tile(
        store: _Store(enabled: true),
        answer: () async => const UpdateCheckUnavailable(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('GitHub could not be asked. Try again later.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-update-check-open')), findsNothing);
  });

  testWidgets('nothing newer reads as up to date', (tester) async {
    await tester.pumpWidget(
      _tile(
        store: _Store(enabled: true),
        answer: () async => const UpdateUpToDate(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Nothing newer has been published.'), findsOneWidget);
    expect(find.byKey(const Key('settings-update-check-open')), findsNothing);
  });

  testWidgets(
    'Windows offers to download the installer once one is published',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        _tile(
          store: _Store(enabled: true),
          answer: () async => _releaseWithInstaller(),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('settings-update-check-download-row')),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final platform in const [TargetPlatform.macOS, TargetPlatform.linux]) {
    testWidgets(
      '$platform never offers a download, even for a release that has one',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;

        await tester.pumpWidget(
          _tile(
            store: _Store(enabled: true),
            answer: () async => _releaseWithInstaller(),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const Key('settings-update-check-download-row')),
          findsNothing,
        );
        // The link every platform gets is still there.
        expect(
          find.byKey(const Key('settings-update-check-open')),
          findsOneWidget,
        );
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('confirming the download verifies it and offers to install', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final bytes = utf8.encode('fake installer bytes for the tile test');
    final hash = sha256.convert(bytes).toString();
    final client = MockClient((request) async {
      if (request.url.pathSegments.last == 'SHA256SUMS') {
        return http.Response('$hash  $_installerName\n', 200);
      }
      return http.Response.bytes(
        bytes,
        200,
        headers: {'content-length': '${bytes.length}'},
      );
    });

    await tester.pumpWidget(
      _tile(
        store: _Store(enabled: true),
        answer: () async => _releaseWithInstaller(),
        installerClient: client,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings-update-check-download')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('settings-update-check-download-confirm')),
    );

    // The download does real dart:io work (a temp directory, a file
    // write), so the fake clock plain pump() advances has nothing to wait
    // on — the real event loop needs an actual turn between pumps.
    await _pumpUntilFound(tester, const Key('settings-update-check-install'));

    expect(
      find.byKey(const Key('settings-update-check-install')),
      findsOneWidget,
      reason: 'a verified download must offer the second, install step',
    );
    debugDefaultTargetPlatformOverride = null;
  });
}

final _switch = find.byKey(const Key('settings-update-check'));

/// Waits for a widget keyed [key] to appear, interleaving a fake-clock
/// [WidgetTester.pump] with a real, tiny [Future.delayed] each round — the
/// real event loop needs an actual turn for the installer download's real
/// dart:io work (a temp directory, a file write) to make progress at all.
Future<void> _pumpUntilFound(WidgetTester tester, Key key) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (find.byKey(key).evaluate().isNotEmpty) {
      return;
    }
  }
  fail('${key.toString()} did not appear in time');
}

const _installerName = 'NKS-Talk-0.1.0-63-windows-x64-setup.exe';

UpdateAvailable _releaseWithInstaller() => UpdateAvailable(
  buildNumber: 63,
  name: 'Build 63',
  releaseUri: Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/tag/v0.1.0%2B63',
  ),
  windowsInstallerAssetUri: Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/'
    'v0.1.0%2B63/$_installerName',
  ),
  sha256SumsAssetUri: Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/'
    'v0.1.0%2B63/SHA256SUMS',
  ),
);

Widget _tile({
  required _Store store,
  required Future<UpdateCheckResult> Function() answer,
  ReferenceUriLauncher? launcher,
  http.Client? installerClient,
}) {
  return ProviderScope(
    overrides: [
      updateCheckPreferenceStoreProvider.overrideWithValue(store),
      // The tile only ever reads the answer, so the service itself is
      // replaced rather than its HTTP client — update_check_service_test.dart
      // is where the wire behaviour is pinned down.
      latestBuildProvider.overrideWith((ref) async {
        if (!ref.watch(updateCheckEnabledProvider)) {
          return null;
        }
        return answer();
      }),
      referenceUriLauncherProvider.overrideWithValue(
        launcher ?? (_) async => true,
      ),
      if (installerClient != null)
        updateInstallerServiceProvider.overrideWithValue(
          UpdateInstallerService(client: installerClient),
        ),
    ],
    child: localizedTestApp(
      home: const Scaffold(body: UpdateCheckSettingsTile()),
    ),
  );
}

final class _Store implements UpdateCheckPreferenceStore {
  _Store({this.enabled = false});

  final bool enabled;
  final List<bool> writes = [];

  @override
  Future<bool> read() async => enabled;

  @override
  Future<void> write(bool value) async => writes.add(value);
}
