import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:nextcloudtalk/platform/media/image_attachment_picker.dart';

void main() {
  late Directory root;
  late DurableAttachmentSourceStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-image-picker-test-');
    store = DurableAttachmentSourceStore(root: root, maximumSourceBytes: 64);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('DurableImageAttachmentPicker', () {
    test(
      'returns null without creating a source when selection is cancelled',
      () async {
        final picker = DurableImageAttachmentPicker(
          backend: _FakeImageSelectionBackend(null),
          store: store,
          maximumImageBytes: 64,
        );

        expect(await picker.pick(), isNull);
        expect(
          await root.list(recursive: true).where((e) => e is File).toList(),
          isEmpty,
        );
      },
    );

    test(
      'detects image MIME and copies selected bytes into the store',
      () async {
        final bytes = <int>[
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
          1,
          2,
          3,
        ];
        final picker = DurableImageAttachmentPicker(
          backend: _FakeImageSelectionBackend(
            ImageSelection(
              displayName: 'camera.png',
              declaredMimeType: null,
              byteLength: bytes.length,
              openRead: ({int? start, int? end}) => Stream<List<int>>.value(
                bytes.sublist(start ?? 0, end ?? bytes.length),
              ),
            ),
          ),
          store: store,
          maximumImageBytes: 64,
        );

        final source = await picker.pick();

        expect(source, isNotNull);
        expect(source!.mimeType, 'image/png');
        expect(source.displayName, 'camera.png');
        expect((await store.observe(source.handle)).matches(source), isTrue);
      },
    );

    test(
      'rejects declared oversize files before opening their stream',
      () async {
        var opens = 0;
        final picker = DurableImageAttachmentPicker(
          backend: _FakeImageSelectionBackend(
            ImageSelection(
              displayName: 'large.png',
              declaredMimeType: 'image/png',
              byteLength: 65,
              openRead: ({int? start, int? end}) {
                opens++;
                return Stream<List<int>>.value(<int>[1]);
              },
            ),
          ),
          store: store,
          maximumImageBytes: 64,
        );

        await expectLater(
          picker.pick(),
          throwsA(
            isA<DurableAttachmentSourceException>().having(
              (error) => error.code,
              'code',
              DurableAttachmentSourceError.sourceTooLarge,
            ),
          ),
        );
        expect(opens, 0);
      },
    );

    test('rejects a selected non-image without persisting it', () async {
      final bytes = 'not an image'.codeUnits;
      final picker = DurableImageAttachmentPicker(
        backend: _FakeImageSelectionBackend(
          ImageSelection(
            displayName: 'notes.txt',
            declaredMimeType: 'text/plain',
            byteLength: bytes.length,
            openRead: ({int? start, int? end}) => Stream<List<int>>.value(
              bytes.sublist(start ?? 0, end ?? bytes.length),
            ),
          ),
        ),
        store: store,
        maximumImageBytes: 64,
      );

      await expectLater(
        picker.pick(),
        throwsA(
          isA<ImageAttachmentPickerException>().having(
            (error) => error.code,
            'code',
            ImageAttachmentPickerError.unsupportedType,
          ),
        ),
      );
      expect(
        await root.list(recursive: true).where((e) => e is File).toList(),
        isEmpty,
      );
    });

    test('keeps a non-image when the file source was chosen', () async {
      final bytes = 'not an image'.codeUnits;
      final backend = _FakeImageSelectionBackend(
        ImageSelection(
          displayName: 'notes.txt',
          declaredMimeType: 'Text/Plain; charset=utf-8',
          byteLength: bytes.length,
          openRead: ({int? start, int? end}) => Stream<List<int>>.value(
            bytes.sublist(start ?? 0, end ?? bytes.length),
          ),
        ),
      );
      final picker = DurableImageAttachmentPicker(
        backend: backend,
        store: store,
        maximumImageBytes: 64,
      );

      final source = await picker.pick(source: AttachmentPickerSource.file);

      expect(backend.requested, <AttachmentPickerSource>[
        AttachmentPickerSource.file,
      ]);
      expect(source, isNotNull);
      expect(source!.mimeType, 'text/plain');
      expect(source.displayName, 'notes.txt');
      expect((await store.observe(source.handle)).matches(source), isTrue);
    });

    test(
      'falls back to the generic MIME when the platform declares none',
      () async {
        final bytes = <int>[7, 7, 7, 7];
        final picker = DurableImageAttachmentPicker(
          backend: _FakeImageSelectionBackend(
            ImageSelection(
              displayName: 'blob.unknownext',
              declaredMimeType: 'definitely not a mime type',
              byteLength: bytes.length,
              openRead: ({int? start, int? end}) => Stream<List<int>>.value(
                bytes.sublist(start ?? 0, end ?? bytes.length),
              ),
            ),
          ),
          store: store,
          maximumImageBytes: 64,
        );

        final source = await picker.pick(source: AttachmentPickerSource.file);

        expect(source!.mimeType, 'application/octet-stream');
      },
    );

    test('asks the backend for the camera when that source is picked', () async {
      final bytes = <int>[0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];
      final backend = _FakeImageSelectionBackend(
        ImageSelection(
          displayName: 'shot.jpg',
          declaredMimeType: null,
          byteLength: bytes.length,
          openRead: ({int? start, int? end}) => Stream<List<int>>.value(
            bytes.sublist(start ?? 0, end ?? bytes.length),
          ),
        ),
      );
      final picker = DurableImageAttachmentPicker(
        backend: backend,
        store: store,
        maximumImageBytes: 64,
      );

      final source = await picker.pick(source: AttachmentPickerSource.camera);

      expect(backend.requested, <AttachmentPickerSource>[
        AttachmentPickerSource.camera,
      ]);
      expect(source!.mimeType, 'image/jpeg');
    });

    test('rejects a non-image the camera source returned', () async {
      final bytes = 'not an image'.codeUnits;
      final picker = DurableImageAttachmentPicker(
        backend: _FakeImageSelectionBackend(
          ImageSelection(
            displayName: 'notes.txt',
            declaredMimeType: 'text/plain',
            byteLength: bytes.length,
            openRead: ({int? start, int? end}) => Stream<List<int>>.value(
              bytes.sublist(start ?? 0, end ?? bytes.length),
            ),
          ),
        ),
        store: store,
        maximumImageBytes: 64,
      );

      await expectLater(
        picker.pick(source: AttachmentPickerSource.camera),
        throwsA(
          isA<ImageAttachmentPickerException>().having(
            (error) => error.code,
            'code',
            ImageAttachmentPickerError.unsupportedType,
          ),
        ),
      );
    });
  });
}

final class _FakeImageSelectionBackend implements ImageSelectionBackend {
  _FakeImageSelectionBackend(this.selection);

  final ImageSelection? selection;
  final List<AttachmentPickerSource> requested = <AttachmentPickerSource>[];

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) async {
    requested.add(source);
    return selection;
  }
}
