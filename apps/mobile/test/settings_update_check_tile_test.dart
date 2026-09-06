import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/update_check_preference.dart';
import 'package:nextcloudtalk/features/settings/update_check_service.dart';
import 'package:nextcloudtalk/features/settings/update_check_tile.dart';

import 'test_support.dart';

void main() {
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
}

final _switch = find.byKey(const Key('settings-update-check'));

Widget _tile({
  required _Store store,
  required Future<UpdateCheckResult> Function() answer,
  ReferenceUriLauncher? launcher,
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
