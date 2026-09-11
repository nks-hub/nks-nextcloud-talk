import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/app_install_source.dart';

/// Which builds are allowed to look for a newer one.
///
/// The desktops always are. A phone is only ever allowed when nothing else is
/// already keeping it up to date, and while that is still being worked out the
/// answer has to be no — a download offered beside a shop breaks the shop's
/// rules, and there is no undoing a shipped build that does it.
void main() {
  ProviderContainer containerWith(AsyncValue<AppInstallSource> source) {
    final container = ProviderContainer(
      overrides: [
        appInstallSourceProvider.overrideWith(
          (ref) => switch (source) {
            AsyncData(:final value) => Future<AppInstallSource>.value(value),
            // Never completes, which is what "still being asked" looks like.
            _ => Completer<AppInstallSource>().future,
          },
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in const [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test('$platform always looks for a newer build', () async {
      debugDefaultTargetPlatformOverride = platform;
      final container = containerWith(const AsyncData(AppInstallSource.store));

      expect(container.read(updateCheckHostProvider), isTrue);
    });
  }

  test('an Android build installed by hand looks for a newer one', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final container = containerWith(
      const AsyncData(AppInstallSource.sideloaded),
    );
    await container.read(appInstallSourceProvider.future);

    expect(container.read(updateCheckHostProvider), isTrue);
  });

  test('an Android build from a shop never does', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final container = containerWith(const AsyncData(AppInstallSource.store));
    await container.read(appInstallSourceProvider.future);

    expect(container.read(updateCheckHostProvider), isFalse);
  });

  test('an Android build whose source is unknown never does', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final container = containerWith(const AsyncData(AppInstallSource.unknown));
    await container.read(appInstallSourceProvider.future);

    expect(container.read(updateCheckHostProvider), isFalse);
  });

  test('an Android build still being asked about never does yet', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final container = containerWith(const AsyncLoading());

    expect(
      container.read(updateCheckHostProvider),
      isFalse,
      reason: 'silence has to read as a shop until proven otherwise',
    );
  });

  test('iOS never does, whatever it was installed by', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final container = containerWith(
      const AsyncData(AppInstallSource.sideloaded),
    );
    await container.read(appInstallSourceProvider.future);

    expect(container.read(updateCheckHostProvider), isFalse);
  });
}
