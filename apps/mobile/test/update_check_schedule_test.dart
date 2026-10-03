import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/update_check_preference.dart';
import 'package:nextcloudtalk/features/settings/update_check_service.dart';

final _activeWindow = StateProvider<bool>((ref) => true);

void main() {
  testWidgets('GitHub retry-after also delays wake-triggered checks', (
    tester,
  ) async {
    final f = _Fixture(
      answer: (count) async => count == 1
          ? http.Response('', 429, headers: {'retry-after': '600'})
          : _release('89'),
    );
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(minutes: 5));
    f.network.add(null);
    f.resume.add(null);
    await tester.pump(Duration.zero);
    expect(f.checks, 1);
    await tester.pump(const Duration(minutes: 5));
    await tester.pump(Duration.zero);
    expect(f.checks, 2);
    f.container.dispose();
  });

  testWidgets('checks at startup and every fifteen minutes', (tester) async {
    final f = _Fixture();
    await tester.pump(Duration.zero);
    expect(f.checks, 1);
    await tester.pump(updateCheckInterval - const Duration(seconds: 1));
    expect(f.checks, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(Duration.zero);
    expect(f.checks, 2);
    f.container.dispose();
  });

  for (final failure in ['network', 'missing installer']) {
    testWidgets(
      'retries $failure after two minutes',
      (tester) async {
        final f = _Fixture(
          answer: (count) async => count == 1
              ? failure == 'network'
                    ? http.Response('', 503)
                    : _release('90')
              : _release('89'),
        );
        await tester.pump(Duration.zero);
        expect(f.checks, 1);
        await tester.pump(updateCheckRetryInterval);
        await tester.pump(Duration.zero);
        expect(f.checks, 2);
        expect(
          f.container.read(latestBuildProvider).valueOrNull,
          isA<UpdateUpToDate>(),
        );
        f.container.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets('resume, network and focus hints share a five-minute cooldown', (
    tester,
  ) async {
    final f = _Fixture();
    await tester.pump(Duration.zero);
    f.resume.add(null);
    f.network.add(null);
    await tester.pump(Duration.zero);
    expect(f.checks, 1);
    await tester.pump(updateCheckWakeInterval);
    f.resume.add(null);
    f.network.add(null);
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    expect(f.checks, 2);
    f.container.read(_activeWindow.notifier).state = false;
    await tester.pump(Duration.zero);
    f.container.read(_activeWindow.notifier).state = true;
    await tester.pump(Duration.zero);
    expect(f.checks, 2);
    await tester.pump(updateCheckWakeInterval);
    f.container.read(_activeWindow.notifier).state = false;
    await tester.pump(Duration.zero);
    f.container.read(_activeWindow.notifier).state = true;
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    expect(f.checks, 3);
    f.container.dispose();
  });

  testWidgets('a restored network retries a failed check after one minute', (
    tester,
  ) async {
    final f = _Fixture(
      answer: (count) async =>
          count == 1 ? http.Response('', 503) : _release('89'),
    );
    await tester.pump(Duration.zero);
    f.network.add(null);
    await tester.pump(Duration.zero);
    expect(f.checks, 1);
    await tester.pump(updateCheckRetryWakeInterval);
    f.network.add(null);
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    expect(f.checks, 2);
    f.container.dispose();
  });

  testWidgets('wake hints do not overlap a check or revive disabled checks', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final f = _Fixture(answer: (_) => pending.future);
    await tester.pump(Duration.zero);
    await tester.pump(updateCheckWakeInterval);
    f.network.add(null);
    f.resume.add(null);
    await tester.pump(Duration.zero);
    expect(f.checks, 1);
    await f.container
        .read(updateCheckEnabledProvider.notifier)
        .setEnabled(false);
    pending.complete(_release('89'));
    await tester.pump(Duration.zero);
    await tester.pump(updateCheckInterval * 2);
    f.network.add(null);
    await tester.pump(Duration.zero);
    expect(f.checks, 1);
    expect(f.container.read(latestBuildProvider).valueOrNull, isNull);
    expect(f.network.hasListener, isFalse);
    expect(f.resume.hasListener, isFalse);
    f.container.dispose();
  });

  testWidgets('a store-managed host never checks even with a saved opt-in', (
    tester,
  ) async {
    final f = _Fixture(host: false);
    await tester.pump(Duration.zero);
    await tester.pump(updateCheckInterval * 2);
    expect(f.checks, 0);
    expect(f.network.hasListener, isFalse);
    f.container.dispose();
  });

  testWidgets('an explicit opt-out wins over a delayed saved preference', (
    tester,
  ) async {
    final preference = Completer<bool>();
    final f = _Fixture(preference: preference.future);
    await f.container
        .read(updateCheckEnabledProvider.notifier)
        .setEnabled(false);
    preference.complete(true);
    await tester.pump(Duration.zero);
    expect(f.container.read(updateCheckEnabledProvider), isFalse);
    expect(f.checks, 0);
    f.container.dispose();
  });
}

http.Response _release(String build) => http.Response(
  jsonEncode({
    'tag_name': 'v1.0.21+$build',
    'html_url':
        'https://github.com/nks-hub/nks-nextcloud-talk/releases/tag/v1.0.21%2B$build',
    'assets': [],
  }),
  200,
);

class _Fixture {
  _Fixture({
    bool host = true,
    Future<bool>? preference,
    Future<http.Response> Function(int)? answer,
  }) {
    final service = UpdateCheckService(
      currentBuild: '89',
      timeout: const Duration(hours: 1),
      client: MockClient((_) {
        checks++;
        return answer?.call(checks) ?? Future.value(_release('89'));
      }),
    );
    container = ProviderContainer(
      overrides: [
        updateCheckHostProvider.overrideWithValue(host),
        updateCheckPreferenceStoreProvider.overrideWithValue(
          _Preference(preference ?? Future.value(true)),
        ),
        updateCheckServiceProvider.overrideWithValue(service),
        connectivityWakeEventsProvider.overrideWithValue(network.stream),
        appLifecycleResumeEventsProvider.overrideWithValue(resume.stream),
        windowActiveProvider.overrideWith((ref) => ref.watch(_activeWindow)),
      ],
    );
    container.listen(latestBuildProvider, (_, _) {}, fireImmediately: true);
    addTearDown(() async {
      container.dispose();
      service.close();
      await network.close();
      await resume.close();
    });
  }

  final network = StreamController<void>.broadcast(sync: true);
  final resume = StreamController<void>.broadcast(sync: true);
  late final ProviderContainer container;
  int checks = 0;
}

class _Preference implements UpdateCheckPreferenceStore {
  _Preference(this.value);
  final Future<bool> value;
  @override
  Future<bool> read() => value;
  @override
  Future<void> write(bool enabled) async {}
}
