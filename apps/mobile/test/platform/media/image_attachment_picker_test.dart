import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' as platform_picker;
import 'package:nextcloudtalk/core/attachment_upload_telemetry.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
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

  group('PlatformAttachmentSelectionBackend', () {
    test('iOS gallery opens the native photo library', () async {
      var fileCalls = 0;
      final imageSources = <platform_picker.ImageSource>[];
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.iOS,
        isWeb: false,
        openFile: ({required imageOnly}) async {
          fileCalls++;
          return null;
        },
        pickImage: (source) async {
          imageSources.add(source);
          return XFile.fromData(
            _pngBytes,
            name: 'screenshot.png',
            mimeType: 'image/png',
          );
        },
      );

      final selected = await backend.selectImage(
        AttachmentPickerSource.gallery,
      );

      expect(fileCalls, 0);
      expect(imageSources, <platform_picker.ImageSource>[
        platform_picker.ImageSource.gallery,
      ]);
      expect(selected?.byteLength, _pngBytes.length);
    });

    test('desktop gallery keeps the filtered document picker', () async {
      final fileFilters = <bool>[];
      var imageCalls = 0;
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.windows,
        isWeb: false,
        openFile: ({required imageOnly}) async {
          fileFilters.add(imageOnly);
          return XFile.fromData(
            _pngBytes,
            name: 'desktop.png',
            mimeType: 'image/png',
          );
        },
        pickImage: (source) async {
          imageCalls++;
          return null;
        },
      );

      final selected = await backend.selectImage(
        AttachmentPickerSource.gallery,
      );

      expect(fileFilters, <bool>[true]);
      expect(imageCalls, 0);
      expect(selected?.byteLength, _pngBytes.length);
    });

    test('Android gallery keeps the filtered document picker', () async {
      final fileFilters = <bool>[];
      var imageCalls = 0;
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.android,
        isWeb: false,
        openFile: ({required imageOnly}) async {
          fileFilters.add(imageOnly);
          return XFile.fromData(_pngBytes, mimeType: 'image/png');
        },
        pickImage: (source) async {
          imageCalls++;
          return null;
        },
      );

      await backend.selectImage(AttachmentPickerSource.gallery);

      expect(fileFilters, <bool>[true]);
      expect(imageCalls, 0);
    });

    test('web never invokes the iOS photo picker', () async {
      final fileFilters = <bool>[];
      var imageCalls = 0;
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.iOS,
        isWeb: true,
        openFile: ({required imageOnly}) async {
          fileFilters.add(imageOnly);
          return null;
        },
        pickImage: (source) async {
          imageCalls++;
          return null;
        },
      );

      await backend.selectImage(AttachmentPickerSource.gallery);

      expect(fileFilters, <bool>[true]);
      expect(imageCalls, 0);
    });

    test('generic files stay on the unfiltered document picker', () async {
      final fileFilters = <bool>[];
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.iOS,
        isWeb: false,
        openFile: ({required imageOnly}) async {
          fileFilters.add(imageOnly);
          return null;
        },
        pickImage: (source) async => null,
      );

      await backend.selectImage(AttachmentPickerSource.file);

      expect(fileFilters, <bool>[false]);
    });

    test('camera selection keeps the native camera source', () async {
      final imageSources = <platform_picker.ImageSource>[];
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.iOS,
        isWeb: false,
        openFile: ({required imageOnly}) async => null,
        pickImage: (source) async {
          imageSources.add(source);
          return null;
        },
      );

      await backend.selectImage(AttachmentPickerSource.camera);

      expect(imageSources, <platform_picker.ImageSource>[
        platform_picker.ImageSource.camera,
      ]);
    });

    test('a refused photo library reports its own failure', () async {
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.iOS,
        isWeb: false,
        openFile: ({required imageOnly}) async => null,
        pickImage: (source) async =>
            throw PlatformException(code: 'photo_access_denied'),
      );

      await expectLater(
        backend.selectImage(AttachmentPickerSource.gallery),
        throwsA(
          isA<ImageAttachmentPickerException>().having(
            (error) => error.code,
            'code',
            ImageAttachmentPickerError.galleryPermissionDenied,
          ),
        ),
      );
    });

    test('a missing iOS photo plugin reports gallery unavailable', () async {
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.iOS,
        isWeb: false,
        openFile: ({required imageOnly}) async => null,
        pickImage: (source) async => throw MissingPluginException(),
      );

      await expectLater(
        backend.selectImage(AttachmentPickerSource.gallery),
        throwsA(
          isA<ImageAttachmentPickerException>().having(
            (error) => error.code,
            'code',
            ImageAttachmentPickerError.galleryUnavailable,
          ),
        ),
      );
    });
  });

  group('DurableImageAttachmentPicker', () {
    test(
      'returns null without creating a source when selection is cancelled',
      () async {
        final diagnostics = <AttachmentUploadDiagnostic>[];
        final picker = DurableImageAttachmentPicker(
          backend: _FakeImageSelectionBackend(null),
          store: store,
          maximumImageBytes: 64,
          reportDiagnostic: diagnostics.add,
        );

        expect(await picker.pick(), isNull);
        expect(
          await root.list(recursive: true).where((e) => e is File).toList(),
          isEmpty,
        );
        expect(
          diagnostics.map((event) => event.checkpoint),
          <AttachmentUploadCheckpoint>[
            AttachmentUploadCheckpoint.pickerPresented,
            AttachmentUploadCheckpoint.pickerCancelled,
          ],
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

    test('reports picker and durable copy boundaries in order', () async {
      final diagnostics = <AttachmentUploadDiagnostic>[];
      final picker = DurableImageAttachmentPicker(
        backend: _FakeImageSelectionBackend(
          ImageSelection(
            displayName: 'camera.png',
            declaredMimeType: 'image/png',
            byteLength: _pngBytes.length,
            openRead: ({int? start, int? end}) => Stream<List<int>>.value(
              _pngBytes.sublist(start ?? 0, end ?? _pngBytes.length),
            ),
          ),
        ),
        store: store,
        maximumImageBytes: 64,
        reportDiagnostic: diagnostics.add,
      );

      await picker.pick(source: AttachmentPickerSource.gallery);

      expect(
        diagnostics.map((event) => event.checkpoint),
        <AttachmentUploadCheckpoint>[
          AttachmentUploadCheckpoint.pickerPresented,
          AttachmentUploadCheckpoint.pickerReturned,
          AttachmentUploadCheckpoint.prefixRead,
          AttachmentUploadCheckpoint.durableCopyStarted,
          AttachmentUploadCheckpoint.durableCopyCompleted,
        ],
      );
      expect(
        diagnostics.map((event) => event.source).toSet(),
        <AttachmentUploadSource>{AttachmentUploadSource.gallery},
      );
    });

    test('cancelled durable copy is not reported as a failure', () async {
      final diagnostics = <AttachmentUploadDiagnostic>[];
      final cancellation = AttachmentCancellationController()..cancel();
      final picker = DurableImageAttachmentPicker(
        backend: _FakeImageSelectionBackend(
          ImageSelection(
            displayName: 'camera.png',
            declaredMimeType: 'image/png',
            byteLength: _pngBytes.length,
            openRead: ({int? start, int? end}) => Stream<List<int>>.value(
              _pngBytes.sublist(start ?? 0, end ?? _pngBytes.length),
            ),
          ),
        ),
        store: store,
        maximumImageBytes: 64,
        reportDiagnostic: diagnostics.add,
      );

      await expectLater(
        picker.pick(cancellationSignal: cancellation.signal),
        throwsA(
          isA<DurableAttachmentSourceException>().having(
            (error) => error.code,
            'code',
            DurableAttachmentSourceError.cancelled,
          ),
        ),
      );

      expect(diagnostics.last.checkpoint, AttachmentUploadCheckpoint.cancelled);
      expect(diagnostics.last.capturesEvent, isFalse);
    });

    test(
      'rejects declared oversize files before opening their stream',
      () async {
        var opens = 0;
        final diagnostics = <AttachmentUploadDiagnostic>[];
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
          reportDiagnostic: diagnostics.add,
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
        expect(
          diagnostics.last.checkpoint,
          AttachmentUploadCheckpoint.durableCopyFailed,
        );
        expect(
          diagnostics.last.failure,
          AttachmentUploadFailure.invalidSelection,
        );
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

    test(
      'asks the backend for the camera when that source is picked',
      () async {
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
      },
    );

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

final _pngBytes = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  1,
]);

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
