import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_source.dart';

/// A 1x1 PNG.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// A clipboard a test fills by hand, counting how often it is asked.
final class FakeClipboardImageSource implements ClipboardImageSource {
  String? _clip;
  Uint8List? _bytes;
  final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  int peeks = 0;
  int reads = 0;

  /// Whether a clip keeps its identity across an app restart.
  bool durable = true;

  @override
  bool survivesRestart(String id) => durable;

  /// When set, [read] never answers, like an owner that promised its data
  /// and went away.
  bool hangs = false;

  /// Puts an image clip on the clipboard; null [bytes] make it unreadable.
  void copyImage(String id, Uint8List? bytes) {
    _clip = id;
    _bytes = bytes;
    _changes.value++;
  }

  void copyText() {
    _clip = null;
    _bytes = null;
    _changes.value++;
  }

  @override
  Listenable get changes => _changes;

  @override
  Future<String?> peek() async {
    peeks++;
    return _clip;
  }

  @override
  Future<Uint8List?> read() {
    reads++;
    return hangs ? Completer<Uint8List?>().future : Future.value(_bytes);
  }
}
