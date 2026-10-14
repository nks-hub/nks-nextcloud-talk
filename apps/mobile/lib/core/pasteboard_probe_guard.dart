import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Answers Flutter's "is there text to paste?" probe on macOS without reading
/// the pasteboard.
///
/// Every text field owns a ClipboardStatusNotifier, which asks the engine
/// `Clipboard.hasStrings` each time the app returns to the foreground. The
/// macOS engine answers with a synchronous `-[NSPasteboard stringForType:]` on
/// the main thread, and that call waits for whoever owns the pasteboard: an
/// iPhone over Universal Clipboard, or an app that promised its data lazily.
/// A tester's Mac froze right after coming back to the foreground with
/// exactly that frame on top. The probe only decides whether Paste is enabled
/// in the context menu, so it is answered "yes"; pasting an empty pasteboard
/// does nothing. A real paste still reads the pasteboard, when the user asked.
final class PasteboardProbeGuard implements BinaryMessenger {
  PasteboardProbeGuard(this._inner);

  final BinaryMessenger _inner;

  static const _codec = JSONMethodCodec();

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel == SystemChannels.platform.name &&
        message != null &&
        _codec.decodeMethodCall(message).method == 'Clipboard.hasStrings') {
      return Future.value(
        _codec.encodeSuccessEnvelope(const <String, Object?>{'value': true}),
      );
    }
    return _inner.send(channel, message);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      _inner.setMessageHandler(channel, handler);

  @override
  @Deprecated('Use ServicesBinding.instance.channelBuffers.push.')
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) =>
      // ignore: deprecated_member_use
      _inner.handlePlatformMessage(channel, data, callback);
}

/// The widgets binding with [PasteboardProbeGuard] in front of the engine.
/// Must be created before anything else asks for a binding.
final class PasteboardProbeBinding extends WidgetsFlutterBinding {
  /// Installs the binding on macOS, the only engine whose probe blocks.
  static void installOnMacOS() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      PasteboardProbeBinding();
    }
  }

  @override
  BinaryMessenger createBinaryMessenger() =>
      PasteboardProbeGuard(super.createBinaryMessenger());
}
