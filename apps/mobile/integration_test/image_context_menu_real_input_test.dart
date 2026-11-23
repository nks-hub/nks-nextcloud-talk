// A standalone app, not a `testWidgets` test: it is built with
// `flutter build windows -t integration_test/image_context_menu_real_input_test.dart`
// and run on a machine of its own, because it moves the real mouse.
//
// It shows the chat room with synthetic pictures (in memory, no account, no
// network, no app storage), sends REAL right clicks through user32 SendInput
// at the pictures and at the opened viewer, and writes down whether the picture
// menu came up. A journal and a PNG per case land next to the executable, and
// the process exits 0 when every case passed and 1 when any failed.
//
// With IMGMENU_SHELL=1 in the environment the chat is hosted inside the real
// application root (NextcloudTalkApp: shell, drop target, shortcuts, lock gate,
// update banner) instead of a bare room screen.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/stale_modifier_repair.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/chat/chat_background_surface.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_exporter.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_opener.dart';
import 'package:nextcloudtalk/features/chat/media/chat_image_exporter.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';
import 'package:talk_protocol/talk_protocol.dart';

late final Directory _out;
late final File _journalFile;
final _repaint = GlobalKey();
final _pointerSeen = <String>[];
final _opener = _RecordingOpen();
var _failures = 0;
final _shell = Platform.environment['IMGMENU_SHELL'] == '1';

void _note(String line) {
  final text = '${DateTime.now().toIso8601String()} $line';
  _journalFile.writeAsStringSync('$text\n', mode: FileMode.append);
  debugPrint('IMGMENU $text');
}

void _verdict(String name, bool pass, String detail) {
  if (!pass) _failures++;
  _note('${pass ? 'PASS' : 'FAIL'} $name: $detail');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _out = Directory(
    '${File(Platform.resolvedExecutable).parent.path}\\image-menu-run',
  )..createSync(recursive: true);
  _journalFile = File('${_out.path}\\journal.txt')..writeAsStringSync('');
  _note('start pid=$pid');
  unawaited(
    Future<void>.delayed(const Duration(seconds: 170), () {
      _note('WATCHDOG timeout');
      exit(2);
    }),
  );

  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final accounts = AccountRepository(database);
  final vault = _MemoryVault();
  final account = await accounts.upsertAccount(
    accountId: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    talkFeatures: const {},
    createdAt: DateTime.utc(2026, 1, 1),
  );
  vault.values[account.id] = 'fixture-password';
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: account.id,
          token: 'rooma123',
          displayName: 'Synthetic room A',
          description: '',
          lastActivity: 1724300000,
          unreadMessages: 0,
          favorite: false,
          readOnly: const Value(0),
          roomType: const Value(2),
          roomName: const Value('synthetic-room-a'),
          objectType: const Value(''),
          avatarVersion: const Value(''),
          isCustomAvatar: const Value(false),
          rawJson: '{}',
        ),
      );
  final conversation = await database
      .select(database.cachedConversations)
      .getSingle();
  final preview = await _solidPreview(320, 200);

  // 100 incoming single, 101 outgoing single, 102 incoming with caption,
  // 103 outgoing with caption, 110..113 an album.
  Future<void> add(Map<String, Object?> wire) => database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: account.id,
          roomToken: 'rooma123',
          messageId: wire['id']! as int,
          actorType: 'users',
          actorId: wire['actorId']! as String,
          actorDisplayName: wire['actorDisplayName']! as String,
          timestamp: wire['timestamp']! as int,
          systemMessage: '',
          messageType: 'comment',
          referenceId: wire['referenceId']! as String,
          displayText: wire['message']! as String,
          deleted: false,
          threadId: Value(wire['threadId'] as int?),
          rawJson: jsonEncode(wire),
        ),
      );
  await add(_textWire(99, 'Selectable sample text for the drag test'));
  await add(_imageWire(100, outgoing: false));
  await add(_imageWire(101, outgoing: true));
  await add(_imageWire(102, outgoing: false, caption: 'Nice photo'));
  await add(_imageWire(103, outgoing: true, caption: 'My photo'));
  for (var index = 0; index < 4; index++) {
    await add(_albumWire(110 + index, index));
  }

  final media = ChatMediaRepository(
    vault,
    client: MockClient(
      (request) async => http.Response.bytes(
        preview.body,
        200,
        headers: const {'content-type': 'image/png'},
      ),
    ),
    wait: (_) async {},
  );

  final overrides = [
    appDatabaseProvider.overrideWithValue(database),
    credentialVaultProvider.overrideWithValue(vault),
    chatBackgroundProvider.overrideWith(
      (ref, key) => Stream<String?>.value(null),
    ),
    connectivityWakeEventsProvider.overrideWithValue(
      const Stream<void>.empty(),
    ),
    chatAttachmentDependenciesProvider.overrideWith(
      (ref, key) => Future<ChatAttachmentDependencies>.error(
        StateError('attachments are not wired in this run'),
        StackTrace.empty,
      ),
    ),
    chatMediaProvider.overrideWith((ref, key) async => preview),
    chatMediaRepositoryProvider.overrideWithValue(media),
    chatImageExporterProvider.overrideWithValue(_NoImageExport()),
    chatAttachmentExportActionFactoryProvider.overrideWithValue(
      (_) => _NoSave(),
    ),
    chatAttachmentOpenActionFactoryProvider.overrideWithValue((_) => _opener),
    clientPushEnabledProvider.overrideWithValue(false),
  ];
  Widget watched(Widget child) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) => _pointerSeen.add(
      'down kind=${event.kind.name} buttons=${event.buttons} '
      'at=${event.position}',
    ),
    child: RepaintBoundary(key: _repaint, child: child),
  );
  if (_shell) {
    staleModifierRepair.attach();
    runApp(
      ProviderScope(
        overrides: overrides,
        child: watched(const NextcloudTalkApp()),
      ),
    );
  } else {
    runApp(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => watched(child!),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      ),
    );
  }
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
}

