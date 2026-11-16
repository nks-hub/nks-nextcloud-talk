@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_offer.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_source.dart';
import 'package:nextcloudtalk/features/chat/composer/pasted_image.dart';

import 'test_support.dart';

/// The suggestion against the real Windows clipboard: user32 and kernel32,
/// the reader isolate and the clipboard counter, with another process
/// writing the clipboard the way a screenshot tool does.
///
/// It replaces whatever the clipboard of the machine holds, so it runs only
/// where OWNTALK_LIVE_CLIPBOARD=1 is set: a test machine, never a desktop
/// somebody works at.
final _live = Platform.environment['OWNTALK_LIVE_CLIPBOARD'] == '1';

const _picture = Key('clipboard-image-offer-attach');

/// Puts a [width] x [height] picture on the clipboard from a separate
/// process, as a bitmap and, with [png], also in the registered "PNG" format
/// a screenshot tool adds; that PNG is also written to [pngFile]. With
/// [holdMs] the process then keeps the clipboard open that long, like an
/// owner still busy with it, and creates [heldMarker] once it holds it.
List<String> _imageScript(
  int width,
  int height, {
  bool png = false,
  File? pngFile,
  int holdMs = 0,
  File? heldMarker,
}) {
  final script = StringBuffer()
    ..writeln('Add-Type -AssemblyName System.Windows.Forms, System.Drawing')
    ..writeln('\$bmp = New-Object System.Drawing.Bitmap $width, $height')
    ..writeln('\$g = [System.Drawing.Graphics]::FromImage(\$bmp)')
    ..writeln(
      '\$g.Clear([System.Drawing.Color]::FromArgb(255, ${width % 256}, '
      '${height % 256}, 120))',
    )
    ..writeln('\$g.Dispose()')
    ..writeln('\$data = New-Object System.Windows.Forms.DataObject')
    ..writeln('\$data.SetImage(\$bmp)');
  if (png) {
    script
      ..writeln('\$ms = New-Object System.IO.MemoryStream')
      ..writeln('\$bmp.Save(\$ms, [System.Drawing.Imaging.ImageFormat]::Png)')
      ..writeln(
        "[System.IO.File]::WriteAllBytes('${pngFile!.path}', "
        '\$ms.ToArray())',
      )
      ..writeln("\$data.SetData('PNG', \$false, \$ms)");
  }
  script.writeln(
    '[System.Windows.Forms.Clipboard]::SetDataObject(\$data, \$true, 10, 100)',
  );
  if (holdMs > 0) {
    script
      ..writeln(
        "Add-Type -Namespace W -Name C -MemberDefinition '"
        '[DllImport("user32.dll")] public static extern bool '
        'OpenClipboard(System.IntPtr h); [DllImport("user32.dll")] '
        "public static extern bool CloseClipboard();'",
      )
      ..writeln('if ([W.C]::OpenClipboard([IntPtr]::Zero)) {')
      ..writeln("  Set-Content -Path '${heldMarker!.path}' -Value held")
      ..writeln('  Start-Sleep -Milliseconds $holdMs')
      ..writeln('  [W.C]::CloseClipboard() | Out-Null')
      ..writeln('}');
  }
  return ['-NoProfile', '-STA', '-Command', script.toString()];
}

Future<void> _writeImage(
  int width,
  int height, {
  bool png = false,
  File? pngFile,
}) async {
  final result = await Process.run(
    'powershell.exe',
    _imageScript(width, height, png: png, pngFile: pngFile),
  );
  if (result.exitCode != 0) {
    fail('powershell exit ${result.exitCode}: ${result.stderr}');
  }
}

Future<void> _writeText(String text) async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-STA',
    '-Command',
    "Set-Clipboard -Value '$text'",
  ]);
  if (result.exitCode != 0) {
    fail('powershell exit ${result.exitCode}: ${result.stderr}');
  }
}

