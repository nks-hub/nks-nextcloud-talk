import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_providers.dart';
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
