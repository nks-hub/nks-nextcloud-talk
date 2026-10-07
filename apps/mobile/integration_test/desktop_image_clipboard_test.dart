@TestOn('windows')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/features/chat/media/chat_image_exporter.dart';
import 'package:pasteboard/pasteboard.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('copied image can be read from the Windows clipboard', (_) async {
    final previousFiles = await Pasteboard.files();
    final previousImage = await Pasteboard.image;
    final previousText = await Pasteboard.text;
    addTearDown(() async {
      if (previousFiles.isNotEmpty) {
        await Pasteboard.writeFiles(previousFiles);
      } else if (previousImage != null) {
        await Pasteboard.writeImage(previousImage);
      } else {
        Pasteboard.writeText(previousText ?? '');
      }
    });
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..color = const ui.Color(0xffff0000),
    );
    canvas.drawRect(
      const ui.Rect.fromLTWH(1, 0, 1, 1),
      ui.Paint()..color = const ui.Color(0xff00ff00),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    const exporter = PlatformChatImageExporter();
    expect(
      await exporter.copyToClipboard(bytes: png!.buffer.asUint8List()),
      isTrue,
    );
    final pasted = await Pasteboard.image;
    expect(pasted, isNotNull);
    final codec = await ui.instantiateImageCodec(pasted!);
    final frame = await codec.getNextFrame();
    try {
      expect(frame.image.width, 2);
      expect(frame.image.height, 1);
      final pixels = await frame.image.toByteData();
      expect(pixels!.buffer.asUint8List(), [255, 0, 0, 255, 0, 255, 0, 255]);
    } finally {
      frame.image.dispose();
      codec.dispose();
    }
    expect(
      await exporter.copyToClipboard(bytes: Uint8List.fromList([1, 2, 3])),
      isFalse,
    );
    expect(await Pasteboard.image, isNotNull);
  });
}
