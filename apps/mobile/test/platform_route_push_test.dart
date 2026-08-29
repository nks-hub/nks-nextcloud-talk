import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';

import 'test_support.dart';

void main() {
  testWidgets('a route pushed by the platform never reaches the navigator', (
    tester,
  ) async {
    // A link opens the app twice: through our own deep_link channel, and
    // through Flutter's pushRouteInformation, which calls Navigator.pushNamed
    // with the link's path. This app has no named routes, so that second
    // delivery used to die in WidgetsApp._onUnknownRoute on a null check -
    // fatal, on a real device, for every link (Sentry NKS-TALK-6).
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(openTestDatabase())],
        child: const NextcloudTalkApp(),
      ),
    );
    await tester.pump();

    final handled = await tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter/navigation',
          const JSONMethodCodec().encodeMethodCall(
            const MethodCall('pushRouteInformation', <String, dynamic>{
              'location': '/call/somerandomtoken',
              'state': null,
            }),
          ),
          (_) {},
        );

    expect(
      tester.takeException(),
      isNull,
      reason: 'the push must not raise anything at all',
    );
    expect(
      const JSONMethodCodec().decodeEnvelope(handled!),
      isTrue,
      reason: 'the platform is told the link was taken care of',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
