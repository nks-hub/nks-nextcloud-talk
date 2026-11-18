import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_offer.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_source.dart';
import 'package:nextcloudtalk/features/chat/composer/pasted_image.dart';
import 'package:nextcloudtalk/features/chat/media/image_clipboard.dart';

import '../test/clipboard_image_test_support.dart';
import '../test/test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a real image clip attaches without opening the keyboard',
    (tester) async {
      final source = Platform.isAndroid
          ? ChannelClipboardImageSource.android
          : ChannelClipboardImageSource.macOS;
      final focus = FocusNode();
      final refresh = ValueNotifier(false);
      final attached = <PastedImage>[];
      addTearDown(focus.dispose);
      addTearDown(refresh.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [clipboardImageSourceProvider.overrideWithValue(source)],
          child: localizedTestApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Expanded(child: SizedBox.expand()),
                  ClipboardImageOffer(
                    focusNode: focus,
                    blocked: () => false,
                    refresh: refresh,
                    sending: false,
                    onAttach: (image) async {
                      attached.add(image);
                      return true;
                    },
                    onSend: () => fail('Tapping the image must only attach it'),
                  ),
                  TextField(focusNode: focus),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(await copyImageBytes(tinyPng), isTrue);

      final attach = find.byKey(const Key('clipboard-image-offer-attach'));
      await _waitFor(tester, () => attach.evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      await tester.tap(attach);
      await _waitFor(tester, () => attached.isNotEmpty);
      expect(attached.single.mimeType, 'image/png');
      await tester.pumpAndSettle();
      expect(attach, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isAndroid && !Platform.isMacOS,
  );
}

Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail('Clipboard operation timed out');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
