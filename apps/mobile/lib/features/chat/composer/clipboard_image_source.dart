import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Directory, File, Platform, sleep;
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

  /// True where the system asks the person before [read] may see the
  /// content. The suggestion is then shown without a preview and the image
  /// is read only once it is taken.
  bool get readNeedsConsent;

  /// True on a desktop, where the window stays on screen next to the program
  /// a screenshot is taken in. The suggestion then follows the clipboard
  /// while the window is visible, focused or not, and the message field need
  /// not hold the focus.
  bool get offersWhileVisible;
}

/// Null where the suggestion is off: macOS (the pasteboard is read on the
/// main thread and can wait on another device, see PasteboardProbeGuard) and
/// Linux.
final clipboardImageSourceProvider = Provider<ClipboardImageSource?>((ref) {
  // A widget test must not look at the clipboard of the machine it runs on.
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
    return null;
  }
  if (Platform.isAndroid) {
    return ChannelClipboardImageSource.android;
  }
  if (Platform.isIOS) {
    return ChannelClipboardImageSource.ios;
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

/// The app's own clipboard channel: on Android the clip description, which
/// costs no clipboard access notice, and on iOS whether the pasteboard holds
/// an image and its change count, which raise no paste prompt.
final class ChannelClipboardImageSource implements ClipboardImageSource {
  ChannelClipboardImageSource._({
    required this.readNeedsConsent,
    required this.idSurvivesRestart,
  }) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        _changes.value++;
      }
    });
  }

  // The clip's own timestamp does; the change count of a release without
  // one starts over with the process.
  static final ChannelClipboardImageSource android =
      ChannelClipboardImageSource._(
        readNeedsConsent: false,
        idSurvivesRestart: (id) => !id.startsWith('android-change-'),
      );

  // iOS asks the person before the app may see what another app put on the
  // pasteboard, so the picture is read only once the suggestion is taken.
  // The change count starts over when the device restarts.
  static final ChannelClipboardImageSource ios = ChannelClipboardImageSource._(
    readNeedsConsent: true,
    idSurvivesRestart: (id) => false,
  );

  static const _channel = MethodChannel(
    'com.nkshub.nextcloudtalk/clipboard_image',
  );

  final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  final bool Function(String id) idSurvivesRestart;

  @override
  final bool readNeedsConsent;

  @override
  Listenable get changes => _changes;

  @override
  bool get offersWhileVisible => false;

  @override
  Future<String?> peek() => _channel.invokeMethod<String>('peek');

  @override
  bool survivesRestart(String id) => idSurvivesRestart(id);

  @override
  Future<Uint8List?> read() =>
      _channel.invokeMethod<Uint8List>('read', clipboardImageMaximumBytes);
}

/// Reads the Windows clipboard through user32 directly: the sequence number
/// and the format list answer [peek] without opening the clipboard.
final class WindowsClipboardImageSource implements ClipboardImageSource {
  const WindowsClipboardImageSource();

  static final ClipboardSequenceWatch _watch = ClipboardSequenceWatch(
    _windowsClipboardSequence,
  );

  // A screenshot tool gives the window its focus back first and writes the
  // clipboard a moment later, so a look taken on focus alone still saw the
  // screenshot before it and offered that one.
  @override
  Listenable get changes => _watch;

  @override
  bool get readNeedsConsent => false;

