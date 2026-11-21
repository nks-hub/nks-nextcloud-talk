import 'dart:async';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:image_picker/image_picker.dart' as platform_picker;
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;
import 'package:mime/mime.dart';
import 'package:nextcloudtalk/core/attachment_upload_telemetry.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:path/path.dart' as p;
import 'package:talk_protocol/talk_protocol.dart';

/// Where the bytes of an attachment come from. All three end up in the same
/// durable copy and follow the identical upload path; only the selection UI
/// and the accepted MIME types differ.
enum AttachmentPickerSource { gallery, camera, file }

enum ImageAttachmentPickerError {
  unsupportedType,
  invalidSelection,
  galleryPermissionDenied,
  galleryUnavailable,
  cameraPermissionDenied,
  cameraUnavailable,
}

final class ImageAttachmentPickerException implements Exception {
  const ImageAttachmentPickerException(this.code);

  final ImageAttachmentPickerError code;

  @override
  String toString() => 'ImageAttachmentPickerException(${code.name})';
}

typedef OpenSelectedImage = Stream<List<int>> Function({int? start, int? end});

final class ImageSelection {
  const ImageSelection({
    required this.displayName,
    required this.declaredMimeType,
    required this.byteLength,
    required this.openRead,
  });

  final String displayName;
  final String? declaredMimeType;
  final int byteLength;
  final OpenSelectedImage openRead;
}

abstract interface class ImageSelectionBackend {
  Future<ImageSelection?> selectImage(AttachmentPickerSource source);
}

abstract interface class MultipleImageSelectionBackend {
  Future<List<ImageSelection>> selectImages();
}

typedef OpenAttachmentFile = Future<XFile?> Function({required bool imageOnly});
typedef PickAttachmentImage =
    Future<XFile?> Function(platform_picker.ImageSource source);
typedef MeasureAttachmentFile = Future<int> Function(XFile file);

