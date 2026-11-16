@TestOn('ios')
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pasteboard/pasteboard.dart';

/// Off, the test copies the images itself, which iOS never asks about. On
/// (`--dart-define=CLIP_EXTERNAL=true`), it waits for somebody else to put
/// each clip on the pasteboard (`xcrun simctl pbsync host <device>`): that is
/// the clip from another app, the one the paste alert is about.
const _external = bool.fromEnvironment('CLIP_EXTERNAL');

const _channel = MethodChannel('com.nkshub.nextcloudtalk/clipboard_image');
const _maximumBytes = 25 * 1024 * 1024;

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
  _log('waiting for $what');
  final limit = _external
      ? const Duration(minutes: 5)
      : const Duration(seconds: 10);
  final watch = Stopwatch()..start();
  var polls = 0;
  while (true) {
    final id = await _peek();
    polls++;
    if (done(id)) {
      _log('$what: peek=$id after $polls peeks');
      return id;
    }
    if (watch.elapsed > limit) {
      fail('$what did not show up within $limit, last peek=$id');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Reads the clip and reports how long the call was held, which is how a
/// paste alert waiting for the user shows from the inside.
Future<Uint8List?> _read(
  String what, {
  int maximumBytes = _maximumBytes,
}) async {
  final watch = Stopwatch()..start();
  Uint8List? bytes;
  try {
    bytes = await _channel
        .invokeMethod<Uint8List>('read', maximumBytes)
        .timeout(const Duration(minutes: 3));
  } on TimeoutException {
    _log('$what: read still unanswered after ${watch.elapsed.inSeconds} s');
    rethrow;
  }
  final size = bytes == null ? 'none' : await _sizeOf(bytes);
  _log(
    '$what: read took ${watch.elapsedMilliseconds} ms, '
    'bytes=${bytes?.length}, decoded=$size',
  );
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the iOS clipboard image channel names and returns the clip', (
    tester,
  ) async {
    var changed = 0;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        changed++;
      }
    });
    addTearDown(() => _channel.setMethodCallHandler(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('clipboard image channel'))),
      ),
    );
    _log('mode=${_external ? 'external' : 'own'} copies');

    if (!_external) {
      await Pasteboard.writeImage(
        await _png(40, 30, const ui.Color(0xffcc2200)),
      );
    }
    final first = await _until('image A 40x30', (id) => id != null);
    expect(first, startsWith('ios-'));
    if (_external) {
      // Room for a screenshot that shows the peeks alone raised nothing.
      await Future<void>.delayed(const Duration(seconds: 25));
    }
    final firstBytes = await _read('image A');
    expect(await _sizeOf(firstBytes!), '40x30');
    if (_external) {
      await _read('image A again');
    } else {
      expect(
        await _read('image A capped at 10 bytes', maximumBytes: 10),
        isNull,
      );
    }

    if (!_external) {
      await Pasteboard.writeImage(
        await _png(64, 48, const ui.Color(0xff0044cc)),
      );
    }
    final second = await _until(
      'image B 64x48',
      (id) => id != null && id != first,
    );
    final secondBytes = await _read('image B');
    expect(await _sizeOf(secondBytes!), '64x48');

    if (!_external) {
      Pasteboard.writeText('plain text');
    }
    await _until('text only', (id) => id == null);
    expect(await _read('text only'), isNull);

    _log('ids: $first -> $second, changed calls=$changed');
    if (!_external) {
      // A copy made by the app itself is announced right away.
      expect(changed, greaterThan(0));
    }
  });
}
