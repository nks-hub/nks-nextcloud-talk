import 'dart:async';

import 'package:flutter/services.dart';

final class IncomingShare {
  const IncomingShare({
    required this.id,
    required this.text,
    required this.file,
  });

  final String id;
  final String? text;
  final IncomingSharedFile? file;
}

final class IncomingSharedFile {
  const IncomingSharedFile({
    required this.path,
    required this.mimeType,
    required this.displayName,
    required this.byteLength,
    required this.sha256,
  });

  final String path;
  final String mimeType;
  final String displayName;
  final int byteLength;
  final String sha256;
}

abstract interface class IncomingSharePlatform {
  Stream<IncomingShare> get shareOpened;

  Future<IncomingShare?> getLaunchShare();

  Future<void> complete(String id);

  Future<void> dispose();
}

final class IncomingShareBridge implements IncomingSharePlatform {
  IncomingShareBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/share';

  final MethodChannel _channel;
  final StreamController<IncomingShare> _openedController =
      StreamController<IncomingShare>.broadcast();

  @override
  Stream<IncomingShare> get shareOpened => _openedController.stream;

  @override
  Future<IncomingShare?> getLaunchShare() async {
    final response = await _channel.invokeMethod<Object?>('getLaunchShare');
    return response == null ? null : parseIncomingShare(response);
  }

  @override
  Future<void> complete(String id) async {
    final completed = await _channel.invokeMethod<bool>('completeShare', {
      'id': id,
    });
    if (completed != true) {
      throw StateError('Incoming share was not present in the native inbox.');
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'shareOpened') {
      throw MissingPluginException('Unknown incoming share callback.');
    }
    _openedController.add(parseIncomingShare(call.arguments));
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _openedController.close();
  }
}

IncomingShare parseIncomingShare(Object? value) {
  if (value is! Map<Object?, Object?>) {
    throw const FormatException('Incoming share has an invalid shape.');
  }
  final id = _requiredString(value, 'id', maximumLength: 128);
  final text = _optionalString(value, 'text', maximumLength: 32768);
  final path = _optionalString(value, 'filePath', maximumLength: 4096);
  if (path == null) {
    if (text == null) {
      throw const FormatException('Incoming share is empty.');
    }
    return IncomingShare(id: id, text: text, file: null);
  }
  final mimeType = _requiredString(value, 'mimeType', maximumLength: 255);
  final displayName = _requiredString(value, 'displayName', maximumLength: 255);
  final byteLength = value['byteLength'];
  final sha256 = _requiredString(value, 'sha256', maximumLength: 64);
  if (byteLength is! int ||
      byteLength < 1 ||
      byteLength > 512 * 1024 * 1024 ||
      !_mimeTypePattern.hasMatch(mimeType) ||
      !_sha256Pattern.hasMatch(sha256) ||
      text != null && text.length > 4000) {
    throw const FormatException('Incoming shared file metadata is invalid.');
  }
  return IncomingShare(
    id: id,
    text: text,
    file: IncomingSharedFile(
      path: path,
      mimeType: mimeType,
      displayName: displayName,
      byteLength: byteLength,
      sha256: sha256,
    ),
  );
}

String _requiredString(
  Map<Object?, Object?> map,
  String key, {
  required int maximumLength,
}) {
  final value = _optionalString(map, key, maximumLength: maximumLength);
  if (value == null) {
    throw FormatException('Incoming share is missing $key.');
  }
  return value;
}

String? _optionalString(
  Map<Object?, Object?> map,
  String key, {
  required int maximumLength,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.contains('\u0000')) {
    throw FormatException('Incoming share has an invalid $key.');
  }
  return value;
}

final RegExp _mimeTypePattern = RegExp(
  r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$',
);
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