/// Photo batches use the native library on phones and file_selector on desktop.
final class PlatformAttachmentSelectionBackend
    implements ImageSelectionBackend, MultipleImageSelectionBackend {
  const PlatformAttachmentSelectionBackend()
    : _targetPlatform = null,
      _isWeb = null,
      _openFile = null,
      _pickImage = null,
      _measureFile = null;

  const PlatformAttachmentSelectionBackend._testing({
    required this._targetPlatform,
    required this._isWeb,
    required this._openFile,
    required this._pickImage,
    required this._measureFile,
  });

  @visibleForTesting
  static PlatformAttachmentSelectionBackend forTesting({
    required TargetPlatform targetPlatform,
    required bool isWeb,
    required OpenAttachmentFile openFile,
    required PickAttachmentImage pickImage,
    MeasureAttachmentFile? measureFile,
  }) => PlatformAttachmentSelectionBackend._testing(
    targetPlatform: targetPlatform,
    isWeb: isWeb,
    openFile: openFile,
    pickImage: pickImage,
    measureFile: measureFile,
  );

  static const _metadataConcurrency = 8;

  static const _imageTypes = XTypeGroup(
    label: 'Images',
    extensions: <String>[
      'avif',
      'bmp',
      'gif',
      'heic',
      'heif',
      'jpeg',
      'jpg',
      'png',
      'webp',
    ],
    mimeTypes: <String>[
      'image/avif',
      'image/bmp',
      'image/gif',
      'image/heic',
      'image/heif',
      'image/jpeg',
      'image/png',
      'image/webp',
    ],
    uniformTypeIdentifiers: <String>['public.image'],
    webWildCards: <String>['image/*'],
  );

  final TargetPlatform? _targetPlatform;
  final bool? _isWeb;
  final OpenAttachmentFile? _openFile;
  final PickAttachmentImage? _pickImage;
  final MeasureAttachmentFile? _measureFile;

  @override
  Future<List<ImageSelection>> selectImages() async {
    try {
      final platform = _targetPlatform ?? defaultTargetPlatform;
      final implementation = ImagePickerPlatform.instance;
      if (!(_isWeb ?? kIsWeb) &&
          platform == TargetPlatform.android &&
          implementation is ImagePickerAndroid) {
        implementation.useAndroidPhotoPicker = true;
      }
      final files =
          !(_isWeb ?? kIsWeb) &&
              (platform == TargetPlatform.iOS ||
                  platform == TargetPlatform.android)
          ? await platform_picker.ImagePicker().pickMultiImage()
          : await openFiles(acceptedTypeGroups: const [_imageTypes]);
      return _describeFiles(files);
    } on PlatformException catch (error) {
      throw ImageAttachmentPickerException(
        error.code == 'photo_access_denied' ||
                error.code == 'photo_access_restricted'
            ? ImageAttachmentPickerError.galleryPermissionDenied
            : ImageAttachmentPickerError.galleryUnavailable,
      );
    } on MissingPluginException {
      throw const ImageAttachmentPickerException(
        ImageAttachmentPickerError.galleryUnavailable,
      );
    }
  }

  Future<List<ImageSelection>> _describeFiles(List<XFile> files) async {
    final selections = List<ImageSelection?>.filled(files.length, null);
    final measure = _measureFile ?? (XFile file) => file.length();
    var nextFile = 0;

    Future<void> describeNext() async {
      while (nextFile < files.length) {
        final index = nextFile++;
        final file = files[index];
        selections[index] = ImageSelection(
          displayName: file.name,
          declaredMimeType: file.mimeType,
          byteLength: await measure(file),
          openRead: ({int? start, int? end}) => file.openRead(start, end),
        );
      }
    }

    final workerCount = files.length < _metadataConcurrency
        ? files.length
        : _metadataConcurrency;
    await Future.wait(List.generate(workerCount, (_) => describeNext()));
    return selections.cast<ImageSelection>();
  }

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) async {
    final file = switch (source) {
      AttachmentPickerSource.gallery => await _selectGallery(),
      AttachmentPickerSource.file => await _selectFile(imageOnly: false),
      AttachmentPickerSource.camera => await _selectImage(
        platform_picker.ImageSource.camera,
      ),
    };
    if (file == null) {
      return null;
    }
    return ImageSelection(
      displayName: file.name,
      declaredMimeType: file.mimeType,
      byteLength: await file.length(),
      openRead: ({int? start, int? end}) => file.openRead(start, end),
    );
  }

  Future<XFile?> _selectGallery() {
    final platform = _targetPlatform ?? defaultTargetPlatform;
    final web = _isWeb ?? kIsWeb;
    if (!web && platform == TargetPlatform.iOS) {
      return _selectImage(platform_picker.ImageSource.gallery);
    }
    return _selectFile(imageOnly: true);
  }

  Future<XFile?> _selectFile({required bool imageOnly}) {
    final injected = _openFile;
    if (injected != null) {
      return injected(imageOnly: imageOnly);
    }
    return imageOnly
        ? openFile(acceptedTypeGroups: const <XTypeGroup>[_imageTypes])
        : openFile();
  }

  Future<XFile?> _selectImage(platform_picker.ImageSource source) async {
    try {
      final injected = _pickImage;
      return injected != null
          ? await injected(source)
          : await platform_picker.ImagePicker().pickImage(source: source);
    } on PlatformException catch (error) {
      if (source == platform_picker.ImageSource.gallery) {
        throw ImageAttachmentPickerException(
          error.code == 'photo_access_denied' ||
                  error.code == 'photo_access_restricted'
              ? ImageAttachmentPickerError.galleryPermissionDenied
              : ImageAttachmentPickerError.galleryUnavailable,
        );
      }
      throw ImageAttachmentPickerException(
        error.code == 'camera_access_denied'
            ? ImageAttachmentPickerError.cameraPermissionDenied
            : ImageAttachmentPickerError.cameraUnavailable,
      );
    } on MissingPluginException {
      throw ImageAttachmentPickerException(
        source == platform_picker.ImageSource.gallery
            ? ImageAttachmentPickerError.galleryUnavailable
            : ImageAttachmentPickerError.cameraUnavailable,
      );
    }
  }
}

