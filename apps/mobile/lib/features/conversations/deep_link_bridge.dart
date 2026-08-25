import 'dart:async';

import 'package:flutter/services.dart';

/// Platform-side entry point for account-scoped Talk room deep links, such
/// as `https://<server>/call/<token>` or `.../index.php/call/<token>`.
///
/// The platform layer only ever hands over the raw link; matching it to a
/// signed-in account and validating the room token happens in Dart.
abstract interface class DeepLinkPlatform {
  /// Emits every link opened while the Flutter engine is already running.
  Stream<Uri> get linkOpened;

  /// Returns the link that launched the app cold, if any. Native code
  /// queues it until this is first called, so it must only be read once.
  Future<Uri?> getLaunchLink();

  Future<void> dispose();
}

final class DeepLinkBridge implements DeepLinkPlatform {
  DeepLinkBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/deep_link';

  final MethodChannel _channel;
  final StreamController<Uri> _linkOpenedController =
      StreamController<Uri>.broadcast();

  @override
  Stream<Uri> get linkOpened => _linkOpenedController.stream;

  @override
  Future<Uri?> getLaunchLink() async {
    final response = await _channel.invokeMethod<Object?>('getLaunchLink');
    if (response == null) {
      return null;
    }
    return _parseUri(_requiredMap(response));
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'linkOpened':
        final uri = _parseUri(_requiredMap(call.arguments));
        if (uri != null) {
          _linkOpenedController.add(uri);
        }
      default:
        throw MissingPluginException('Unknown deep link callback.');
    }
  }

  Uri? _parseUri(Map<Object?, Object?> map) {
    final raw = map['uri'];
    return raw is String ? Uri.tryParse(raw) : null;
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _linkOpenedController.close();
  }
}

Map<Object?, Object?> _requiredMap(Object? value) {
  if (value is Map<Object?, Object?>) {
    return value;
  }
  throw const FormatException(
    'Native deep link response has an invalid shape.',
  );
}
