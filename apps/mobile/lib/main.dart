import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_providers.dart';
import 'core/background_drain.dart';
import 'core/telemetry.dart';
import 'core/telemetry_bootstrap.dart';

Future<void> main() async {
  await runWithTelemetry(
    config: TelemetryConfig.fromEnvironment(),
    appBuilder: (observers) => ProviderScope(
      overrides: [
        telemetryNavigatorObserversProvider.overrideWithValue(observers),
      ],
      child: const NextcloudTalkApp(),
    ),
  );
}

/// Second entry point, started by the platform's background scheduler when the
/// app process is not running at all. Lives here so the platform side can name
/// it without also naming a library.
///
/// No UI and no telemetry: this isolate exists to hand the outbox to the
/// network and end. A process that is already running is served by
/// `outboxDrainProvider` instead, over the same channel.
@pragma('vm:entry-point')
void backgroundDrainMain() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(
    runBackgroundDrainIsolate(
      drain: () async {
        final container = ProviderContainer();
        try {
          await drainForBackground(container);
        } finally {
          container.dispose();
        }
      },
    ),
  );
}