final class DurableImageAttachmentPicker {
  DurableImageAttachmentPicker({
    required this.backend,
    required this.store,
    required this.maximumImageBytes,
    this.reportDiagnostic = reportAttachmentUploadDiagnostic,
  }) {
    if (maximumImageBytes < 1 || maximumImageBytes > store.maximumSourceBytes) {
      throw ArgumentError.value(
        maximumImageBytes,
        'maximumImageBytes',
        'must be within the durable store limit',
      );
    }
  }

  final ImageSelectionBackend backend;
  final DurableAttachmentSourceStore store;
  final int maximumImageBytes;
  final ReportAttachmentUploadDiagnostic reportDiagnostic;

  /// Two streams hide storage latency without opening every selected photo at
  /// once on older phones.
  static const int _maximumConcurrentCopies = 2;

  /// [onSelected] reports how many images the gallery returned and
  /// [onCopied] each durable copy as it lands, so a caller can show every
  /// preview slot at once instead of after the last copy.
  Future<List<PreparedAttachmentSource>> pickImages({
    AttachmentCancellationSignal? cancellationSignal,
    void Function(int count)? onSelected,
    void Function(int index, PreparedAttachmentSource source)? onCopied,
  }) async {
    final selectionBackend = backend;
    if (selectionBackend is! MultipleImageSelectionBackend) {
      final image = await pick(cancellationSignal: cancellationSignal);
      return image == null ? [] : [image];
    }
    final selections = await (selectionBackend as MultipleImageSelectionBackend)
        .selectImages();
    onSelected?.call(selections.length);
    final sources = List<PreparedAttachmentSource?>.filled(
      selections.length,
      null,
    );
    final batchCancellation = AttachmentCancellationController();
    ({Object error, StackTrace stack})? firstFailure;
    var next = 0;

    Future<void> copyNext() async {
      while (firstFailure == null) {
        final index = next++;
        if (index >= selections.length) {
          return;
        }
        try {
          final source = await _copySelection(
            selections[index],
            imageOnly: true,
            diagnosticSource: AttachmentUploadSource.gallery,
            cancellationSignal: batchCancellation.signal,
          );
          sources[index] = source;
          if (firstFailure == null) {
            onCopied?.call(index, source);
          }
        } on Object catch (error, stack) {
          if (firstFailure == null) {
            firstFailure = (error: error, stack: stack);
            batchCancellation.cancel();
          }
        }
      }
    }

    final registration = cancellationSignal?.register(batchCancellation.cancel);
    try {
      await Future.wait(
        List<Future<void>>.generate(
          min(_maximumConcurrentCopies, selections.length),
          (_) => copyNext(),
        ),
      );
    } finally {
      registration?.detach();
    }
    final failure = firstFailure;
    if (failure != null) {
      try {
        await store.discardAll(sources.nonNulls.map((source) => source.handle));
      } on Object {
        // The picker failure is the useful error; cleanup was attempted for
        // every completed copy and must not replace it.
      }
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
    return [for (final source in sources) source!];
  }

  Future<PreparedAttachmentSource?> pick({
    AttachmentPickerSource source = AttachmentPickerSource.gallery,
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    final diagnosticSource = _diagnosticSource(source);
    reportDiagnostic(
      AttachmentUploadDiagnostic(
        checkpoint: AttachmentUploadCheckpoint.pickerPresented,
        source: diagnosticSource,
        uiPhase: AttachmentUploadUiPhase.preparing,
      ),
    );
    final ImageSelection? selection;
    try {
      selection = await backend.selectImage(source);
    } on ImageAttachmentPickerException catch (error) {
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.pickerFailed,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
          failure: _pickerFailure(error.code),
        ),
      );
      rethrow;
    } on Object {
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.pickerFailed,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
          failure: AttachmentUploadFailure.unknown,
        ),
      );
      rethrow;
    }
    if (selection == null) {
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.pickerCancelled,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
        ),
      );
      return null;
    }
    reportDiagnostic(
      AttachmentUploadDiagnostic(
        checkpoint: AttachmentUploadCheckpoint.pickerReturned,
        source: diagnosticSource,
        uiPhase: AttachmentUploadUiPhase.preparing,
      ),
    );
    return _copySelection(
      selection,
      imageOnly: source != AttachmentPickerSource.file,
      diagnosticSource: diagnosticSource,
      cancellationSignal: cancellationSignal,
    );
  }

  Future<PreparedAttachmentSource> copyFileSelection(
    ImageSelection selection, {
    AttachmentCancellationSignal? cancellationSignal,
  }) => _copySelection(
    selection,
    imageOnly: false,
    diagnosticSource: AttachmentUploadSource.file,
    cancellationSignal: cancellationSignal,
  );

  Future<PreparedAttachmentSource> _copySelection(
    ImageSelection selection, {
    required bool imageOnly,
    required AttachmentUploadSource diagnosticSource,
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    var failure = AttachmentUploadFailure.invalidSelection;
    try {
      if (selection.byteLength < 1) {
        throw const DurableAttachmentSourceException(
          DurableAttachmentSourceError.emptySource,
        );
      }
      if (selection.byteLength > maximumImageBytes) {
        throw const DurableAttachmentSourceException(
          DurableAttachmentSourceError.sourceTooLarge,
        );
      }
      final displayName = _safeDisplayName(
        selection.displayName,
        fallback: imageOnly ? 'image' : 'attachment',
      );
      failure = AttachmentUploadFailure.sourceRead;
      final header = await _readPrefix(
        selection.openRead(
          start: 0,
          end: min(selection.byteLength, defaultMagicNumbersMaxLength),
        ),
        defaultMagicNumbersMaxLength,
        cancellationSignal,
      );
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.prefixRead,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
        ),
      );
      final detected = lookupMimeType(displayName, headerBytes: header);
      final mimeType = _normalizeMimeType(
        detected ?? selection.declaredMimeType,
      );
      if (imageOnly && (mimeType == null || !mimeType.startsWith('image/'))) {
        throw const ImageAttachmentPickerException(
          ImageAttachmentPickerError.unsupportedType,
        );
      }
      failure = AttachmentUploadFailure.sourceCopy;
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.durableCopyStarted,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
        ),
      );
      final prepared = await store.copyFromStream(
        stream: selection.openRead(),
        expectedByteLength: selection.byteLength,
        // An unrecognised file still has to reach the server with a MIME type
        // that describes it honestly, so it falls back to the generic one
        // instead of borrowing whatever the platform guessed.
        mimeType: mimeType ?? 'application/octet-stream',
        displayName: displayName,
        cancellationSignal: cancellationSignal,
      );
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.durableCopyCompleted,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
        ),
      );
      return prepared;
    } on DurableAttachmentSourceException catch (error) {
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: error.code == DurableAttachmentSourceError.cancelled
              ? AttachmentUploadCheckpoint.cancelled
              : AttachmentUploadCheckpoint.durableCopyFailed,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
          failure: error.code == DurableAttachmentSourceError.cancelled
              ? AttachmentUploadFailure.none
              : _durableFailure(error.code),
        ),
      );
      rethrow;
    } on ImageAttachmentPickerException {
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.durableCopyFailed,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
          failure: AttachmentUploadFailure.invalidSelection,
        ),
      );
      rethrow;
    } on Object {
      reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.durableCopyFailed,
          source: diagnosticSource,
          uiPhase: AttachmentUploadUiPhase.preparing,
          failure: failure,
        ),
      );
      rethrow;
    }
  }
}