void main() {
  late FocusNode focus;
  late ValueNotifier<bool> blocked;
  late List<PastedImage> attached;
  late Directory scratch;

  setUp(() {
    ClipboardImageOffer.debugForgetHandledClip();
    focus = FocusNode();
    blocked = ValueNotifier<bool>(false);
    attached = <PastedImage>[];
    scratch = Directory.systemTemp.createTempSync('nctalk-live-clipboard-');
  });

  tearDown(() {
    blocked.dispose();
    scratch.deleteSync(recursive: true);
  });

  Future<void> pumpComposer(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clipboardImageSourceProvider.overrideWithValue(
            const WindowsClipboardImageSource(),
          ),
          clipboardOfferMemoryProvider.overrideWithValue(
            ClipboardOfferMemory(directory: scratch),
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
                  onSend: () {},
                ),
                TextField(focusNode: focus),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Lets real time pass for the reader isolate, the image decoder and the
  /// other process, and fake time for the counter watch and retry delays,
  /// until [done] holds or [rounds] run out.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    int rounds = 60,
  }) async {
    for (var round = 0; round < rounds && !done(); round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// The picture on show; while one tile replaces another both are there
  /// for a moment, and the incoming one is the last.
  Size? pictureSize(WidgetTester tester) {
    final found = find.byKey(_picture);
    return found.evaluate().isEmpty ? null : tester.getSize(found.last);
  }

  testWidgets(
    'the newest screenshot replaces the one on show, also when it lands '
    'after the window got the focus back',
    (tester) async {
      await tester.runAsync(() => _writeImage(1600, 900));
      await pumpComposer(tester);
      await waitFor(tester, () => pictureSize(tester) != null);
      final first = pictureSize(tester);
      expect(first, isNotNull, reason: 'the first screenshot is offered');
      expect(first!.width, 220);
      expect(first.height, moreOrLessEquals(220 * 900 / 1600, epsilon: 0.5));

      // The screenshot tool takes the focus and gives it back before it
      // writes the clipboard.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.runAsync(() => _writeImage(400, 900));

      await waitFor(
        tester,
        () =>
            find.byKey(_picture).evaluate().length == 1 &&
            pictureSize(tester)?.height == 160,
      );
      final second = pictureSize(tester);
      // ignore: avoid_print
      print('LIVE first=$first second=$second');
      expect(second, const Size(72, 160), reason: 'the tall one is on show');
    },
    skip: !_live,
  );

  testWidgets(
    'a clipboard the owner still holds open is read once it lets go',
    (tester) async {
      await tester.runAsync(() => _writeText('before'));
      await pumpComposer(tester);
      await waitFor(tester, () => false, rounds: 6);
      expect(find.byKey(_picture), findsNothing);

      final held = File('${scratch.path}\\held.txt');
      // Started, not awaited: the process writes and then holds the
      // clipboard while the suggestion tries to read it.
      final writer = (await tester.runAsync(
        () => Process.start(
          'powershell.exe',
          _imageScript(800, 800, holdMs: 900, heldMarker: held),
        ),
      ))!;
      await waitFor(tester, () => pictureSize(tester) != null, rounds: 80);
      expect(await tester.runAsync(() => writer.exitCode), 0);
      // ignore: avoid_print
      print('LIVE held=${held.existsSync()} size=${pictureSize(tester)}');
      expect(held.existsSync(), isTrue, reason: 'the clipboard was held');
      expect(pictureSize(tester), const Size(160, 160));
    },
    skip: !_live,
  );

  testWidgets(
    'a clip with the PNG a screenshot tool adds is taken as that PNG',
    (tester) async {
      final png = File('${scratch.path}\\shot.png');
      await tester.runAsync(
        () => _writeImage(640, 360, png: true, pngFile: png),
      );
      await pumpComposer(tester);
      await waitFor(tester, () => pictureSize(tester) != null);
      expect(pictureSize(tester), isNotNull);

      await tester.tap(find.byKey(_picture));
      await waitFor(tester, () => attached.isNotEmpty, rounds: 20);
      expect(attached, hasLength(1));
      expect(attached.single.mimeType, 'image/png');
      expect(
        attached.single.bytes,
        png.readAsBytesSync(),
        reason: 'the PNG itself, not the bitmap encoded again',
      );

      await tester.runAsync(() => _writeText('after'));
      await waitFor(tester, () => pictureSize(tester) == null, rounds: 12);
      expect(find.byKey(_picture), findsNothing, reason: 'text hides it');
    },
    skip: !_live,
  );
}
