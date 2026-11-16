import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_offer.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_source.dart';
import 'package:nextcloudtalk/features/chat/composer/pasted_image.dart';

import 'clipboard_image_test_support.dart';
import 'test_support.dart';

const _card = Key('clipboard-image-offer');
const _field = Key('field');
const _timeline = Key('timeline');

void main() {
  late FakeClipboardImageSource clipboard;
  late FocusNode focus;
  late ValueNotifier<bool> blocked;
  late List<PastedImage> attached;
  late int sends;
  late Directory memory;

  setUp(() {
    ClipboardImageOffer.debugForgetHandledClip();
    clipboard = FakeClipboardImageSource();
    focus = FocusNode();
    blocked = ValueNotifier<bool>(false);
    attached = <PastedImage>[];
    sends = 0;
    memory = Directory.systemTemp.createTempSync('nctalk-clipboard-offer-');
  });

  tearDown(() async {
    blocked.dispose();
    // An answer is written to disk without being awaited, and on Windows a
    // file still open cannot be deleted; a loaded machine finishes late.
    for (var attempt = 1; ; attempt++) {
      try {
        memory.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 40) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  // The framework asserts on a lifecycle jump that skips a state.
  var backgrounded = false;
  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void toBackground(WidgetTester tester) {
    backgrounded = true;
    lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
  }

  void toForeground(WidgetTester tester) {
    if (!backgrounded) {
      return;
    }
    backgrounded = false;
    lifecycle(tester, const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
  }

  Future<void> pumpComposer(
    WidgetTester tester, {
    bool reduceMotion = false,
    bool rtl = false,
    VoidCallback? onTimelineTap,
    Object room = 'room-a',
    bool sending = false,
    double? paneWidth,
  }) async {
    addTearDown(() => toForeground(tester));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clipboardImageSourceProvider.overrideWithValue(clipboard),
          clipboardOfferMemoryProvider.overrideWithValue(
            ClipboardOfferMemory(directory: memory),
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduceMotion),
                child: Directionality(
                  textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: SizedBox(
                      width: paneWidth ?? double.infinity,
                      child: Column(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              key: _timeline,
                              behavior: HitTestBehavior.opaque,
                              onTap: onTimelineTap,
                            ),
                          ),
                          ClipboardImageOffer(
                            key: ValueKey<Object>(room),
                            focusNode: focus,
                            blocked: () => blocked.value || sending,
                            refresh: blocked,
                            sending: sending,
                            onAttach: (image) async {
                              attached.add(image);
                              return true;
                            },
                            onSend: () => sends++,
                          ),
                          TextField(key: _field, focusNode: focus),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Lets the engine decode the thumbnail, which fake time never does, and
  /// plays the transitions out.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 8; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> focusField(WidgetTester tester) async {
    await tester.tap(find.byKey(_field));
    await settle(tester);
  }

  Future<void> refocusField(WidgetTester tester) async {
    focus.unfocus();
    await settle(tester);
    await focusField(tester);
  }

  testWidgets('an image clip is offered, a text clip is not', (tester) async {
    clipboard.copyText();
    await pumpComposer(tester);
    await focusField(tester);
    expect(find.byKey(_card), findsNothing);
    expect(clipboard.reads, 0, reason: 'text is never read');

    clipboard.copyImage('clip-1', tinyPng);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(find.bySemanticsLabel('Paste image from clipboard'), findsOneWidget);
    expect(clipboard.reads, 1);
  });

  testWidgets('nothing is asked while the field is unfocused or the app is '
      'in the background', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await settle(tester);
    clipboard.copyImage('clip-2', tinyPng);
    await settle(tester);
    expect((clipboard.peeks, clipboard.reads), (0, 0));

    toBackground(tester);
    await focusField(tester);
    clipboard.copyImage('clip-3', tinyPng);
    await settle(tester);
    expect((clipboard.peeks, clipboard.reads), (0, 0));
    expect(find.byKey(_card), findsNothing);

    toForeground(tester);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 1);
  });

  testWidgets('a dismissed clip is not offered again, a newer one is', (
    tester,
  ) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    await tester.tap(find.byKey(const Key('clipboard-image-offer-dismiss')));
    await settle(tester);
    expect(find.byKey(_card), findsNothing);

    await refocusField(tester);
    toBackground(tester);
    toForeground(tester);
    await settle(tester);
    expect(find.byKey(_card), findsNothing);
    expect(clipboard.reads, 1, reason: 'the content is read once per clip');

    // Another room gets a fresh widget and must still remember the answer.
    await pumpComposer(tester, room: 'room-b');
    await refocusField(tester);
    expect(find.byKey(_card), findsNothing);

    clipboard.copyImage('clip-2', tinyPng);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 2);
  });

  testWidgets('an answered clip stays answered across a restart when its '
      'identity does', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    await tester.tap(find.byKey(const Key('clipboard-image-offer-dismiss')));
    await settle(tester);

    ClipboardImageOffer.debugForgetHandledClip();
    await pumpComposer(tester, room: 'room-after-restart');
    await refocusField(tester);
    expect(find.byKey(_card), findsNothing);
    expect(clipboard.reads, 1, reason: 'a remembered clip is not read again');

    // A platform whose identity starts over with the process keeps nothing.
    clipboard
      ..durable = false
      ..copyImage('clip-2', tinyPng);
    await settle(tester);
    await tester.tap(find.byKey(const Key('clipboard-image-offer-dismiss')));
    await settle(tester);
    ClipboardImageOffer.debugForgetHandledClip();
    await pumpComposer(tester, room: 'room-after-second-restart');
    await refocusField(tester);
    expect(find.byKey(_card), findsOneWidget);
  });

  testWidgets('send hands the image over exactly once', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    final send = find.byKey(const Key('clipboard-image-offer-send'));
    await tester.tap(send);
    await tester.tap(send, warnIfMissed: false);
    await settle(tester);

    expect(attached, hasLength(1));
    expect(attached.single.bytes, same(tinyPng));
    expect(attached.single.mimeType, 'image/png');
    expect(sends, 1);
    expect(find.byKey(_card), findsNothing);
    expect(focus.hasFocus, isTrue, reason: 'the keyboard must stay up');

    await refocusField(tester);
    expect(find.byKey(_card), findsNothing, reason: 'a sent clip is answered');
  });

  testWidgets('tapping the thumbnail attaches without sending', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    await tester.tap(find.byKey(const Key('clipboard-image-offer-attach')));
    await settle(tester);

    expect(attached, hasLength(1));
    expect(sends, 0);
    expect(find.byKey(_card), findsNothing);
  });

  testWidgets('a busy composer gets no offer and loses the one it shows', (
    tester,
  ) async {
    blocked.value = true;
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    expect(find.byKey(_card), findsNothing);
    expect((clipboard.peeks, clipboard.reads), (0, 0));

    // Freed, the composer offers the clip that came while it was busy,
    // without any other nudge.
    blocked.value = false;
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);

    final thumbnail = tester.widget<RawImage>(find.byType(RawImage)).image!;
    blocked.value = true;
    await settle(tester);
    expect(find.byKey(_card), findsNothing);
    expect(thumbnail.debugDisposed, isTrue);
  });

  testWidgets('the image is dropped on dismiss and when the app is hidden', (
    tester,
  ) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    var thumbnail = tester.widget<RawImage>(find.byType(RawImage)).image!;

    lifecycle(tester, const [AppLifecycleState.inactive]);
    await settle(tester);
    expect(
      find.byKey(_card),
      findsOneWidget,
      reason: 'a lost focus is no exit',
    );
    lifecycle(tester, const [AppLifecycleState.resumed]);

    // One frame, no exit animation: a hidden app may not get a second one.
    toBackground(tester);
    await tester.pump();
    expect(find.byKey(_card), findsNothing);
    expect(thumbnail.debugDisposed, isTrue);

    toForeground(tester);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget, reason: 'it was never answered');
    expect(clipboard.reads, 2);

    thumbnail = tester.widget<RawImage>(find.byType(RawImage)).image!;
    await tester.tap(find.byKey(const Key('clipboard-image-offer-dismiss')));
    await settle(tester);
    expect(find.byKey(_card), findsNothing);
    expect(thumbnail.debugDisposed, isTrue);
  });

  testWidgets('the image is dropped when the room changes', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    expect(find.byKey(_card), findsOneWidget);
    final thumbnail = tester.widget<RawImage>(find.byType(RawImage)).image!;

    focus.unfocus();
    await pumpComposer(tester, room: 'room-b');
    await settle(tester);
    expect(find.byKey(_card), findsNothing);
    expect(thumbnail.debugDisposed, isTrue);
  });

  testWidgets('reduced motion shows and hides the card without a transition', (
    tester,
  ) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester, reduceMotion: true);
    await tester.tap(find.byKey(_field));
    // Past the field's own focus animation, so only the card could move.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var round = 0; find.byKey(_card).evaluate().isEmpty; round++) {
      expect(round, lessThan(50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(tester.hasRunningAnimations, isFalse);

    await tester.tap(find.byKey(const Key('clipboard-image-offer-dismiss')));
    await tester.pump();
    expect(find.byKey(_card), findsNothing);
  });

  testWidgets('the card animates in within 200 ms', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await tester.tap(find.byKey(_field));
    // Past the field's own focus animation, so only the card can be moving.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.hasRunningAnimations, isFalse);
    for (var round = 0; find.byKey(_card).evaluate().isEmpty; round++) {
      expect(round, lessThan(50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byKey(_card), findsOneWidget);
  });

  testWidgets('a clipboard that never answers shows nothing and is asked '
      'once', (tester) async {
    clipboard
      ..hangs = true
      ..copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await tester.tap(find.byKey(_field));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(_card), findsNothing);
    expect(tester.takeException(), isNull);

    await refocusField(tester);
    expect(clipboard.reads, 1);
  });

  testWidgets('an unreadable clip and a broken picture show nothing', (
    tester,
  ) async {
    clipboard.copyImage('clip-1', null);
    await pumpComposer(tester);
    await focusField(tester);
    expect(find.byKey(_card), findsNothing);

    // The PNG signature and nothing an engine could decode behind it.
    clipboard.copyImage('clip-2', Uint8List.fromList(tinyPng.sublist(0, 24)));
    await settle(tester);
    expect(find.byKey(_card), findsNothing);
    expect(tester.takeException(), isNull);

    // Content that arrived and is no picture is not read on every look.
    final reads = clipboard.reads;
    await refocusField(tester);
    expect(clipboard.reads, reads);
  });

  testWidgets('the tile floats: nothing in the layout moves when it comes '
      'or goes', (tester) async {
    await pumpComposer(tester);
    await focusField(tester);
    final field = tester.getRect(find.byKey(_field));
    final timeline = tester.getRect(find.byKey(_timeline));

    clipboard.copyImage('clip-1', tinyPng);
    await settle(tester);
    final tile = tester.getRect(find.byKey(_card));
    expect(tester.getRect(find.byKey(_field)), field);
    expect(tester.getRect(find.byKey(_timeline)), timeline);
    expect(tile.bottom, lessThanOrEqualTo(field.top - 8));
    expect(tile.right, lessThanOrEqualTo(field.right));
    expect(tile.overlaps(timeline), isTrue, reason: 'it hangs over the list');

    await tester.tap(find.byKey(const Key('clipboard-image-offer-dismiss')));
    await settle(tester);
    expect(tester.getRect(find.byKey(_field)), field);
    expect(tester.getRect(find.byKey(_timeline)), timeline);
  });

  testWidgets('the tile follows the composer when the keyboard opens', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    final gap =
        tester.getTopLeft(find.byKey(_field)).dy -
        tester.getBottomLeft(find.byKey(_card)).dy;
    final before = tester.getTopLeft(find.byKey(_field)).dy;

    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await settle(tester);
    final after = tester.getTopLeft(find.byKey(_field)).dy;
    expect(after, lessThan(before - 200));
    expect(
      after - tester.getBottomLeft(find.byKey(_card)).dy,
      moreOrLessEquals(gap),
    );
  });

  testWidgets('a tap beside the tile reaches what is under it', (tester) async {
    var taps = 0;
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester, onTimelineTap: () => taps++);
    await focusField(tester);
    final tile = tester.getRect(find.byKey(_card));

    // Level with the tile, on the other side of the pane.
    await tester.tapAt(Offset(40, tile.center.dy));
    // In the tile's own box, but on the corner neither button covers.
    await tester.tapAt(tile.topRight + const Offset(-4, 4));
    expect(taps, 2);
    expect(find.byKey(_card), findsOneWidget);
    expect(attached, isEmpty);
  });

  testWidgets('the tile mirrors to the start edge in a right-to-left pane', (
    tester,
  ) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester, rtl: true);
    await focusField(tester);
    final tile = tester.getRect(find.byKey(_card));
    final field = tester.getRect(find.byKey(_field));
    expect(tile.left, moreOrLessEquals(field.left));
    expect(tile.bottom, lessThanOrEqualTo(field.top - 8));
  });

  testWidgets('both actions are full-size touch targets with labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    for (final key in const ['dismiss', 'send', 'attach']) {
      final size = tester.getSize(
        find.byKey(Key('clipboard-image-offer-$key')),
      );
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    expect(find.byTooltip('Send the image'), findsOneWidget);
    expect(find.byTooltip('Dismiss the clipboard image'), findsOneWidget);
    expect(find.byTooltip('Add the image to the message'), findsOneWidget);
    semantics.dispose();
  });

  test('clipboard padding after the PNG end is cut off', () {
    final padded = Uint8List.fromList([...tinyPng, 0, 0, 0, 0, 0, 0, 0]);
    expect(pngWithoutPadding(padded), tinyPng);
    expect(pngWithoutPadding(tinyPng), same(tinyPng));
    final notPng = Uint8List.fromList(List<int>.filled(32, 7));
    expect(pngWithoutPadding(notPng), same(notPng));
  });

  testWidgets('a clipboard bitmap becomes a file the engine decodes', (
    tester,
  ) async {
    // A 2x1 32-bit DIB: the 40-byte header, then one blue and one red pixel.
    final dib = Uint8List(48);
    ByteData.sublistView(dib)
      ..setUint32(0, 40, Endian.little)
      ..setInt32(4, 2, Endian.little)
      ..setInt32(8, 1, Endian.little)
      ..setUint16(12, 1, Endian.little)
      ..setUint16(14, 32, Endian.little)
      ..setUint32(40, 0xFF0000FF, Endian.little)
      ..setUint32(44, 0xFFFF0000, Endian.little);

    final file = bitmapFileFromDib(dib)!;
    expect(file.sublist(0, 2), [0x42, 0x4D]);
    final size = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(file);
      final frame = await codec.getNextFrame();
      final size = (frame.image.width, frame.image.height);
      frame.image.dispose();
      codec.dispose();
      return size;
    });
    expect(size, (2, 1));

    expect(bitmapFileFromDib(Uint8List(12)), isNull);
  });
  test('the tile keeps the shape and at most the size of the picture', () {
    void tile(
      int w,
      int h,
      double width,
      double height, {
      double maxWidth = 400,
      double maxHeight = 400,
      double pixelRatio = 1,
    }) {
      final size = ClipboardImageOfferCard.tileSize(
        w,
        h,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        pixelRatio: pixelRatio,
      );
      expect(size.width, moreOrLessEquals(width), reason: '$w x $h');
      expect(size.height, moreOrLessEquals(height), reason: '$w x $h');
    }

    // A full HD screenshot: as wide as allowed, its own 16:9 shape.
    tile(1920, 1080, 220, 220 * 1080 / 1920);
    // A phone screenshot: as tall as allowed, cropped to the narrowest tile.
    tile(1080, 2400, 96, 160);
    // A thin strip is cropped to a tile instead of becoming a line.
    tile(3000, 40, 220, 96);
    // A narrow pane gets a narrower tile.
    tile(1920, 1080, 180, 180 * 1080 / 1920, maxWidth: 180);
    // Little room above the composer makes it lower, in the same shape.
    tile(1920, 1080, 110 * 1920 / 1080, 110, maxHeight: 110);
    // A small picture keeps the size it has on the screen it came from.
    tile(200, 150, 200, 150);
    tile(400, 300, 200, 150, pixelRatio: 2);
    // A tiny one is raised to a tile still worth a tap.
    tile(16, 16, 96, 96);
  });

  testWidgets('a big screenshot shows larger than a small one, in its shape', (
    tester,
  ) async {
    final wide = await _png(tester, 1600, 900);
    final tall = await _png(tester, 400, 900);
    final small = await _png(tester, 150, 100);
    clipboard.copyImage('clip-wide', wide);
    await pumpComposer(tester);
    await focusField(tester);
    final picture = find.byKey(const Key('clipboard-image-offer-attach'));
    final wideSize = tester.getSize(picture);
    expect(
      wideSize.width / wideSize.height,
      moreOrLessEquals(16 / 9, epsilon: 0.05),
    );

    clipboard.copyImage('clip-tall', tall);
    await settle(tester);
    final tallSize = tester.getSize(picture);
    expect(tallSize.height, greaterThan(tallSize.width));
    expect(tallSize.height, lessThanOrEqualTo(160 + 1));

    // 150 x 100 pixels are 50 x 33 dp on this 3x screen, raised to the
    // smallest tile instead of being blown up to the box.
    clipboard.copyImage('clip-small', small);
    await settle(tester);
    expect(tester.getSize(picture), const Size(96, 96));
  });

  testWidgets('a clipboard still held by the screenshot tool is asked again', (
    tester,
  ) async {
    clipboard
      ..busyReads = 2
      ..copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await tester.tap(find.byKey(_field));
    for (var round = 0; round < 20; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 3);
  });

  testWidgets('on a desktop a new screenshot is offered without a click into '
      'the field', (tester) async {
    clipboard.offersWhileVisible = true;
    await pumpComposer(tester);
    await settle(tester);
    expect(find.byKey(_card), findsNothing);

    clipboard.copyImage('clip-1', tinyPng);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(focus.hasFocus, isFalse);

    // The next screenshot replaces the one on show, without any focus change.
    clipboard.copyImage('clip-2', tinyPng);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 2);
  });

  testWidgets('on a desktop the tile follows the clipboard while the window '
      'is on screen without the focus', (tester) async {
    clipboard
      ..offersWhileVisible = true
      ..copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    expect(find.byKey(_card), findsOneWidget);

    // The screenshot tool takes the focus; the window stays on screen.
    lifecycle(tester, const [AppLifecycleState.inactive]);
    await settle(tester);
    clipboard.copyImage('clip-2', tinyPng);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 2, reason: 'the new screenshot was read');
    lifecycle(tester, const [AppLifecycleState.resumed]);
    await settle(tester);
    expect(
      clipboard.reads,
      2,
      reason: 'getting the focus back reads nothing new',
    );
  });

  testWidgets('on a phone an inactive app reads nothing', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    lifecycle(tester, const [AppLifecycleState.inactive]);
    await settle(tester);
    clipboard.copyImage('clip-2', tinyPng);
    await settle(tester);
    expect(clipboard.reads, 1);
    lifecycle(tester, const [AppLifecycleState.resumed]);
    await settle(tester);
    expect(clipboard.reads, 2);
  });

  testWidgets(
    'where reading needs consent the tile shows without a preview and '
    'the image is read only when taken',
    (tester) async {
      clipboard
        ..readNeedsConsent = true
        ..copyImage('clip-1', tinyPng);
      await pumpComposer(tester);
      await focusField(tester);
      expect(find.byKey(_card), findsOneWidget);
      expect(clipboard.reads, 0, reason: 'showing the tile reads nothing');
      expect(
        find.byKey(const Key('clipboard-image-offer-send')),
        findsNothing,
        reason: 'a picture nobody has seen yet is not sent straight away',
      );

      await tester.tap(find.byKey(const Key('clipboard-image-offer-attach')));
      await settle(tester);
      expect(clipboard.reads, 1);
      expect(attached, hasLength(1));
      expect(sends, 0);
      expect(find.byKey(_card), findsNothing);
    },
  );

  testWidgets('the clipboard counter is watched only while somebody listens', (
    tester,
  ) async {
    var sequence = 7;
    var reads = 0;
    final watch = ClipboardSequenceWatch(() {
      reads++;
      return sequence;
    }, interval: const Duration(milliseconds: 100));
    var changes = 0;
    void listener() => changes++;

    await tester.pump(const Duration(milliseconds: 300));
    expect(reads, 0, reason: 'nobody listens yet');

    watch.addListener(listener);
    await tester.pump(const Duration(milliseconds: 250));
    expect(changes, 0, reason: 'the counter has not moved');

    sequence = 8;
    await tester.pump(const Duration(milliseconds: 100));
    expect(changes, 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(changes, 1, reason: 'one change is told once');

    watch.removeListener(listener);
    final before = reads;
    sequence = 9;
    await tester.pump(const Duration(milliseconds: 300));
    expect(reads, before);
    expect(changes, 1);
  });

  testWidgets('a newer clip that cannot be read yet takes the older tile '
      'away and is asked again on a later look', (tester) async {
    clipboard
      ..offersWhileVisible = true
      ..copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);

    clipboard
      ..busyReads = 3
      ..copyImage('clip-2', tinyPng);
    for (var round = 0; round < 12; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(_card), findsNothing, reason: 'clip-1 is not shown');
    expect(clipboard.reads, 4);

    // A busy clipboard says nothing about the clip itself.
    toBackground(tester);
    toForeground(tester);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 5);
  });

  testWidgets('a tile the clipboard has moved past sends nothing and makes '
      'way for the newer picture', (tester) async {
    final newer = Uint8List.fromList(tinyPng);
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    // Copied between two looks, so no change was announced yet.
    clipboard.copyImage('clip-2', newer, notify: false);
    await tester.tap(find.byKey(const Key('clipboard-image-offer-send')));
    await settle(tester);
    expect(attached, isEmpty);
    expect(sends, 0);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 2);

    await tester.tap(find.byKey(const Key('clipboard-image-offer-send')));
    await settle(tester);
    expect(attached.single.bytes, same(newer));
    expect(sends, 1);
  });

  testWidgets('a clip copied while a message went out is offered once it '
      'is gone', (tester) async {
    await pumpComposer(tester, sending: true);
    await focusField(tester);
    clipboard.copyImage('clip-1', tinyPng);
    await settle(tester);
    expect((clipboard.peeks, clipboard.reads), (0, 0));

    await pumpComposer(tester);
    await settle(tester);
    expect(find.byKey(_card), findsOneWidget);
  });

  testWidgets('another room offers the same clip without reading it again', (
    tester,
  ) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    expect(find.byKey(_card), findsOneWidget);

    await pumpComposer(tester, room: 'room-b');
    await refocusField(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 1);
  });

  testWidgets('content that changed while it was read is offered under its '
      'own identity', (tester) async {
    final newer = Uint8List.fromList(tinyPng);
    clipboard
      ..copyImage('clip-1', tinyPng)
      ..duringRead = () {
        clipboard
          ..duringRead = null
          ..copyImage('clip-2', newer, notify: false);
      };
    await pumpComposer(tester);
    await focusField(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(clipboard.reads, 2);

    await tester.tap(find.byKey(const Key('clipboard-image-offer-attach')));
    await settle(tester);
    expect(attached.single.bytes, same(newer));
    await refocusField(tester);
    expect(find.byKey(_card), findsNothing, reason: 'clip-2 is answered');
  });

  testWidgets('the clipboard is followed only while the app is on screen', (
    tester,
  ) async {
    await pumpComposer(tester);
    await settle(tester);
    expect(clipboard.listeners, 1);
    toBackground(tester);
    expect(clipboard.listeners, 0);
    toForeground(tester);
    expect(clipboard.listeners, 1);
  });

  group('two panes', () {
    late FocusNode other;

    setUp(() => other = FocusNode());
    tearDown(() => other.dispose());

    Future<void> pumpPanes(WidgetTester tester) async {
      Widget pane(String key, FocusNode node) => Expanded(
        child: Column(
          children: [
            const Spacer(),
            ClipboardImageOffer(
              key: ValueKey<String>(key),
              focusNode: node,
              blocked: () => false,
              refresh: blocked,
              sending: false,
              onAttach: (image) async {
                attached.add(image);
                return true;
              },
              onSend: () => sends++,
            ),
            TextField(focusNode: node),
          ],
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clipboardImageSourceProvider.overrideWithValue(clipboard),
            clipboardOfferMemoryProvider.overrideWithValue(
              ClipboardOfferMemory(directory: memory),
            ),
          ],
          child: localizedTestApp(
            home: Scaffold(
              body: Row(children: [pane('room', focus), pane('thread', other)]),
            ),
          ),
        ),
      );
    }

    testWidgets('share one read, and a clip answered in one leaves both', (
      tester,
    ) async {
      clipboard
        ..offersWhileVisible = true
        ..copyImage('clip-1', tinyPng);
      await pumpPanes(tester);
      await settle(tester);
      expect(find.byKey(_card), findsNWidgets(2));
      expect(clipboard.reads, 1);

      await tester.tap(
        find.byKey(const Key('clipboard-image-offer-dismiss')).first,
      );
      await settle(tester);
      expect(find.byKey(_card), findsNothing);
    });

    testWidgets('opening at once both remember a clip answered before a '
        'restart', (tester) async {
      await tester.runAsync(
        () => ClipboardOfferMemory(directory: memory).write('clip-1'),
      );
      clipboard
        ..offersWhileVisible = true
        ..copyImage('clip-1', tinyPng);
      await pumpPanes(tester);
      await settle(tester);
      expect(find.byKey(_card), findsNothing);
      expect(clipboard.reads, 0);
    });
  });

  testWidgets('a clipboard bitmap with a colour table is read past it', (
    tester,
  ) async {
    // A 1x1 24-bit DIB listing two green colours before its one red pixel.
    final dib = Uint8List(40 + 8 + 4);
    ByteData.sublistView(dib)
      ..setUint32(0, 40, Endian.little)
      ..setInt32(4, 1, Endian.little)
      ..setInt32(8, 1, Endian.little)
      ..setUint16(12, 1, Endian.little)
      ..setUint16(14, 24, Endian.little)
      ..setUint32(32, 2, Endian.little)
      ..setUint32(40, 0x0000FF00, Endian.little)
      ..setUint32(44, 0x0000FF00, Endian.little)
      ..setUint8(50, 0xFF);
    final file = bitmapFileFromDib(dib)!;
    final pixel = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(file);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData();
      frame.image.dispose();
      codec.dispose();
      return data!.buffer.asUint8List().sublist(0, 4);
    });
    expect(pixel, [0xFF, 0, 0, 0xFF]);
  });

  testWidgets('switching reduced motion while the tile is shown keeps its '
      'picture', (tester) async {
    clipboard.copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    final thumbnail = tester.widget<RawImage>(find.byType(RawImage)).image!;

    await pumpComposer(tester, reduceMotion: true);
    await tester.pump();
    expect(find.byKey(_card), findsOneWidget);
    expect(thumbnail.debugDisposed, isFalse);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(thumbnail),
    );
  });

  testWidgets('while the system asks about the paste the tile stays away', (
    tester,
  ) async {
    clipboard
      ..readNeedsConsent = true
      ..copyImage('clip-1', tinyPng);
    await pumpComposer(tester);
    await focusField(tester);
    clipboard.hold = Completer<void>();
    await tester.tap(find.byKey(const Key('clipboard-image-offer-attach')));
    await settle(tester);
    expect(find.byKey(_card), findsNothing);

    // The system's question takes the app out of resumed and back.
    lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await settle(tester);
    expect(find.byKey(_card), findsNothing);

    clipboard.hold!.complete();
    await settle(tester);
    expect(attached, hasLength(1));
    expect(find.byKey(_card), findsNothing);
  });

  testWidgets('a refused paste leaves the clip on offer', (tester) async {
    clipboard
      ..readNeedsConsent = true
      ..copyImage('clip-1', null);
    await pumpComposer(tester);
    await focusField(tester);
    await tester.tap(find.byKey(const Key('clipboard-image-offer-attach')));
    await settle(tester);
    expect(attached, isEmpty);
    expect(find.byKey(_card), findsOneWidget);
  });

  testWidgets('the tile fits its pane and the room above the composer', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final wide = await _png(tester, 1600, 900);
    final picture = find.byKey(const Key('clipboard-image-offer-attach'));
    clipboard.copyImage('clip-1', wide);
    await pumpComposer(tester, paneWidth: 300);
    await focusField(tester);
    expect(tester.getSize(picture).width, moreOrLessEquals(150));

    // A low window: 110 dp left for the picture between a top bar and the
    // composer, so the tile gets lower and stays below that bar.
    await pumpComposer(tester);
    await settle(tester);
    final field = tester.getSize(find.byKey(_field)).height;
    double windowFor(double room) =>
        3 *
        (kToolbarHeight + 16 + ClipboardImageOfferCard.overhang + room + field);
    tester.view.physicalSize = Size(2400, windowFor(110));
    await settle(tester);
    expect(tester.getSize(picture).height, moreOrLessEquals(110));
    expect(
      tester.getRect(find.byKey(_card)).top,
      moreOrLessEquals(kToolbarHeight),
    );

    // Too low for any tile worth a tap: none is shown.
    tester.view.physicalSize = Size(2400, windowFor(80));
    await settle(tester);
    expect(find.byKey(_card), findsNothing);
  });
}

/// A [width] x [height] PNG of one colour, encoded by the engine.
Future<Uint8List> _png(WidgetTester tester, int width, int height) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF3366CC),
    );
    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}