AttachmentUploadSource _diagnosticSource(AttachmentPickerSource source) =>
    switch (source) {
      AttachmentPickerSource.gallery => AttachmentUploadSource.gallery,
      AttachmentPickerSource.camera => AttachmentUploadSource.camera,
      AttachmentPickerSource.file => AttachmentUploadSource.file,
    };

AttachmentUploadFailure _pickerFailure(ImageAttachmentPickerError error) =>
    switch (error) {
      ImageAttachmentPickerError.galleryPermissionDenied ||
      ImageAttachmentPickerError.cameraPermissionDenied =>
        AttachmentUploadFailure.permission,
      ImageAttachmentPickerError.galleryUnavailable ||
      ImageAttachmentPickerError.cameraUnavailable =>
        AttachmentUploadFailure.unavailable,
      ImageAttachmentPickerError.unsupportedType ||
      ImageAttachmentPickerError.invalidSelection =>
        AttachmentUploadFailure.invalidSelection,
    };

AttachmentUploadFailure _durableFailure(DurableAttachmentSourceError error) =>
    switch (error) {
      DurableAttachmentSourceError.sourceTooLarge ||
      DurableAttachmentSourceError.emptySource ||
      DurableAttachmentSourceError.invalidHandle ||
      DurableAttachmentSourceError.sourceChanged =>
        AttachmentUploadFailure.invalidSelection,
      DurableAttachmentSourceError.sourceUnavailable =>
        AttachmentUploadFailure.sourceRead,
      DurableAttachmentSourceError.invalidWriteSession =>
        AttachmentUploadFailure.sourceCopy,
      DurableAttachmentSourceError.cancelled => AttachmentUploadFailure.none,
    };

