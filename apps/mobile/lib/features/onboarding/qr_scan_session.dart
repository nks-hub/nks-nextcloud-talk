import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import '../../platform/camera_permission.dart';
import 'qr_login_decoder.dart';

/// Why a camera preview could not be opened.
enum QrScanFailure {
  /// The user has not granted camera access, or revoked it.
  permissionDenied,

  /// There is no usable camera on this device.
  unavailable,
}

final class QrScanException implements Exception {
  const QrScanException(this.failure);

  final QrScanFailure failure;

  @override
  String toString() => 'QrScanException(${failure.name})';
}

/// A running camera preview that reports every QR payload it reads.
abstract interface class QrScanSession {
  /// Raw scanned strings, in the order they were read.
  Stream<String> get payloads;

  Widget buildPreview();

  Future<void> close();
}

/// Opens a scan session, throwing [QrScanException] when it cannot.
typedef QrScanSessionOpener = Future<QrScanSession> Function();

/// One decode attempt per interval, so a stream of camera frames cannot pin
/// the CPU on a device that never sees a code.
const Duration _decodeInterval = Duration(milliseconds: 200);

Future<QrScanSession> openCameraQrScanSession() async {
  if (!await ensureCameraPermission()) {
    throw const QrScanException(QrScanFailure.permissionDenied);
  }
  final List<CameraDescription> cameras;
  try {
    cameras = await availableCameras();
  } on CameraException catch (error) {
    throw QrScanException(_failureFor(error));
  }
  if (cameras.isEmpty) {
    throw const QrScanException(QrScanFailure.unavailable);
  }
  final description = cameras.firstWhere(
    (camera) => camera.lensDirection == CameraLensDirection.back,
    orElse: () => cameras.first,
  );
  final controller = CameraController(
    description,
    // A code fills a good part of the frame, so the extra pixels of a higher
    // preset only cost decode time.
    ResolutionPreset.medium,
    enableAudio: false,
    imageFormatGroup: ImageFormatGroup.yuv420,
  );
  final session = _CameraQrScanSession(controller);
  try {
    await controller.initialize();
    await controller.startImageStream(session._onFrame);
  } on CameraException catch (error) {
    await session.close();
    throw QrScanException(_failureFor(error));
  } on Object {
    await session.close();
    throw const QrScanException(QrScanFailure.unavailable);
  }
  return session;
}

QrScanFailure _failureFor(CameraException error) {
  final code = error.code.toLowerCase();
  return code.contains('accessdenied') ||
          code.contains('accessrestricted') ||
          code.contains('permission')
      ? QrScanFailure.permissionDenied
      : QrScanFailure.unavailable;
}

final class _CameraQrScanSession implements QrScanSession {
  _CameraQrScanSession(this._controller);

  final CameraController _controller;
  final StreamController<String> _payloads = StreamController<String>();
  DateTime _lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;

  @override
  Stream<String> get payloads => _payloads.stream;

  @override
  Widget buildPreview() => CameraPreview(_controller);

  void _onFrame(CameraImage image) {
    if (_closed || image.planes.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastAttempt) < _decodeInterval) {
      return;
    }
    _lastAttempt = now;
    final plane = image.planes.first;
    // ponytail: decoding runs on this isolate. The preview is a platform
    // texture, so it keeps moving regardless, and the interval above bounds
    // the cost; move it to Isolate.run only if the overlay visibly stutters.
    final payload = decodeQrFromLuminance(
      luma: plane.bytes,
      width: image.width,
      height: image.height,
      bytesPerRow: plane.bytesPerRow,
    );
    if (payload != null && !_closed) {
      _payloads.add(payload);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }
    } on Object {
      // Tearing the camera down is best effort; the controller is disposed
      // either way and there is nothing the user could do about a failure.
    }
    await _controller.dispose();
    await _payloads.close();
  }
}
