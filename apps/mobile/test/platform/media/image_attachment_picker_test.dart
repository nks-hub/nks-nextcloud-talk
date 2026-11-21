import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' as platform_picker;
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_android/src/messages.g.dart' as picker_wire;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;
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
    test('Android gallery requests the multi-photo system picker', () async {
      final paths = <String>[];
      for (var index = 0; index < 4; index++) {
        final file = File.fromUri(root.uri.resolve('photo-$index.png'));
        await file.writeAsBytes(_pngBytes);
        paths.add(file.path);
      }
      final api = _RecordingAndroidPicker(paths);
      final previous = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = ImagePickerAndroid(api: api);
      addTearDown(() => ImagePickerPlatform.instance = previous);
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.android,
        isWeb: false,
        openFile: ({required imageOnly}) async =>
            throw StateError('Single-file picker used'),
        pickImage: (_) async => throw StateError('Single-image picker used'),
      );
      final selected = await backend.selectImages();
      expect(api.source?.type, picker_wire.SourceType.gallery);
      expect(api.options?.allowMultiple, isTrue);
      expect(api.options?.usePhotoPicker, isTrue);
      expect(selected.map((image) => image.displayName), [
        'photo-0.png',
        'photo-1.png',
        'photo-2.png',
        'photo-3.png',
      ]);
    });

    test('selected photo metadata uses bounded concurrency', () async {
      const fileCount = 10;
      final paths = List.generate(
        fileCount,
        (index) => File.fromUri(root.uri.resolve('photo-$index.png')).path,
      );
      final api = _RecordingAndroidPicker(paths);
      final previous = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = ImagePickerAndroid(api: api);
      addTearDown(() => ImagePickerPlatform.instance = previous);
      final gates = <Completer<void>>[];
      final firstMeasurementStarted = Completer<void>();
      var inFlight = 0;
      var peakInFlight = 0;
      final backend = PlatformAttachmentSelectionBackend.forTesting(
        targetPlatform: TargetPlatform.android,
        isWeb: false,
        openFile: ({required imageOnly}) async =>
            throw StateError('Single-file picker used'),
        pickImage: (_) async => throw StateError('Single-image picker used'),
        measureFile: (file) async {
          final gate = Completer<void>();
          gates.add(gate);
          if (!firstMeasurementStarted.isCompleted) {
            firstMeasurementStarted.complete();
          }
          inFlight++;
          peakInFlight = max(peakInFlight, inFlight);
          await gate.future;
          inFlight--;
          return file.name.length;
        },
      );
      final selection = backend.selectImages();

      Future<List<ImageSelection>> releaseAll() async {
        while (gates.length < fileCount) {
          for (final gate in gates) {
            if (!gate.isCompleted) {
              gate.complete();
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        for (final gate in gates) {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
        return selection;
      }

      addTearDown(releaseAll);
      await firstMeasurementStarted.future;
      for (var turn = 0; turn < 20 && gates.length < 8; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(gates, hasLength(8));
      expect(peakInFlight, 8);

      gates.first.complete();
      for (var turn = 0; turn < 20 && gates.length < 9; turn++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(gates, hasLength(9));
      expect(peakInFlight, 8);

      final selected = await releaseAll();
      expect(selected.map((image) => image.displayName), [
        for (var index = 0; index < fileCount; index++) 'photo-$index.png',
      ]);
      expect(
        selected.map((image) => image.byteLength),
        selected.map((image) => image.displayName.length),
      );
    });

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
      'copies a gallery batch concurrently and preserves its order',
      () async {
        final gates = List.generate(5, (_) => Completer<void>());
        var inFlight = 0;
        var peak = 0;
        final selected = <int>[];
        final copied = <int>[];
        final selections = <ImageSelection>[
          for (var index = 0; index < gates.length; index++)
            ImageSelection(
              displayName: 'photo-$index.png',
              declaredMimeType: 'image/png',
              byteLength: _pngBytes.length,
              openRead: ({int? start, int? end}) {
                if (start != null || end != null) {
                  return Stream<List<int>>.value(
                    _pngBytes.sublist(start ?? 0, end ?? _pngBytes.length),
                  );
                }
                return (() async* {
                  inFlight++;
                  peak = peak > inFlight ? peak : inFlight;
                  try {
                    await gates[index].future;
                    yield _pngBytes;
                  } finally {
                    inFlight--;
                  }
                })();
              },
            ),
        ];
        final picker = DurableImageAttachmentPicker(
          backend: _FakeMultipleImageSelectionBackend(selections),
          store: store,
          maximumImageBytes: 64,
        );
        final future = picker.pickImages(
          onSelected: selected.add,
          onCopied: (index, _) => copied.add(index),
        );
        addTearDown(() async {
          for (final gate in gates) {
            if (!gate.isCompleted) gate.complete();
          }
          await future;
        });

        for (var turn = 0; turn < 20 && inFlight < 2; turn++) {
          await pumpEventQueue();
        }
        expect(inFlight, 2);

        // Let the second copy land first. Its callback carries the original
        // selection index while the returned list still keeps selection order.
        gates[1].complete();
        for (var turn = 0; turn < 20 && !copied.contains(1); turn++) {
          await pumpEventQueue();
        }
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
        final sources = await future;

        expect(peak, 2);
        expect(selected, <int>[5]);
        expect(copied.first, 1);
        expect(copied.toSet(), <int>{0, 1, 2, 3, 4});
        expect(sources.map((source) => source.displayName), <String>[
          'photo-0.png',
          'photo-1.png',
          'photo-2.png',
          'photo-3.png',
          'photo-4.png',
        ]);
      },
    );

    test('a failed gallery batch discards every completed copy', () async {
      ImageSelection selection(String name, List<int> bytes, String mimeType) {
        return ImageSelection(
          displayName: name,
          declaredMimeType: mimeType,
          byteLength: bytes.length,
          openRead: ({int? start, int? end}) => Stream<List<int>>.value(
            bytes.sublist(start ?? 0, end ?? bytes.length),
          ),
        );
      }

      final picker = DurableImageAttachmentPicker(
        backend: _FakeMultipleImageSelectionBackend([
          selection('photo.png', _pngBytes, 'image/png'),
          selection('notes.txt', 'not an image'.codeUnits, 'text/plain'),
        ]),
        store: store,
        maximumImageBytes: 64,
      );

      await expectLater(
        picker.pickImages(),
        throwsA(
          isA<ImageAttachmentPickerException>().having(
            (error) => error.code,
            'code',
            ImageAttachmentPickerError.unsupportedType,
          ),
        ),
      );

      expect(
        await root
            .list(recursive: true)
            .where((entry) => entry is File)
            .toList(),
        isEmpty,
      );
    });

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

    for (final stallAtPrefix in [false, true]) {
      final stage = stallAtPrefix ? 'prefix read' : 'durable copy';
      test('a gallery read failure cancels a sibling in $stage', () async {
        const deadline = Duration(seconds: 3);
        final stalledStarted = Completer<void>();
        final failingStarted = Completer<void>();
        final stalled = StreamController<List<int>>(
          onListen: stalledStarted.complete,
        );
        final failing = StreamController<List<int>>(
          onListen: failingStarted.complete,
        );
        ImageSelection photo(
          String name,
          Stream<List<int>> Function(bool prefix) read,
        ) => ImageSelection(
          displayName: name,
          declaredMimeType: 'image/png',
          byteLength: _pngBytes.length,
          openRead: ({start, end}) => read(end != null),
        );
        final picker = DurableImageAttachmentPicker(
          backend: _FakeMultipleImageSelectionBackend([
            photo('copied.png', (_) => Stream.value(_pngBytes)),
            photo('stalled.png', (prefix) {
              return prefix == stallAtPrefix
                  ? stalled.stream
                  : Stream.value(_pngBytes);
            }),
            photo('failed.png', (prefix) {
              return prefix ? Stream.value(_pngBytes) : failing.stream;
            }),
          ]),
          store: store,
          maximumImageBytes: 64,
        );
        final copied = <int>[];
        final picked = picker
            .pickImages(onCopied: (index, _) => copied.add(index))
            .then<(Object?, StackTrace?)>(
              (_) => (null, null),
              onError: (Object error, StackTrace stack) => (error, stack),
            );
        addTearDown(() async {
          unawaited(failing.close());
          unawaited(stalled.close());
          await picked;
        });

        await stalledStarted.future.timeout(deadline);
        await failingStarted.future.timeout(deadline);
        expect(copied, [0]);
        final error = StateError('Selected photo read failed');
        final stack = StackTrace.fromString('gallery source read');
        failing.addError(error, stack);

        final (failure, failureStack) = await picked.timeout(deadline);
        expect(failure, same(error));
        expect(failureStack.toString(), stack.toString());
        expect(stalled.hasListener, isFalse);
        expect(copied, [0]);
        expect(
          await root.list(recursive: true).where((e) => e is File).toList(),
          isEmpty,
        );
      });
    }

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

    test('user cancellation stops an active gallery copy', () async {
      const deadline = Duration(seconds: 3);
      final started = Completer<void>();
      final input = StreamController<List<int>>(onListen: started.complete);
      addTearDown(() async {
        if (started.isCompleted) await input.close();
      });
      final picker = DurableImageAttachmentPicker(
        backend: _FakeMultipleImageSelectionBackend([
          ImageSelection(
            displayName: 'photo.png',
            declaredMimeType: 'image/png',
            byteLength: _pngBytes.length,
            openRead: ({start, end}) =>
                end == null ? input.stream : Stream.value(_pngBytes),
          ),
        ]),
        store: store,
        maximumImageBytes: 64,
      );
      final cancellation = AttachmentCancellationController();
      final picked = expectLater(
        picker
            .pickImages(cancellationSignal: cancellation.signal)
            .timeout(deadline),
        throwsA(
          isA<DurableAttachmentSourceException>().having(
            (error) => error.code,
            'code',
            DurableAttachmentSourceError.cancelled,
          ),
        ),
      );

      await started.future.timeout(deadline);
      cancellation.cancel();
      await picked;

      expect(input.hasListener, isFalse);
      expect(
        await root.list(recursive: true).where((e) => e is File).toList(),
        isEmpty,
      );
    });

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

final class _FakeMultipleImageSelectionBackend
    implements ImageSelectionBackend, MultipleImageSelectionBackend {
  _FakeMultipleImageSelectionBackend(this.selections);

  final List<ImageSelection> selections;

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) =>
      throw StateError('Single selection used for a gallery batch');

  @override
  Future<List<ImageSelection>> selectImages() async => selections;
}

final class _RecordingAndroidPicker extends picker_wire.ImagePickerApi {
  _RecordingAndroidPicker(this.paths);

  final List<String> paths;
  picker_wire.SourceSpecification? source;
  picker_wire.GeneralOptions? options;

  @override
  Future<List<String>> pickImages(
    picker_wire.SourceSpecification source,
    picker_wire.ImageSelectionOptions selection,
    picker_wire.GeneralOptions options,
  ) async {
    this.source = source;
    this.options = options;
    return paths;
  }
}