Future<void> _run() async {
  try {
    await _scenario();
  } on Object catch (error, stack) {
    _failures++;
    _note('FAIL harness: $error\n$stack');
  }
  _note('done failures=$_failures');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  exit(_failures == 0 ? 0 : 1);
}

Future<void> _scenario() async {
  final hwnd = _ownWindow();
  _note('window=$hwnd foreground=${_foreground() == hwnd}');
  _bringToFront(hwnd);
  await _frames(const Duration(seconds: 3));
  if (_shell) {
    _note('shell mode: opening the conversation with a real left click');
    await _waitFor(const Key('conversation-tile-rooma123'), 'the conversation');
    await _realClick(
      hwnd,
      await _centerOf(const Key('conversation-tile-rooma123')),
    );
  }
  await _waitFor(const Key('chat-image-112-0'), 'the album picture');
  await _frames(const Duration(seconds: 2));

  // First clicks after the window was just brought to the front.
  for (final id in [100, 101, 102, 103]) {
    await _pictureCase('single-$id', Key('chat-image-$id-0'), hwnd);
  }
  await _pictureCase('album-112', const Key('chat-image-112-0'), hwnd);

  // After a left click somewhere else.
  final header = find(const Key('chat-room-header'));
  if (header != null) {
    final box = header.renderObject! as RenderBox;
    await _realClick(
      hwnd,
      box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2)),
    );
    await _pictureCase(
      'after-left-click-elsewhere',
      const Key('chat-image-100-0'),
      hwnd,
    );
  }

  // The name and the caption under a picture belong to the bubble, not to the
  // picture: a menu must still open, offering the message actions.
  await _areaCase('file-name-area', hwnd, () async {
    await _reveal(const Key('chat-image-name-100-0'));
    return _centerOf(const Key('chat-image-name-100-0'));
  });
  await _areaCase('caption-area', hwnd, () async {
    await _reveal(const Key('chat-rich-content-102'));
    final box =
        find(const Key('chat-rich-content-102'))!.renderObject! as RenderBox;
    return box.localToGlobal(const Offset(24, 10));
  });

  // With text selected in another bubble.
  await _reveal(const Key('chat-rich-content-99'));
  final text =
      find(const Key('chat-rich-content-99'))!.renderObject! as RenderBox;
  final textOrigin = text.localToGlobal(Offset.zero);
  await _realDrag(
    hwnd,
    textOrigin + const Offset(2, 10),
    textOrigin + Offset(text.size.width - 4, 10),
  );
  await _frames(const Duration(milliseconds: 500));
  await _shot('text-selected');
  await _pictureCase('selection-active', const Key('chat-image-100-0'), hwnd);

  // The opened single picture, reached with a real left click.
  await _reveal(const Key('chat-image-100-0'));
  await _realClick(hwnd, await _centerOf(const Key('chat-image-100-0')));
  await _waitFor(
    const Key('authenticated-image-fullscreen'),
    'the opened picture',
  );
  await _frames(const Duration(seconds: 2));
  await _viewerCase('viewer-single', hwnd);
  await _realClick(hwnd, await _centerOf(const Key('authenticated-image-close')));
  await _frames(const Duration(seconds: 1));

  // The opened album at its second picture, then at the next one.
  await _reveal(const Key('chat-image-111-0'));
  await _realClick(hwnd, await _centerOf(const Key('chat-image-111-0')));
  await _waitFor(const Key('chat-gallery-pages'), 'the opened album');
  await _frames(const Duration(seconds: 2));
  await _viewerCase('viewer-album-first', hwnd, pickFile: 'photo-1.png');
  await _realClick(hwnd, await _centerOf(const Key('chat-gallery-next')));
  await _frames(const Duration(seconds: 2));
  _note('gallery position: ${_text(const Key('chat-gallery-position'))}');
  await _viewerCase('viewer-album-next', hwnd, pickFile: 'photo-2.png');
}

