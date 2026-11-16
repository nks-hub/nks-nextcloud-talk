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

  tearDown(() {
    blocked.dispose();
    memory.deleteSync(recursive: true);
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
                        blocked: () => blocked.value,
                        refresh: blocked,
                        sending: false,
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

    blocked.value = false;
    await refocusField(tester);
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
    await focusField(tester);
    expect(find.byKey(_card), findsOneWidget);
    expect(find.byType(AnimatedSwitcher), findsNothing);

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
  test('the tile keeps the shape of the picture inside a bounded box', () {
    Size tile(int w, int h, [double available = 400]) =>
        ClipboardImageOfferCard.tileSize(w, h, available);

    // A full HD screenshot: as wide as allowed, its own 16:9 shape.
    expect(tile(1920, 1080), const Size(220, 220 * 1080 / 1920));
    // A phone screenshot: as tall as allowed, its own shape.
    expect(tile(1080, 2400), const Size(72, 160));
    // A thin strip is cropped to 3:1 instead of becoming a line.
    expect(tile(3000, 40), const Size(220, 220 / 3));
    // A narrow pane gets a smaller tile, never more than half its width.
    expect(tile(1920, 1080, 150).width, 150);
    // A tiny picture is not blown up past the box either way.
    expect(tile(16, 16), const Size(160, 160));
  });

  testWidgets('a big screenshot shows larger than a small one, in its shape', (
    tester,
  ) async {
    Future<Uint8List> png(int width, int height) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xFF3366CC),
      );
      final image = await recorder.endRecording().toImage(width, height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }

    final wide = (await tester.runAsync(() => png(1600, 900)))!;
    final tall = (await tester.runAsync(() => png(400, 900)))!;
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

      await tester.tap(find.byKey(const Key('clipboard-image-offer-send')));
      await settle(tester);
      expect(clipboard.reads, 1);
      expect(attached, hasLength(1));
      expect(sends, 1);
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
}
