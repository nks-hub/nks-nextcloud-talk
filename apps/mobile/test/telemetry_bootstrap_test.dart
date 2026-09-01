import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/runtime_health_telemetry.dart';
import 'package:nextcloudtalk/core/telemetry.dart';
import 'package:nextcloudtalk/core/telemetry_bootstrap.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Sentry keeps watchdog and app-hang diagnostics enabled', () {
    final options = SentryFlutterOptions();

    configureSentryOptions(
      options,
      config: const TelemetryConfig(
        sentryDsn: 'https://key@sentry.example.invalid/1',
        rybbitHost: '',
        rybbitSiteId: '',
        environment: 'production',
      ),
    );

    expect(options.enableWatchdogTerminationTracking, isTrue);
    expect(options.enableAppHangTracking, isTrue);
    expect(options.appHangTimeoutInterval, const Duration(seconds: 2));
    expect(options.enableAutoNativeBreadcrumbs, isTrue);
    expect(options.enableMemoryPressureBreadcrumbs, isFalse);
    expect(options.enableScopeSync, isTrue);
  });

  test('release gate scope retains only allowlisted runtime tags', () async {
    final runtime = RuntimeHealthTelemetry(
      runKind: RuntimeHealthRunKind.releaseGate,
      readRssBytes: () => 300 * 1024 * 1024,
      reportTags: (_) async {},
      lifecycleState: () => AppLifecycleState.paused,
    );
    await runtime.start();
    addTearDown(runtime.dispose);

    for (final gateKind in <String>['error', 'diagnostic']) {
      final scope = Scope(SentryFlutterOptions());
      await scope.setTag('runtime.raw_bytes', '314572800');
      await scope.setTag('server', 'private.example.invalid');
      await scope.setUser(SentryUser(id: 'installation-id'));
      await scope.addBreadcrumb(
        Breadcrumb(message: 'private breadcrumb', category: 'test'),
      );

      await configureTelemetryReleaseGateScope(
        scope,
        gateKind: gateKind,
        runtimeTags: runtime.tags,
      );
      final event = await scope.applyToEvent(SentryEvent(), Hint());

      expect(event?.tags, <String, String>{
        'runtime.run_kind': 'release_gate',
        'runtime.lifecycle': 'background',
        'runtime.rss_bucket': '256-384m',
        'runtime.memory_pressure_seen': 'false',
        'telemetry.release_gate': gateKind,
      });
      expect(event?.user, isNull);
      expect(event?.breadcrumbs, isEmpty);
    }
  });

  group('scrubSentryEvent', () {
    test('drops the request, which names the server and the room', () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://talk.example.com/ocs/v2.php/apps/spreed/api/v4/room',
        ),
      );

      expect(scrubSentryEvent(event).request, isNull);
    });

    test('reduces a URL in the message to its scheme', () {
      final event = SentryEvent(
        message: SentryMessage(
          'GET https://talk.example.com/call/a1b2c3d4 failed',
        ),
      );

      final formatted = scrubSentryEvent(event).message!.formatted;
      expect(formatted, contains('https://<host>'));
      expect(formatted, isNot(contains('talk.example.com')));
      expect(formatted, isNot(contains('a1b2c3d4')));
    });

    test('scrubs every exception value', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'HttpException',
            value: 'Authorization: Basic fixture-value rejected',
          ),
          SentryException(
            type: 'StateError',
            value: 'room https://talk.example.com/call/a1b2c3d4 is gone',
          ),
        ],
      );

      final values = scrubSentryEvent(
        event,
      ).exceptions!.map((e) => e.value).join(' ');
      expect(values, isNot(contains('fixture-value')));
      expect(values, isNot(contains('talk.example.com')));
      expect(values, isNot(contains('a1b2c3d4')));
    });

    test('attachment diagnostics drop inherited user and breadcrumbs', () {
      final event = SentryEvent(
        logger: 'attachment.upload',
        user: SentryUser(id: 'installation-id'),
        breadcrumbs: <Breadcrumb>[
          Breadcrumb(
            category: 'http',
            data: <String, Object?>{
              'url': 'https://talk.example.com/call/a1b2c3d4',
            },
          ),
        ],
      );

      final scrubbed = scrubSentryEvent(event);
      expect(scrubbed.user, isNull);
      expect(scrubbed.breadcrumbs, isEmpty);
    });
  });

  group('scrubSentryBreadcrumb', () {
    test('scrubs the message and every string in data', () {
      final crumb = Breadcrumb(
        message: 'request to https://talk.example.com/call/a1b2c3d4',
        data: {
          'url': 'https://talk.example.com/ocs/v2.php/apps/spreed',
          'method': 'GET',
          'status_code': 404,
        },
      );

      final scrubbed = scrubSentryBreadcrumb(crumb, Hint())!;
      expect(scrubbed.message, isNot(contains('talk.example.com')));
      expect(scrubbed.data!['url'], 'https://<host>');
      expect(scrubbed.data!['method'], 'GET');
      expect(scrubbed.data!['status_code'], 404);
    });

    test('passes a null breadcrumb through', () {
      expect(scrubSentryBreadcrumb(null, Hint()), isNull);
    });
  });
}
