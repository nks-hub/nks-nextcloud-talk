import 'dart:ffi';
import 'dart:io' show Directory, File, Platform;
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// The clipboard as the composer's paste suggestion sees it: first whether an
/// image is there, and only then the image itself.
abstract interface class ClipboardImageSource {
  /// Identifies the image now on the clipboard, or null when it holds none.
  ///
  /// Must not read the content: on Android that would raise the system
  /// "pasted from your clipboard" notice for something nobody asked to paste.
  /// A new copy has to produce a new value.
  Future<String?> peek();

  /// Whether [id] still names the same clip after the app was restarted, so
  /// an answer to it is worth remembering on disk.
  bool survivesRestart(String id);

  /// The image bytes, or null when they are gone, too large or unreadable.
  /// Runs off the UI thread and never hands back more than the cap.
  Future<Uint8List?> read();

  /// Fires when the clipboard got a new clip, where the platform says so
  /// without being polled.
  Listenable? get changes;
}

/// Null where the suggestion is off: iOS (any automatic pasteboard read shows
/// the system paste banner), macOS (the pasteboard is read on the main thread
/// and can wait on another device, see PasteboardProbeGuard) and Linux.
final clipboardImageSourceProvider = Provider<ClipboardImageSource?>((ref) {
  // A widget test must not look at the clipboard of the machine it runs on.
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
    return null;
  }
  if (Platform.isAndroid) {
    return AndroidClipboardImageSource.instance;
  }
  if (Platform.isWindows) {
    return const WindowsClipboardImageSource();
  }
  return null;
});

/// Keeps the clip the user last answered across launches: one line in the
/// application support directory, the clip's identity and nothing of its
/// content.
final class ClipboardOfferMemory {
  const ClipboardOfferMemory({this.directory});

  final Directory? directory;

  Future<File> _file() async {
    final target = directory ?? await getApplicationSupportDirectory();
    return File('${target.path}/clipboard_offer_answered.txt');
  }

  Future<String?> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return null;
      }
      final stored = (await file.readAsString()).trim();
      return stored.isEmpty ? null : stored;
    } on Object {
      // Forgetting costs one repeated suggestion.
      return null;
    }
  }

  Future<void> write(String id) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(id, flush: true);
    } on Object {
      // Same as above.
    }
  }
}

final clipboardOfferMemoryProvider = Provider<ClipboardOfferMemory>(
  (ref) => const ClipboardOfferMemory(),
);

/// An encoded image larger than this is not worth a suggestion.
const int clipboardImageMaximumBytes = 25 * 1024 * 1024;

/// Windows hands over the uncompressed bitmap, which is several times the
/// file that gets sent: a 4K screenshot is 33 MB raw and about 2 MB as PNG.
const int clipboardBitmapMaximumBytes = 80 * 1024 * 1024;

/// Asks the Android clip description, which costs no clipboard access notice.
final class AndroidClipboardImageSource implements ClipboardImageSource {
  AndroidClipboardImageSource._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        _changes.value++;
      }
    });
  }

  static final AndroidClipboardImageSource instance =
      AndroidClipboardImageSource._();

  static const _channel = MethodChannel(
    'com.nkshub.nextcloudtalk/clipboard_image',
  );

  final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  @override
  Listenable get changes => _changes;

  @override
  Future<String?> peek() => _channel.invokeMethod<String>('peek');

  // The clip's own timestamp does; the change count of a release without
  // one starts over with the process.
  @override
  bool survivesRestart(String id) => !id.startsWith('android-change-');

  @override
  Future<Uint8List?> read() =>
      _channel.invokeMethod<Uint8List>('read', clipboardImageMaximumBytes);
}

/// Reads the Windows clipboard through user32 directly: the sequence number
/// and the format list answer [peek] without opening the clipboard.
final class WindowsClipboardImageSource implements ClipboardImageSource {
  const WindowsClipboardImageSource();

  @override
  Listenable? get changes => null;

  // The sequence number starts over with the Windows session, so a stored
  // one could match an unrelated clip after a reboot.
  @override
  bool survivesRestart(String id) => false;

  @override
  Future<String?> peek() async {
    final user32 = DynamicLibrary.open('user32.dll');
    final available = user32
        .lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'IsClipboardFormatAvailable',
        );
    // A copied spreadsheet range or document also offers a bitmap rendering
    // of itself; with text beside it the copy was not meant as a picture.
    if (available(_cfDib) == 0 || available(_cfUnicodeText) != 0) {
      return null;
    }
    final sequence = user32
        .lookupFunction<Uint32 Function(), int Function()>(
          'GetClipboardSequenceNumber',
        );
    return 'windows-${sequence()}';
  }

  // shortcut: an owner that never renders its promised bitmap leaves this
  // isolate blocked for good (the caller times out and moves on); spawn a
  // killable helper process if that ever shows up in the field.
  @override
  Future<Uint8List?> read() =>
      Isolate.run(() => _readWindowsBitmap(clipboardBitmapMaximumBytes));
}

const int _cfDib = 8;
const int _cfUnicodeText = 13;

Uint8List? _readWindowsBitmap(int maximumBytes) {
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final open = user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'OpenClipboard',
      );
  final close = user32.lookupFunction<Int32 Function(), int Function()>(
    'CloseClipboard',
  );
  final data = user32
      .lookupFunction<
        Pointer<Void> Function(Uint32),
        Pointer<Void> Function(int)
      >('GetClipboardData');
  final size = kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('GlobalSize');
  final lock = kernel32
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)
      >('GlobalLock');
  final unlock = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('GlobalUnlock');

  if (open(0) == 0) {
    return null;
  }
  try {
    final handle = data(_cfDib);
    if (handle == nullptr) {
      return null;
    }
    final length = size(handle);
    if (length <= 0 || length > maximumBytes) {
      return null;
    }
    final bytes = lock(handle);
    if (bytes == nullptr) {
      return null;
    }
    try {
      return bitmapFileFromDib(Uint8List.fromList(bytes.asTypedList(length)));
    } finally {
      unlock(handle);
    }
  } finally {
    close();
  }
}

/// Puts the 14-byte file header in front of a clipboard DIB, which makes it
/// a BMP file an image decoder accepts. Null when the header is not one this
/// understands.
Uint8List? bitmapFileFromDib(Uint8List dib) {
  if (dib.length < 40) {
    return null;
  }
  final header = ByteData.sublistView(dib);
  final headerSize = header.getUint32(0, Endian.little);
  final bitCount = header.getUint16(14, Endian.little);
  final compression = header.getUint32(16, Endian.little);
  final colorsUsed = header.getUint32(32, Endian.little);
  final int paletteEntries;
  switch (bitCount) {
    case 1 || 4 || 8:
      paletteEntries = colorsUsed != 0 ? colorsUsed : 1 << bitCount;
    case 16 || 32:
      // BI_BITFIELDS keeps three colour masks after a plain 40-byte header;
      // the longer V4/V5 headers carry them inside.
      paletteEntries = compression == 3 && headerSize == 40 ? 3 : 0;
    case 24:
      paletteEntries = 0;
    default:
      return null;
  }
  final pixelOffset = 14 + headerSize + paletteEntries * 4;
  if (headerSize < 40 || pixelOffset > 14 + dib.length) {
    return null;
  }
  final file = Uint8List(14 + dib.length);
  ByteData.sublistView(file)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, file.length, Endian.little)
    ..setUint32(10, pixelOffset, Endian.little);
  file.setRange(14, file.length, dib);
  return file;
}
