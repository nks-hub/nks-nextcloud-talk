import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:path_provider/path_provider.dart';

/// Store screenshots for the 13-inch iPad, taken from the real app signed in
/// to the screenshot rig.
///
/// The rig, `tool/store_screenshot_server.py`, serves an invented Talk server
/// with invented people; a store page is read by everybody, so no real account
/// may ever be the source. Start it on the Mac first, where the simulator
/// reaches `talk.localtest.me` as 127.0.0.1:
///
///     python3 tool/store_screenshot_server.py --language cs --port 443
///
/// then run this on an iPad simulator. The pictures are taken inside the
/// engine at the store's exact size, 2064 x 2752, written to the app's
/// documents folder, and their paths printed after `STORE-SHOT`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
    }
    fail('Timed out waiting for $finder');
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await settle(tester);
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(view.paintBounds, pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$name.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    debugPrint('STORE-SHOT ${image.width}x${image.height} ${file.path}');
  }

  testWidgets('iPad 13-inch store screenshots', (tester) async {
    tester.view.physicalSize = const Size(2064, 2752);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientPushEnabledProvider.overrideWithValue(false)],
        child: const NextcloudTalkApp(),
      ),
    );

    final server = find.descendant(
      of: find.byKey(const Key('onboarding-server-card')),
      matching: find.byType(TextField),
    );
    await waitFor(tester, server);
    await tester.enterText(server, 'talk.localtest.me');
    await tester.testTextInput.receiveAction(TextInputAction.done);

    await waitFor(tester, find.byKey(const Key('certificate-trust-confirm')));
    await tester.tap(find.byKey(const Key('certificate-trust-confirm')));

    final room = find.text('Produktový tým');
    await waitFor(tester, room, timeout: const Duration(minutes: 4));
    await tester.tap(room.first);
    await waitFor(tester, find.text('Pro mě dobré.'));
    await shoot(tester, 'ipad13-1-chat');

    await tester.enterText(
      find.byKey(const Key('chat-composer')),
      'Pošlu odkaz na kód:',
    );
    await tester.tap(find.byKey(const Key('open-format-menu')));
    await shoot(tester, 'ipad13-2-format');
  });
}