Future<void> _pictureCase(String name, Key image, int hwnd) async {
  await _reveal(image);
  final point = await _centerOf(image);
  _pointerSeen.clear();
  await _realClick(hwnd, point, right: true);
  final shown = await _waitForMaybe(
    const Key('message-action-save-image'),
    const Duration(seconds: 2),
  );
  await _frames(const Duration(milliseconds: 400));
  final sheet = _exists((w) => w is BottomSheet);
  final items = _menuKeys();
  await _shot(name);
  _verdict(
    name,
    shown && !sheet && items.contains('message-action-open-image'),
    'menu=$shown sheet=$sheet items=$items pointer=${_pointerSeen.join('; ')}',
  );
  await _dismiss(hwnd);
}

Future<void> _areaCase(
  String name,
  int hwnd,
  Future<Offset> Function() where,
) async {
  final point = await where();
  _pointerSeen.clear();
  await _realClick(hwnd, point, right: true);
  await _frames(const Duration(milliseconds: 900));
  final sheet = _exists((w) => w is BottomSheet);
  final items = _menuKeys();
  await _shot(name);
  _verdict(
    name,
    items.isNotEmpty && !sheet,
    'menu items=$items sheet=$sheet pointer=${_pointerSeen.join('; ')}',
  );
  await _dismiss(hwnd);
}

Future<void> _viewerCase(String name, int hwnd, {String? pickFile}) async {
  final target = find(const Key('authenticated-image-fullscreen')) ??
      find(const Key('chat-gallery-pages'));
  final box = target!.renderObject! as RenderBox;
  final point = box.localToGlobal(box.size.center(Offset.zero));
  _pointerSeen.clear();
  await _realClick(hwnd, point, right: true);
  final shown = await _waitForMaybe(
    const Key('message-action-forward'),
    const Duration(seconds: 2),
  );
  await _frames(const Duration(milliseconds: 400));
  final items = _menuKeys();
  await _shot(name);
  var pass =
      shown &&
      items.contains('message-action-save-image') &&
      items.contains('message-action-open-file');
  var detail =
      'menu=$shown items=$items pointer=${_pointerSeen.join('; ')}';
  if (shown && pickFile != null) {
    _opener.uris.clear();
    await _realClick(
      hwnd,
      await _centerOf(const Key('message-action-open-file')),
    );
    await _frames(const Duration(seconds: 1));
    final opened = _opener.uris.map((uri) => uri.path).toList();
    final right = opened.length == 1 && opened.single.endsWith(pickFile);
    pass = pass && right;
    detail += ' opened=$opened expected=$pickFile';
  } else if (shown) {
    await _dismiss(hwnd);
  }
  _verdict(name, pass, detail);
}

