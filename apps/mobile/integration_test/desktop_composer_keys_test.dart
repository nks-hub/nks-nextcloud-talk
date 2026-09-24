@TestOn('windows')
library;

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/stale_modifier_repair.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import '../test/test_support.dart';
import 'desktop_app_support.dart';

/// Enter and Ctrl+V in the composer, typed through Windows' own input queue.
///
/// `tester.sendKeyEvent` hands the framework a finished key message and skips
/// the embedder, which is exactly the layer that decides whether a key is a
/// press, a repeat, or text for the field. The report was that after typing
/// the next line while a send was in flight, Enter only broke the line and
/// Ctrl+V did nothing until the app was restarted — so the keys here go in
/// with `SendInput`, the way a keyboard does.
///
/// Run on demand:
/// `flutter test integration_test/desktop_composer_keys_test.dart -d windows`
/// with `NKS_TALK_INTEGRATION_TEST=1`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Enter sends and Ctrl+V pastes after typing during a send', (
    tester,
  ) async {
    // What `main` does; this test builds the pane without it.
    staleModifierRepair.attach();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://account-a.example.invalid',
      loginName: 'user-account-a',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'chat-v2'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    // In the database, so a send gets as far as reading the app password —
    // where [_HeldVault] keeps it in flight — instead of failing at once on a
    // room the service cannot find and putting the draft back.
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: 'roomone',
            displayName: 'Synthetic room',
            description: '',
            lastActivity: 1,
            unreadMessages: 0,
            favorite: false,
            rawJson: '{}',
          ),
        );
    final conversation = await database
        .select(database.cachedConversations)
        .getSingle();
    final vault = _HeldVault();
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response('', 404)),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: vault,
      api: api,
    );
    addTearDown(service.close);
    addTearDown(vault.releaseAll);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          clientPushEnabledProvider.overrideWithValue(false),
          credentialVaultProvider.overrideWithValue(vault),
          chatServiceProvider.overrideWithValue(service),
          chatMessagesProvider.overrideWith(
            (ref, key) => Stream.value(const <CachedChatMessage>[]),
          ),
          outgoingMessageStatusesProvider.overrideWith(
            (ref, key) => Stream.value(const <OutgoingMessageStatus>[]),
          ),
          textSendOperationsProvider.overrideWith(
            (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
          ),
          chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
          connectivityWakeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: ChatRoomPane(account: account, conversation: conversation),
          ),
        ),
      ),
    );
    await settle(tester, const Duration(seconds: 1));

    final composer = find.byKey(const Key('chat-composer'));
    TextEditingController controller() =>
        tester.widget<TextField>(composer).controller!;

    // The machine's clipboard belongs to whoever sits at it; the paste check
    // borrows it and hands it back.
    final savedClipboard = await Clipboard.getData(Clipboard.kTextPlain);
    addTearDown(() async {
      final text = savedClipboard?.text;
      if (text != null) {
        await Clipboard.setData(ClipboardData(text: text));
      }
    });

    final field = controller();
    final seen = <String>[];
    bool record(KeyEvent event) {
      seen.add(
        '${event.runtimeType}:${event.logicalKey.keyLabel}'
        '${event.synthesized ? '(synth)' : ''}'
        ' shift=${HardwareKeyboard.instance.isShiftPressed}'
        ' pressed=${HardwareKeyboard.instance.logicalKeysPressed.map((k) => k.keyLabel).toList()}'
        ' os=${_osModifiers()}'
        ' text="${field.text.replaceAll('\n', r'\n')}"'
        ' composing=${field.value.composing}',
      );
      return false;
    }

    HardwareKeyboard.instance.addHandler(record);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(record));
    addTearDown(() => debugPrint('KEYLOG\n${seen.join('\n')}'));

    seen.add(
      'before foreground: os=${_osModifiers()} flutter='
      '${HardwareKeyboard.instance.logicalKeysPressed.map((k) => k.keyLabel).toList()}'
      ' foregroundIsTest=${_getForegroundWindow() == _testWindow()}',
    );
    _takeForeground();
    await settle(tester, const Duration(milliseconds: 500));
    seen.add(
      'after foreground: os=${_osModifiers()} flutter='
      '${HardwareKeyboard.instance.logicalKeysPressed.map((k) => k.keyLabel).toList()}',
    );
    await tester.tap(composer, kind: PointerDeviceKind.mouse);
    await settle(tester, const Duration(milliseconds: 300));

    _type('first');
    await settle(tester, const Duration(milliseconds: 300));
    expect(controller().text, 'first');

    // Enter, and straight into the next line while the send is in flight.
    _press(_vkReturn);
    _type('second');
    await waitUntil(
      tester,
      () => vault.reads >= 1,
      what: 'the first send to start',
    );
    await settle(tester, const Duration(seconds: 2));
    expect(controller().text, 'second');

    // The first send finishes (it fails without a password, which leaves the
    // newer line alone); the composer is free again.
    vault.releaseAll();
    await settle(tester, const Duration(seconds: 1));
    expect(controller().text, 'second');

    // A send empties the field at once; the failure without a password may
    // then put the line back, so what proves the send is that the field was
    // emptied, and what proves Enter did not break the line is that no line
    // break ever appeared.
    final values = <String>[];
    void track() => values.add(field.text);
    field.addListener(track);
    addTearDown(() => field.removeListener(track));
    _press(_vkReturn);
    await waitUntil(
      tester,
      () => values.contains(''),
      what: 'Enter to send the second line',
      timeout: const Duration(seconds: 5),
    );
    await settle(tester, const Duration(milliseconds: 500));
    expect(values.where((v) => v.contains('\n')), isEmpty);

    // The reported state: a Shift whose release never arrived. Flutter's own
    // record says it is held; Windows says it is not. Before the repair this
    // made Enter break the line and Ctrl+V do nothing until a restart.
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.shiftLeft,
        logicalKey: LogicalKeyboardKey.shiftLeft,
        timeStamp: Duration.zero,
        synthesized: true,
      ),
    );
    expect(HardwareKeyboard.instance.isShiftPressed, isTrue);
    controller().clear();
    // Older than the repair's grace, as a Shift stuck for minutes would be.
    await settle(tester, const Duration(seconds: 1));
    values.clear();
    _type('third');
    await settle(tester, const Duration(milliseconds: 300));
    _press(_vkReturn);
    await waitUntil(
      tester,
      () => values.contains(''),
      what: 'Enter to send with a stale Shift',
      timeout: const Duration(seconds: 5),
    );
    await settle(tester, const Duration(milliseconds: 500));
    expect(values.where((v) => v.contains('\n')), isEmpty);
    expect(HardwareKeyboard.instance.isShiftPressed, isFalse);

    HardwareKeyboard.instance.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.shiftLeft,
        logicalKey: LogicalKeyboardKey.shiftLeft,
        timeStamp: Duration.zero,
        synthesized: true,
      ),
    );
    await Clipboard.setData(const ClipboardData(text: 'pasted'));
    controller().clear();
    await settle(tester, const Duration(seconds: 1));
    _chord(_vkControl, _vkV);
    await waitUntil(
      tester,
      () => controller().text == 'pasted',
      what: 'Ctrl+V to paste',
      timeout: const Duration(seconds: 5),
    );
  });
}

