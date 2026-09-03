import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel the host activity answers on.
@visibleForTesting
const MethodChannel cameraPermissionChannel = MethodChannel(
  'com.nkshub.nextcloudtalk/camera_permission',
);

/// Whether the camera may be opened, asking the user once if never asked.
///
/// Android needs this: `camera_android_camerax` requests the permission itself
/// but never reports a refusal back to Dart — `CameraController.initialize()`
/// simply never completes, which would leave the scanner on a spinner with no
/// way out. Asking the platform directly is the only deterministic answer.
/// iOS surfaces the refusal through AVFoundation as a `CameraException`, so
/// there the plugin's own error is enough and this returns true unchanged.
Future<bool> ensureCameraPermission() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return true;
  }
  var status = await _status('status');
  if (status == 'notDetermined') {
    status = await _status('request');
  }
  return status == 'granted';
}

Future<String?> _status(String method) async {
  try {
    final response = await cameraPermissionChannel.invokeMapMethod<String, String>(
      method,
    );
    return response?['status'];
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