// ---- finding things ------------------------------------------------------

Element? find(Key key) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget.key == key) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return found;
}

bool _exists(bool Function(Widget) test) {
  var found = false;
  void visit(Element element) {
    if (found) return;
    if (test(element.widget)) {
      found = true;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return found;
}

List<String> _menuKeys() {
  final keys = <String>[];
  void visit(Element element) {
    final key = element.widget.key;
    if (key is ValueKey<String> &&
        key.value.startsWith('message-action-') &&
        element.widget is PopupMenuItem) {
      keys.add(key.value);
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return keys;
}

String? _text(Key key) {
  final element = find(key);
  return element == null ? null : (element.widget as Text).data;
}

/// The timeline builds its rows lazily, so a picture far up has no widget
/// until the list is scrolled to it.
Future<void> _reveal(Key key) async {
  if (find(key) == null) {
    ScrollPosition? timeline;
    // The anchor is a picture that is always built; the timeline is the
    // scrollable above it that can actually scroll.
    final anchor = [
      for (final id in [100, 101, 102, 103, 110, 111, 112, 113])
        find(Key('chat-image-$id-0')),
    ].firstWhere((element) => element != null, orElse: () => null);
    anchor!.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Scrollable &&
          (widget.axisDirection == AxisDirection.up ||
              widget.axisDirection == AxisDirection.down)) {
        final position = ((element as StatefulElement).state as ScrollableState)
            .position;
        if (position.maxScrollExtent > 0) {
          timeline = position;
          return false;
        }
      }
      return true;
    });
    final position = timeline;
    if (position == null) throw StateError('no timeline to scroll');
    for (
      var offset = position.minScrollExtent;
      find(key) == null && offset <= position.maxScrollExtent + 300;
      offset += 300
    ) {
      position.jumpTo(offset.clamp(position.minScrollExtent, position.maxScrollExtent));
      await _frames(const Duration(milliseconds: 200));
    }
  }
  await _ensureVisible(key);
}

Future<void> _ensureVisible(Key key) async {
  final element = find(key);
  if (element == null) throw StateError('no widget $key');
  await Scrollable.ensureVisible(element, alignment: 0.5, duration: Duration.zero);
  await _frames(const Duration(milliseconds: 500));
}

Future<Offset> _centerOf(Key key) async {
  final element = find(key);
  if (element == null) throw StateError('no widget $key');
  final box = element.renderObject! as RenderBox;
  return box.localToGlobal(box.size.center(Offset.zero));
}

Future<void> _waitFor(Key key, String what) async {
  if (!await _waitForMaybe(key, const Duration(seconds: 20))) {
    await _shot('timeout-${what.replaceAll(' ', '-')}');
    throw StateError('timed out waiting for $what');
  }
}

Future<bool> _waitForMaybe(Key key, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (find(key) != null) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

Future<void> _frames(Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await WidgetsBinding.instance.endOfFrame;
  }
}

Future<void> _shot(String name) async {
  final boundary =
      _repaint.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('${_out.path}\\$name.png').writeAsBytesSync(
    bytes!.buffer.asUint8List(),
  );
  image.dispose();
}

Future<void> _dismiss(int hwnd) async {
  // Escape with nothing open would close the conversation in the real shell.
  if (_menuKeys().isEmpty && !_exists((w) => w is BottomSheet)) return;
  _key(0x1B);
  await _frames(const Duration(milliseconds: 600));
  if (_menuKeys().isNotEmpty) {
    _note('menu survived Escape, clicking outside');
    await _realClick(hwnd, const Offset(3, 3));
    await _frames(const Duration(milliseconds: 600));
  }
}

// ---- real input ----------------------------------------------------------

Future<void> _realDrag(int hwnd, Offset from, Offset to) async {
  await _moveTo(hwnd, from);
  _send(0, 0, 0x0002);
  for (var step = 1; step <= 8; step++) {
    await _moveTo(hwnd, Offset.lerp(from, to, step / 8)!, settle: 30);
  }
  _send(0, 0, 0x0004);
  _note('left drag: $from -> $to');
  await Future<void>.delayed(const Duration(milliseconds: 250));
}

Future<void> _moveTo(int hwnd, Offset logical, {int settle = 150}) async {
  final (x, y) = _screenPoint(hwnd, logical);
  _send(
    x * 65535 ~/ (_getSystemMetrics(0) - 1),
    y * 65535 ~/ (_getSystemMetrics(1) - 1),
    0x0001 | 0x8000,
  );
  await Future<void>.delayed(Duration(milliseconds: settle));
}

(int, int) _screenPoint(int hwnd, Offset logical) {
  final ratio =
      WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  final origin = calloc<_Point>();
  _clientToScreen(hwnd, origin);
  final point = (
    origin.ref.x + (logical.dx * ratio).round(),
    origin.ref.y + (logical.dy * ratio).round(),
  );
  calloc.free(origin);
  return point;
}

Future<void> _realClick(int hwnd, Offset logical, {bool right = false}) async {
  final ratio = WidgetsBinding.instance.platformDispatcher.views.first
      .devicePixelRatio;
  final origin = calloc<_Point>();
  _clientToScreen(hwnd, origin);
  final x = origin.ref.x + (logical.dx * ratio).round();
  final y = origin.ref.y + (logical.dy * ratio).round();
  calloc.free(origin);
  final screenW = _getSystemMetrics(0);
  final screenH = _getSystemMetrics(1);
  _send(
    x * 65535 ~/ (screenW - 1),
    y * 65535 ~/ (screenH - 1),
    0x0001 | 0x8000,
  );
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final cursor = calloc<_Point>();
  _getCursorPos(cursor);
  _note(
    '${right ? 'right' : 'left'} click: logical=$logical dpr=$ratio '
    'target=($x,$y) cursor=(${cursor.ref.x},${cursor.ref.y}) '
    'foreground=${_foreground() == hwnd}',
  );
  calloc.free(cursor);
  _send(0, 0, right ? 0x0008 : 0x0002);
  await Future<void>.delayed(const Duration(milliseconds: 70));
  _send(0, 0, right ? 0x0010 : 0x0004);
  await Future<void>.delayed(const Duration(milliseconds: 250));
}

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _MouseInput extends Struct {
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int flags;
  @Uint32()
  external int time;
  @IntPtr()
  external int extra;
}

final class _Input extends Struct {
  @Uint32()
  external int type;
  external _MouseInput mi;
}

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(int, Pointer<_Input>, int) _sendInput = _user32
    .lookupFunction<
      Uint32 Function(Uint32, Pointer<_Input>, Int32),
      int Function(int, Pointer<_Input>, int)
    >('SendInput');
final int Function(int, Pointer<_Point>) _clientToScreen = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<_Point>),
      int Function(int, Pointer<_Point>)
    >('ClientToScreen');