/// Holds every credential read until the test ends, so each send stays in
/// flight — the window the report is about — and never fails back into the
/// field.
final class _HeldVault implements CredentialVault {
  /// Opened by the test; until then every read waits.
  final Completer<void> gate = Completer<void>();
  int reads = 0;

  void releaseAll() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<String?> readAppPassword(String accountId) async {
    reads++;
    await gate.future;
    return null;
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {}

  @override
  Future<void> deleteAppPassword(String accountId) async {}
}

const int _vkReturn = 0x0D;
const int _vkControl = 0x11;
const int _vkShift = 0x10;
const int _vkV = 0x56;
const int _inputKeyboard = 1;
const int _keyEventKeyUp = 0x0002;
const int _inputSize = 40;

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(int, Pointer<Uint8>, int) _sendInput = _user32
    .lookupFunction<
      Uint32 Function(Uint32, Pointer<Uint8>, Int32),
      int Function(int, Pointer<Uint8>, int)
    >('SendInput');

final int Function(int, int) _mapVirtualKey = _user32
    .lookupFunction<Uint32 Function(Uint32, Uint32), int Function(int, int)>(
      'MapVirtualKeyW',
    );

final int Function(int) _vkKeyScan = _user32
    .lookupFunction<Int16 Function(Uint16), int Function(int)>('VkKeyScanW');

final int Function() _getForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');

final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');

final int Function(int, int, int) _attachThreadInput = _user32
    .lookupFunction<
      Int32 Function(Uint32, Uint32, Int32),
      int Function(int, int, int)
    >('AttachThreadInput');

final int Function(int) _setForegroundWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );

