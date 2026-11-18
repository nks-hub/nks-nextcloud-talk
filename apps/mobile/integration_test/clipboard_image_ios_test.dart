import 'dart:async';
import 'dart:io' show Directory, Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_offer.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_source.dart';
import 'package:nextcloudtalk/features/chat/composer/pasted_image.dart';
import 'package:pasteboard/pasteboard.dart';

import '../test/test_support.dart';

/// Off, the test copies the images itself, which iOS never asks about. On
/// (`--dart-define=CLIP_EXTERNAL=true`), the clip comes from another app: the
/// test prints `CLIPTEST ACT <step>: <what to do>` and waits while somebody,
/// or a script driving the simulator, copies an image in Safari or answers
/// the paste alert the tap raised. The first image must be 600x400 pixels.
/// `CLIPTEST SHOT <name>` marks a moment worth a simulator screenshot.
const _external = bool.fromEnvironment('CLIP_EXTERNAL');

const _channel = MethodChannel('com.nkshub.nextcloudtalk/clipboard_image');
const _maximumBytes = 25 * 1024 * 1024;
const _card = Key('clipboard-image-offer');
const _picture = Key('clipboard-image-offer-attach');
const _field = Key('field');

void _log(String line) => debugPrint('CLIPTEST $line');

Future<Uint8List> _png(int width, int height, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<String> _sizeOf(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = '${frame.image.width}x${frame.image.height}';
  frame.image.dispose();
  codec.dispose();
  return size;
}

Future<String?> _peek() => _channel.invokeMethod<String>('peek');

/// Polls `peek` until [done] accepts its answer and returns that answer.
Future<String?> _until(String what, bool Function(String? id) done) async {
  final watch = Stopwatch()..start();
  var polls = 0;
  while (true) {
    final id = await _peek();
    polls++;
    if (done(id)) {
      _log('$what: peek=$id after $polls peeks');
      return id;
    }
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail('$what did not show up, last peek=$id');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

Future<Uint8List?> _read(
  String what, {
  int maximumBytes = _maximumBytes,
}) async {
  final watch = Stopwatch()..start();
  final bytes = await _channel.invokeMethod<Uint8List>('read', maximumBytes);
  final size = bytes == null ? 'none' : await _sizeOf(bytes);
  _log(
    '$what: read took ${watch.elapsedMilliseconds} ms, '
    'bytes=${bytes?.length}, decoded=$size',
  );
  return bytes;
}

/// The real iOS source, with a count of what the suggestion asks of it and
/// how long each read was held, which is how a paste alert waiting for an
/// answer shows from the inside.
final class _CountedSource implements ClipboardImageSource {
  final ClipboardImageSource _source = ChannelClipboardImageSource.ios;
  int peeks = 0;
  int reads = 0;
  int answered = 0;

  @override
  Future<String?> peek() {
    peeks++;
    return _source.peek();
  }

  @override
  Future<Uint8List?> read() async {
    final number = ++reads;
    final watch = Stopwatch()..start();
    Uint8List? bytes;
    try {
      bytes = await _source.read();
      return bytes;
    } finally {
      answered++;
      _log(
        'read $number answered after ${watch.elapsedMilliseconds} ms, '
        'bytes=${bytes?.length}',
      );
    }
  }

  @override
  bool survivesRestart(String id) => _source.survivesRestart(id);

  @override
  Listenable? get changes => _source.changes;

  @override
  bool get readNeedsConsent => _source.readNeedsConsent;

  @override
  bool get offersWhileVisible => _source.offersWhileVisible;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FocusNode focus;
  late ValueNotifier<bool> blocked;
  late List<PastedImage> attached;
  late Directory memory;

  setUp(() {
    ClipboardImageOffer.debugForgetHandledClip();
    focus = FocusNode();
    blocked = ValueNotifier<bool>(false);
    attached = <PastedImage>[];
    memory = Directory.systemTemp.createTempSync('nctalk-ios-clipboard-');
  });

  tearDown(() {
    blocked.dispose();
    memory.deleteSync(recursive: true);
  });

  Future<void> pumpComposer(
    WidgetTester tester,
    ClipboardImageSource source,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clipboardImageSourceProvider.overrideWithValue(source),
          clipboardOfferMemoryProvider.overrideWithValue(
            ClipboardOfferMemory(directory: memory),
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox.expand()),
                ClipboardImageOffer(
                  focusNode: focus,
                  blocked: () => blocked.value,
                  refresh: blocked,
                  sending: false,
                  onAttach: (image) async {
                    attached.add(image);
                    return true;
                  },
                  onSend: () => fail('a tile without a preview sent'),
                ),
                TextField(key: _field, focusNode: focus),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(focus.hasFocus, isFalse);
  }

  /// Pumps real frames until [done] holds.
  Future<void> waitFor(
    WidgetTester tester,
    String what,
    bool Function() done, {
    Duration limit = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    while (!done()) {
      if (watch.elapsed > limit) {
        fail('$what: not within $limit');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    _log('$what after ${watch.elapsedMilliseconds} ms');
  }

  Future<void> shot(WidgetTester tester, String name) async {
    _log('SHOT $name');
    // Room for the screenshot taken outside the app.
    await tester.pump(const Duration(seconds: 3));
  }

  int tiles() => find.byKey(_card).evaluate().length;

  /// The clip the tile on show stands for; while one tile replaces another
  /// both are there for a moment, and the incoming one is the last. Reads
  /// the element tree only, so a timer may ask between two pumps.
  String? tileId() {
    final cards = find.byKey(_card).evaluate();
    if (cards.isEmpty) {
      return null;
    }
    String? id;
    cards.last.visitAncestorElements((element) {
      final key = element.widget.key;
      if (element.widget is TextFieldTapRegion && key is ValueKey<String>) {
        id = key.value;
        return false;
      }
      return true;
    });
    return id;
  }

  /// Waits for a tile that stands for the clip on the pasteboard right now
  /// and that [accept] takes.
  Future<String> waitForCurrentTile(
    WidgetTester tester,
    ClipboardImageSource source,
    String what, {
    bool Function(String id)? accept,
    Duration limit = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    while (true) {
      await tester.pump(const Duration(milliseconds: 200));
      final shown = tileId();
      if (tiles() == 1 &&
          shown != null &&
          (accept?.call(shown) ?? true) &&
          shown == await source.peek()) {
        _log('$what: tile=$shown after ${watch.elapsedMilliseconds} ms');
        return shown;
      }
      if (watch.elapsed > limit) {
        fail('$what: not within $limit, tile=$shown');
      }
    }
  }

  void expectTileWithoutPreview() {
    final card = find.byKey(_card).last;
    expect(
      find.descendant(of: card, matching: find.byType(RawImage)),
      findsNothing,
      reason: 'nothing of the clip was read, so there is no preview',
    );
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.image_outlined)),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('clipboard-image-offer-send')),
      findsNothing,
      reason: 'a picture nobody has seen is not sent from the tile',
    );
  }

  testWidgets(
    'the iOS clipboard image channel names and returns the clip',
    (tester) async {
      var changed = 0;
      void count() => changed++;
      final changes = ChannelClipboardImageSource.ios.changes;
      changes.addListener(count);
      addTearDown(() => changes.removeListener(count));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('clipboard image channel'))),
        ),
      );

      await Pasteboard.writeImage(
        await _png(40, 30, const ui.Color(0xffcc2200)),
      );
      final first = await _until('image A 40x30', (id) => id != null);
      expect(first, startsWith('ios-'));
      expect(await _sizeOf((await _read('image A'))!), '40x30');
      expect(
        await _read('image A capped at 10 bytes', maximumBytes: 10),
        isNull,
      );

      await Pasteboard.writeImage(
        await _png(64, 48, const ui.Color(0xff0044cc)),
      );
      final second = await _until(
        'image B 64x48',
        (id) => id != null && id != first,
      );
      expect(await _sizeOf((await _read('image B'))!), '64x48');

      await Clipboard.setData(const ClipboardData(text: 'plain text'));
      await _until('text only', (id) => id == null);
      expect(await _read('text only'), isNull);

      _log('ids: $first -> $second, changed calls=$changed');
      // A copy made by the app itself is announced right away.
      expect(changed, greaterThan(0));
    },
    skip: _external || !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'the tile follows the iOS pasteboard and reads the image only when '
    'tapped',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(clipboardImageSourceProvider),
        same(ChannelClipboardImageSource.ios),
      );

      final source = _CountedSource();
      await Clipboard.setData(const ClipboardData(text: 'before'));
      await pumpComposer(tester, source);
      await waitFor(tester, 'field focused', () => focus.hasFocus);
      expect(tiles(), 0);

      await Pasteboard.writeImage(
        await _png(120, 80, const ui.Color(0xffcc2200)),
      );
      await waitFor(tester, 'tile for a copied image', () => tiles() == 1);
      expectTileWithoutPreview();
      expect(source.reads, 0, reason: 'showing the tile reads nothing');
      await shot(tester, 'own-1-tile-without-preview');

      await Clipboard.setData(const ClipboardData(text: 'plain text'));
      await waitFor(tester, 'text hides the tile', () => tiles() == 0);
      await shot(tester, 'own-2-text-hides-tile');

      await Pasteboard.writeImage(
        await _png(200, 100, const ui.Color(0xff00aa44)),
      );
      await waitFor(tester, 'tile for image A', () => tiles() == 1);
      final a = tileId();
      await Pasteboard.writeImage(
        await _png(90, 160, const ui.Color(0xff0044cc)),
      );
      await waitFor(
        tester,
        'image B replaces the tile',
        () => tiles() == 1 && tileId() != a,
      );
      expect(tileId(), await source.peek());
      expectTileWithoutPreview();
      expect(source.reads, 0);
      await shot(tester, 'own-3-new-image-replaces-tile');

      await tester.tap(find.byKey(_picture));
      await waitFor(
        tester,
        'tap hands the image over',
        () => attached.isNotEmpty,
      );
      expect(source.reads, 1);
      expect(attached, hasLength(1));
      expect(await _sizeOf(attached.single.bytes), '90x160');
      _log(
        'attached ${attached.single.mimeType}, '
        '${attached.single.bytes.length} bytes',
      );
      await waitFor(tester, 'answered tile gone', () => tiles() == 0);
      await shot(tester, 'own-4-attached');
    },
    skip: _external || !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'a clip from another app: the tile asks nothing, the tap raises the paste '
    'alert, a refusal keeps the tile, consent attaches the image, and the '
    'field taking the focus again leaves the clip as it was',
    (tester) async {
      var changed = 0;
      void count() => changed++;
      final changes = ChannelClipboardImageSource.ios.changes;
      changes.addListener(count);
      addTearDown(() => changes.removeListener(count));

      // What the tile, the clip and the app do between the steps, logged
      // whenever one of them moves.
      final clock = Stopwatch()..start();
      var watched = '';
      final watch = Timer.periodic(const Duration(milliseconds: 150), (
        _,
      ) async {
        final clip = await ChannelClipboardImageSource.ios.peek();
        final now =
            'tile=${tileId()} clip=$clip changed=$changed '
            'life=${WidgetsBinding.instance.lifecycleState?.name}';
        if (now != watched) {
          watched = now;
          _log('watch +${clock.elapsedMilliseconds} ms $now');
        }
      });
      addTearDown(watch.cancel);

      final failures = <String>[];
      void check(bool ok, String what) {
        _log('CHECK ${ok ? 'ok' : 'FAILED'}: $what');
        if (!ok) {
          failures.add(what);
        }
      }

      /// Whether [holds] keeps holding for [period].
      Future<bool> steady(
        WidgetTester tester,
        bool Function() holds, {
        Duration period = const Duration(seconds: 3),
      }) async {
        final end = DateTime.now().add(period);
        while (DateTime.now().isBefore(end)) {
          if (!holds()) {
            return false;
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        return holds();
      }

      Future<void> refocus(WidgetTester tester) async {
        focus.unfocus();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byKey(_field));
        await waitFor(tester, 'field focused again', () => focus.hasFocus);
        // The keyboard is on its way up.
        await tester.pump(const Duration(milliseconds: 1500));
      }

      int number(String id) => int.parse(id.substring('ios-'.length));

      final source = _CountedSource();
      await pumpComposer(tester, source);
      await waitFor(tester, 'field focused', () => focus.hasFocus);
      // The keyboard is on its way up.
      await tester.pump(const Duration(milliseconds: 1500));
      final before = await source.peek();
      _log('before the copy: peek=$before');

      _log('ACT copy-a: copy an image in another app, then come back');
      final id = await waitForCurrentTile(
        tester,
        source,
        'tile for the image copied in Safari',
        accept: (id) => before == null || number(id) > number(before),
        limit: const Duration(minutes: 4),
      );
      _log('back in the app: focus=${focus.hasFocus}, changed=$changed');
      expectTileWithoutPreview();
      expect(source.reads, 0, reason: 'showing the tile reads nothing');
      // More looks at the clip; none of them may raise the alert.
      for (var look = 0; look < 5; look++) {
        await source.peek();
      }
      _log('peeks=${source.peeks} reads=${source.reads}');
      await shot(tester, 'ext-1-tile-after-peeks');
      expect(source.reads, 0);

      // The message field taking the focus again changes nothing about the
      // clip, so the tile on show still stands for it and a tap takes it.
      await refocus(tester);
      final shown = tileId();
      final clip = await source.peek();
      check(
        tiles() == 1 && shown == clip,
        'after the field took the focus again the tile $shown still names '
        'the clip $clip',
      );

      _log("ACT deny: answer the paste alert with Don't Allow");
      await tester.tap(find.byKey(_picture));
      await waitFor(
        tester,
        'refused read answered',
        () => source.answered == 1,
        limit: const Duration(seconds: 30),
      );
      final back = await waitForCurrentTile(
        tester,
        source,
        'tile back after the refusal',
      );
      expect(attached, isEmpty);
      check(
        await steady(tester, () => tiles() == 1 && tileId() == back),
        'after the refusal the tile $back stays on show',
      );
      _log('refused: reads=${source.reads}, first tile was $id');
      await shot(tester, 'ext-3-refused-tile-back');

      _log('ACT allow: answer the paste alert with Allow Paste');
      await tester.tap(find.byKey(_picture));
      await waitFor(
        tester,
        'image attached after consent',
        () => attached.isNotEmpty,
        limit: const Duration(seconds: 30),
      );
      expect(await _sizeOf(attached.single.bytes), '600x400');
      _log(
        'attached ${attached.single.mimeType}, '
        '${attached.single.bytes.length} bytes, reads=${source.reads}',
      );
      await waitFor(tester, 'answered tile gone', () => tiles() == 0);
      check(
        await steady(tester, () => tiles() == 0),
        'the attached clip is not offered again',
      );
      await shot(tester, 'ext-5-attached');

      final answered = await source.peek();
      _log('ACT copy-b: copy another image in another app, come back');
      final second = await waitForCurrentTile(
        tester,
        source,
        'tile for the second image copied in Safari',
        accept: (id) => answered == null || number(id) > number(answered),
        limit: const Duration(minutes: 4),
      );
      await shot(tester, 'ext-6-second-copy');
      await tester.tap(find.byKey(const Key('clipboard-image-offer-dismiss')));
      await waitFor(tester, 'dismissed tile gone', () => tiles() == 0);
      await refocus(tester);
      final afterRefocus = await source.peek();
      check(
        await steady(tester, () => tiles() == 0),
        'the dismissed clip $second stays dismissed when the field takes '
        'the focus again (clip now $afterRefocus)',
      );
      await shot(tester, 'ext-7-dismissed-stays');

      _log('peeks=${source.peeks} reads=${source.reads} changed=$changed');
      expect(failures, isEmpty);
    },
    skip: !_external || !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