final int Function(Pointer<_Point>) _getCursorPos = _user32
    .lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>(
      'GetCursorPos',
    );
final int Function(int) _getSystemMetrics = _user32
    .lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');
final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>) _findWindowEx =
    _user32.lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final int Function(int, Pointer<Uint32>) _windowPid = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final int Function(int) _setForeground = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );
final int Function() _foreground = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final void Function(int, int, int, int) _keybdEvent = _user32
    .lookupFunction<
      Void Function(Uint8, Uint8, Uint32, IntPtr),
      void Function(int, int, int, int)
    >('keybd_event');

void _send(int dx, int dy, int flags) {
  final input = calloc<_Input>();
  input.ref
    ..type = 0
    ..mi.dx = dx
    ..mi.dy = dy
    ..mi.flags = flags;
  _sendInput(1, input, sizeOf<_Input>());
  calloc.free(input);
}

void _key(int vk) {
  _keybdEvent(vk, 0, 0, 0);
  _keybdEvent(vk, 0, 2, 0);
}

int _ownWindow() {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final owner = calloc<Uint32>();
  try {
    var previous = 0;
    while (true) {
      final handle = _findWindowEx(0, previous, className, nullptr);
      if (handle == 0) throw StateError('own window not found');
      _windowPid(handle, owner);
      if (owner.value == pid) return handle;
      previous = handle;
    }
  } finally {
    malloc.free(className);
    calloc.free(owner);
  }
}