Future<List<int>> _readPrefix(
  Stream<List<int>> stream,
  int maximum,
  AttachmentCancellationSignal? cancellationSignal,
) async {
  final bytes = <int>[];
  final iterator = StreamIterator<List<int>>(stream);
  Future<void>? cancelRead;
  final registration = cancellationSignal?.register(
    () => cancelRead ??= iterator.cancel(),
  );
  try {
    while (bytes.length < maximum && await iterator.moveNext()) {
      if (cancellationSignal?.isCancelled ?? false) break;
      final chunk = iterator.current;
      final remaining = maximum - bytes.length;
      bytes.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
    }
  } finally {
    registration?.detach();
    await (cancelRead ?? iterator.cancel());
  }
  if (cancellationSignal?.isCancelled ?? false) {
    throw const DurableAttachmentSourceException(
      DurableAttachmentSourceError.cancelled,
    );
  }
  return bytes;
}

final RegExp _mimeTypePattern = RegExp(
  r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$',
);

/// Drops parameters such as `; charset=utf-8` and rejects anything the
/// protocol layer would refuse, so a hostile or malformed platform MIME type
/// can never reach [PreparedAttachmentSource].
String? _normalizeMimeType(String? value) {
  if (value == null) {
    return null;
  }
  final essence = value.split(';').first.trim().toLowerCase();
  if (essence.length > 255 || !_mimeTypePattern.hasMatch(essence)) {
    return null;
  }
  return essence;
}

String _safeDisplayName(String value, {required String fallback}) {
  var name = p
      .basename(value)
      .trim()
      .replaceAll(RegExp(r'[\\/\x00-\x1f\x7f]'), '_');
  if (name.isEmpty || name == '.' || name == '..') {
    name = fallback;
  }
  if (name.length <= 255) {
    return name;
  }
  final extension = p.extension(name);
  final extensionLength = min(extension.length, 32);
  final suffix = extension.substring(extension.length - extensionLength);
  return '${name.substring(0, 255 - suffix.length)}$suffix';
}
