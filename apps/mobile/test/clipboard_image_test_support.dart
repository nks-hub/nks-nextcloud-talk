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
  final _CountedNotifier _changes = _CountedNotifier();

  int peeks = 0;
  int reads = 0;

  /// Whether a clip keeps its identity across an app restart.
  bool durable = true;

  @override
  bool survivesRestart(String id) => durable;

  /// When set, [read] never answers, like an owner that promised its data
  /// and went away.
  bool hangs = false;

  /// How many reads answer null first, like a clipboard another program
  /// still holds open.
  int busyReads = 0;

  /// Runs inside [read] before the content is taken, like a program that
  /// writes the clipboard while it is being read.
  VoidCallback? duringRead;

  /// While set and not completed, [read] waits for it.
  Completer<void>? hold;

  /// How many listen to [changes] right now.
  int get listeners => _changes.count;

  /// Puts an image clip on the clipboard; null [bytes] make it unreadable.
  /// Without [notify] the change is not announced, as between two ticks of
  /// a polled clipboard.
  void copyImage(String id, Uint8List? bytes, {bool notify = true}) {
    _clip = id;
    _bytes = bytes;
    if (notify) {
      _changes.tell();
    }
  }

  void copyText() {
    _clip = null;
    _bytes = null;
    _changes.tell();
  }

  @override
  Listenable get changes => _changes;

  @override
  bool readNeedsConsent = false;

  @override
  bool offersWhileVisible = false;

  @override
  Future<String?> peek() async {
    peeks++;
    return _clip;
  }

  @override
  Future<Uint8List?> read() async {
    reads++;
    duringRead?.call();
    final bytes = _bytes;
    await hold?.future;
    if (busyReads > 0) {
      busyReads--;
      return null;
    }
    return hangs ? Completer<Uint8List?>().future : bytes;
  }
}

final class _CountedNotifier extends ChangeNotifier {
  int count = 0;

  void tell() => notifyListeners();

  @override
  void addListener(VoidCallback listener) {
    count++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    count--;
    super.removeListener(listener);
  }
}