void _bringToFront(int hwnd) {
  for (var attempt = 0; attempt < 5 && _foreground() != hwnd; attempt++) {
    // A lone Alt tap lifts the foreground lock that keeps another app in front.
    _key(0x12);
    _setForeground(hwnd);
    sleep(const Duration(milliseconds: 200));
  }
}

// ---- fixtures ------------------------------------------------------------

Map<String, Object?> _fileParameter(int id, String name) => {
  'type': 'file',
  'id': '$id',
  'name': name,
  'path': 'Talk/$name',
  'link': '/index.php/f/$id',
  'mimetype': 'image/png',
  'preview-available': 'yes',
  'width': 320,
  'height': 200,
};

Map<String, Object?> _wire(
  int id, {
  required bool outgoing,
  required String message,
  required Map<String, Object?> file,
  String? referenceId,
  int? threadId,
}) => {
  'id': id,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': outgoing ? 'fixture-user' : 'other-user',
  'actorDisplayName': outgoing ? 'Me' : 'Other user',
  'timestamp': 1724300000 + id,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': referenceId ?? 'reference-$id',
  'message': message,
  'messageParameters': {'file': file},
  'markdown': false,
  'reactions': const <String, Object?>{},
  'reactionsSelf': const <Object?>[],
  'deleted': null,
  'threadId': threadId,
  'isThread': false,
  'threadTitle': null,
  'threadReplies': 0,
};

Map<String, Object?> _textWire(int id, String text) => {
  ..._wire(id, outgoing: false, message: text, file: const {}),
  'messageParameters': const <String, Object?>{},
};

Map<String, Object?> _imageWire(
  int id, {
  required bool outgoing,
  String? caption,
}) => _wire(
  id,
  outgoing: outgoing,
  message: caption ?? '{file}',
  file: _fileParameter(id, 'image-$id.png'),
);

Map<String, Object?> _albumWire(int id, int index) => _wire(
  id,
  outgoing: false,
  message: '{file}',
  file: _fileParameter(id, 'photo-$index.png'),
  threadId: id,
  referenceId: ChatPhotoAlbumReference(
    albumId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    index: index,
    count: 4,
  ).referenceId,
);

Future<ChatMediaImage> _solidPreview(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.indigo,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return ChatMediaImage(
    body: bytes!.buffer.asUint8List(),
    contentType: 'image/png',
  );
}

final class _MemoryVault implements CredentialVault, PendingRevocationStore {
  final Map<String, String> values = {};
  String? pending;

  @override
  Future<void> deleteAppPassword(String accountId) async =>
      values.remove(accountId);

  @override
  Future<String?> readAppPassword(String accountId) async => values[accountId];

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async =>
      values[accountId] = appPassword;

  @override
  Future<String?> readPendingRevocations() async => pending;

  @override
  Future<void> updatePendingRevocations(
    String? Function(String? current) update,
  ) async => pending = update(pending);

  @override
  Future<void> writePendingRevocations(String? json) async => pending = json;
}

final class _NoImageExport implements ChatImageExporter {
  @override
  Future<bool> copyToClipboard({required Uint8List bytes}) async => true;

  @override
  Future<ChatImageSaveResult> saveToGallery({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async => ChatImageSaveResult.saved;

  @override
  Future<bool> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async => true;
}

final class _NoSave implements ChatAttachmentExportAction {
  @override
  Future<ChatAttachmentSaveResult> save({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async => ChatAttachmentSaveResult.saved;

  @override
  Future<ChatAttachmentShareResult> share({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async => ChatAttachmentShareResult.shared;
}

final class _RecordingOpen implements ChatAttachmentOpenAction {
  final List<Uri> uris = [];

  @override
  Future<ChatAttachmentOpenResult> open({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async {
    uris.add(uri);
    return ChatAttachmentOpenResult.opened;
  }
}