  @override
  bool get offersWhileVisible => true;

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
    return 'windows-${_windowsClipboardSequence()}';
  }

  static Future<void> _lastRead = Future<void>.value();

  // One read at a time: a second one would find the clipboard still open by
  // the first and fail.
  // shortcut: an owner that never renders its promised bitmap keeps the
  // isolate, the clipboard it opened, and every later read waiting on it;
  // spawn a killable helper process if that ever shows up in the field.
  @override
  Future<Uint8List?> read() {
    final result = _lastRead.then(
      (_) => Isolate.run(
        () => _readWindowsBitmap(
          fileMaximumBytes: clipboardImageMaximumBytes,
          bitmapMaximumBytes: clipboardBitmapMaximumBytes,
        ),
      ),
    );
    _lastRead = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

final int Function() _windowsClipboardSequence =
    DynamicLibrary.open(
      'user32.dll',
    ).lookupFunction<Uint32 Function(), int Function()>(
      'GetClipboardSequenceNumber',
    );

/// Tells its listeners when a clipboard counter moved, by asking for it four
/// times a second while anybody listens. Reading the counter opens nothing
/// and touches no clipboard content.
final class ClipboardSequenceWatch extends ChangeNotifier {
  ClipboardSequenceWatch(
    this._read, {
    this.interval = const Duration(milliseconds: 250),
  });

  final int Function() _read;
  final Duration interval;
  Timer? _timer;
  int? _last;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(interval, (_) {
      final now = _read();
      final moved = _last != null && now != _last;
      _last = now;
      if (moved) {
        notifyListeners();
      }
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
      _last = null;
    }
  }
}

const int _cfDib = 8;
const int _cfUnicodeText = 13;

Uint8List? _readWindowsBitmap({
  required int fileMaximumBytes,
  required int bitmapMaximumBytes,
}) {
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final open = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
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
  final register = user32
      .lookupFunction<
        Uint32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)
      >('RegisterClipboardFormatA');
  final localAlloc = kernel32
      .lookupFunction<
        Pointer<Uint8> Function(Uint32, IntPtr),
        Pointer<Uint8> Function(int, int)
      >('LocalAlloc');
  final localFree = kernel32
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Uint8>),
        Pointer<Uint8> Function(Pointer<Uint8>)
      >('LocalFree');

  // A screenshot tool still holds the clipboard open for a moment after the
  // counter moved; giving up on the first refusal lost that screenshot.
  var opened = false;
  for (var attempt = 0; attempt < 20 && !opened; attempt++) {
    opened = open(0) != 0;
    if (!opened) {
      sleep(const Duration(milliseconds: 25));
    }
  }
  if (!opened) {
    return null;
  }
  try {
    Uint8List? copy(Pointer<Void> handle, int maximumBytes) {
      final length = size(handle);
      if (length <= 0 || length > maximumBytes) {
        return null;
      }
      final bytes = lock(handle);
      if (bytes == nullptr) {
        return null;
      }
      try {
        return Uint8List.fromList(bytes.asTypedList(length));
      } finally {
        unlock(handle);
      }
    }

    // The file a screenshot tool put there itself, when it did: smaller than
    // the bitmap and with nothing left to guess about its alpha channel.
    // "PNG" as a zero-terminated ANSI string in memory user32 can read.
    final name = localAlloc(0x40, 4);
    var png = 0;
    if (name != nullptr) {
      name.asTypedList(4).setAll(0, const [0x50, 0x4E, 0x47, 0]);
      png = register(name);
      localFree(name);
    }
    final file = png == 0 ? nullptr : data(png);
    if (file != nullptr) {
      // Too large as a file is too large to send; the bitmap is larger still.
      final bytes = copy(file, fileMaximumBytes);
      return bytes == null ? null : pngWithoutPadding(bytes);
    }
    final bitmap = data(_cfDib);
    final dib = bitmap == nullptr ? null : copy(bitmap, bitmapMaximumBytes);
    return dib == null ? null : bitmapFileFromDib(dib);
  } finally {
    close();
  }
}

/// [bytes] cut after the PNG end chunk. The size Windows reports for
/// clipboard memory may be larger than what the owner wrote, and the rest
/// would travel with the file.
Uint8List pngWithoutPadding(Uint8List bytes) {
  // IEND: its type, then the four bytes of its checksum.
  for (var index = bytes.length - 8; index >= 8; index--) {
    if (bytes[index] == 0x49 &&
        bytes[index + 1] == 0x45 &&
        bytes[index + 2] == 0x4E &&
        bytes[index + 3] == 0x44) {
      final end = index + 8;
      return end == bytes.length ? bytes : Uint8List.sublistView(bytes, 0, end);
    }
  }
  return bytes;
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
      // the longer V4/V5 headers carry them inside. A colour table may
      // follow even here, as a hint for palette displays.
      paletteEntries =
          (compression == 3 && headerSize == 40 ? 3 : 0) + colorsUsed;
    case 24:
      paletteEntries = colorsUsed;
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