final int Function(int) _bringWindowToTop = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'BringWindowToTop',
    );

final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindow = _user32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');

int _testWindow() {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final title = 'OwnTalk (integration test)'.toNativeUtf16();
  try {
    return _findWindow(className, title);
  } finally {
    calloc
      ..free(className)
      ..free(title);
  }
}

final int Function(int) _getAsyncKeyState = _user32
    .lookupFunction<Int16 Function(Int32), int Function(int)>(
      'GetAsyncKeyState',
    );

/// Which modifiers Windows itself says are down right now.
String _osModifiers() {
  const names = {
    0xA0: 'LShift',
    0xA1: 'RShift',
    0xA2: 'LCtrl',
    0xA3: 'RCtrl',
    0xA4: 'LAlt',
    0xA5: 'RAlt',
    0x5B: 'LWin',
  };
  return [
    for (final MapEntry(:key, :value) in names.entries)
      if (_getAsyncKeyState(key) & 0x8000 != 0) value,
  ].toString();
}

int _threadOf(int window) => _getWindowThreadProcessId(window, nullptr);

/// Puts the test window in front. `SendInput` types into whatever window has
/// the foreground, so a key sent while another app is in front lands in THAT
/// app — the input queue is borrowed from the foreground thread for the
/// switch, which is what Windows requires before it lets a background process
/// take the foreground.
void _takeForeground() {
  final window = _testWindow();
  if (window == 0) {
    fail('the test window was not found; run with NKS_TALK_INTEGRATION_TEST=1');
  }
  final foreground = _getForegroundWindow();
  if (foreground == window) {
    return;
  }
  final ours = _threadOf(window);
  final theirs = foreground == 0 ? 0 : _threadOf(foreground);
  final attached = theirs != 0 && theirs != ours
      ? _attachThreadInput(theirs, ours, 1) != 0
      : false;
  try {
    _bringWindowToTop(window);
    _setForegroundWindow(window);
  } finally {
    if (attached) {
      _attachThreadInput(theirs, ours, 0);
    }
  }
}

/// Sends key transitions as one batch, the way a keyboard driver queues them.
/// Refuses outright unless the test window is in front, so a stray key can
/// never reach another application.
void _send(List<(int, bool)> strokes) {
  _takeForeground();
  final window = _testWindow();
  if (window == 0 || _getForegroundWindow() != window) {
    fail('the test window is not in the foreground; no key was sent');
  }
  final buffer = calloc<Uint8>(_inputSize * strokes.length);
  try {
    final data = buffer
        .asTypedList(_inputSize * strokes.length)
        .buffer
        .asByteData();
    for (var i = 0; i < strokes.length; i++) {
      final (vk, up) = strokes[i];
      final base = i * _inputSize;
      data.setUint32(base, _inputKeyboard, Endian.little);
      // KEYBDINPUT starts at offset 8 on x64: wVk, wScan, dwFlags.
      data.setUint16(base + 8, vk, Endian.little);
      data.setUint16(base + 10, _mapVirtualKey(vk, 0), Endian.little);
      data.setUint32(base + 12, up ? _keyEventKeyUp : 0, Endian.little);
    }
    final sent = _sendInput(strokes.length, buffer, _inputSize);
    if (sent != strokes.length) {
      fail('SendInput accepted $sent of ${strokes.length} strokes');
    }
  } finally {
    calloc.free(buffer);
  }
}

void _press(int vk) => _send([(vk, false), (vk, true)]);

void _chord(int modifier, int vk) =>
    _send([(modifier, false), (vk, false), (vk, true), (modifier, true)]);

void _type(String text) {
  final strokes = <(int, bool)>[];
  for (final unit in text.codeUnits) {
    final scan = _vkKeyScan(unit);
    final vk = scan & 0xff;
    final shift = (scan >> 8) & 1 == 1;
    if (shift) strokes.add((_vkShift, false));
    strokes
      ..add((vk, false))
      ..add((vk, true));
    if (shift) strokes.add((_vkShift, true));
  }
  _send(strokes);
}
