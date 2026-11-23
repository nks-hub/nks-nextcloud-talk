// Renders the pictures in docs/screenshots from seeded widget trees, without a
// device, a window or a running app. Skipped unless OWNTALK_README_SHOTS=1, so
// the regular suite never rewrites the files:
//
//   OWNTALK_README_SHOTS=1 flutter test test/readme_screenshots_test.dart
//
// OWNTALK_README_OUT redirects the output (default ../../docs/screenshots).
// Every person, room and server below is invented; the cast matches
// tool/store_screenshot_data.py.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/calls/call_audio_interruptions.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/features/rooms/room_details_screen.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const _server = 'https://talk.example.com';
const _login = 'alex';
const _accountId = 'account-demo';
const _roomToken = ownTalkTestToken;
const _typedReply = 'Shall we say 2 pm? I will send an invite.';

_Seeded? _lastSeeded;

final _outDir =
    Platform.environment['OWNTALK_README_OUT'] ?? '../../docs/screenshots';

/// Today at 11:32 local time, so every time on screen reads like a mid-morning.
final _now = () {
  final today = DateTime.now();
  return DateTime(today.year, today.month, today.day, 11, 32)
          .millisecondsSinceEpoch ~/
      1000;
}();

typedef _Shot = ({
  String file,
  Size size,
  double pixelRatio,
  bool desktop,
  Brightness brightness,
  Widget Function(_Seeded seeded) build,
  Finder ready,
  Future<void> Function(WidgetTester tester)? after,
});

final class _Seeded {
  _Seeded(this.account, this.conversation, this.conversations);

  final StoredAccount account;
  final CachedConversation conversation;
  final List<CachedConversation> conversations;
}

void main() {
  if (Platform.environment['OWNTALK_README_SHOTS'] != '1') {
    test('README screenshots need OWNTALK_README_SHOTS=1', () {}, skip: true);
    return;
  }
  setUpAll(_loadFonts);
  setUpAll(() {
    // The voice button builds a recorder and a player; with no plugin behind
    // them every call is answered with nothing, which keeps the button idle.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in const [
      'com.llfbandit.record/messages',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    // Each player listens on an event channel named after its id, which is
    // only known from the `create` call that precedes the listen.
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final playerId = (call.arguments as Map<Object?, Object?>)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$playerId'),
            (_) async => null,
          );
        }
        return null;
      },
    );
  });

  final shots = <_Shot>[
    (
      file: 'desktop-chat',
      size: const Size(1280, 800),
      pixelRatio: 1,
      desktop: true,
      brightness: Brightness.dark,
      build: (s) => _workspace(s, selected: _roomToken),
      ready: find.text('Works for me.'),
      after: null,
    ),
    (
      file: 'desktop-details',
      size: const Size(1280, 800),
      pixelRatio: 1,
      desktop: true,
      brightness: Brightness.dark,
      build: (s) => _workspace(s, selected: _roomToken, detailsOpen: true),
      ready: find.text('Rename conversation'),
      after: null,
    ),
    (
      file: 'phone-conversations',
      size: const Size(390, 848),
      pixelRatio: 420 / 390,
      desktop: false,
      brightness: Brightness.light,
      build: (s) => _workspace(s, selected: null),
      ready: find.text('Design Review'),
      after: null,
    ),
    (
      file: 'phone-chat',
      size: const Size(390, 848),
      pixelRatio: 420 / 390,
      desktop: false,
      brightness: Brightness.light,
      build: (s) =>
          PresenceChatRoomScreen(account: s.account, conversation: s.conversation),
      ready: find.text('Works for me.'),
      after: (tester) async {
        await tester.enterText(
          find.byKey(const Key('chat-composer')),
          _typedReply,
        );
        await tester.pump(const Duration(milliseconds: 400));
      },
    ),
    (
      file: 'phone-details',
      size: const Size(390, 848),
      pixelRatio: 420 / 390,
      desktop: false,
      brightness: Brightness.light,
      build: (s) => const Scaffold(),
      ready: find.byType(Scaffold),
      after: (tester) async {
        final seeded = _lastSeeded!;
        unawaited(
          tester
              .state<NavigatorState>(find.byType(Navigator).first)
              .push(
                MaterialPageRoute<void>(
                  builder: (_) => RoomDetailsScreen(
                    account: seeded.account,
                    conversation: seeded.conversation,
                  ),
                ),
              ),
        );
        await _until(tester, find.text('Appearance for everyone'));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.drag(find.byType(ListView).first, const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 600));
      },
    ),
  ];

  for (final shot in shots) {
    testWidgets('README ${shot.file}', (tester) async {
      // The test binding turns every shadow into a solid block, which draws as
      // a black ring around the floating button.
      debugDisableShadows = false;
      final database = openTestDatabase();
      final apis = <HttpNextcloudApi>[];
      final attachmentRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('owntalk-readme-'),
      ))!;
      final account = await AccountRepository(database).upsertAccount(
        accountId: _accountId,
        serverUrl: _server,
        loginName: _login,
        serverProductName: 'Nextcloud',
        talkFeatures: const <String>{
          'conversation-v4',
          'chat-v2',
          'threads',
          'chat-unread',
          'archived-conversations-v2',
          'unified-search',
          'chat-replies',
          'chat-reference-id',
          'reactions',
          'edit-messages',
          'delete-messages',
          'favorites',
        },
        createdAt: DateTime.utc(2026, 8, 26),
      );
      for (final room in _rooms()) {
        await database
            .into(database.cachedConversations)
            .insertOnConflictUpdate(room.toCompanion(true));
      }
      await _seedChat(database);
      final conversation = await (database.select(
        database.cachedConversations,
      )..where((c) => c.token.equals(_roomToken))).getSingle();
      final seeded = _Seeded(
        account,
        conversation,
        await database.select(database.cachedConversations).get(),
      );

      final picture = await tester.runAsync(_mockupPicture);
      final vault = MemoryCredentialVault()..values[_accountId] = 'demo';
      final sourceStore = DurableAttachmentSourceStore(root: attachmentRoot);
      final attachmentService = (await tester.runAsync(() async {
        await sourceStore.initialize();
        final service = AttachmentService(
          repository: AttachmentRepository(database),
          credentials: vault,
          releaseSource: (source) => sourceStore.discard(source.handle),
          transport: HttpAttachmentTransport(
            client: MockClient((_) async => http.Response('', 404)),
            sourceProvider: sourceStore,
          ),
          watchConfirmationCandidates: () =>
              const Stream<AttachmentConfirmationSnapshot>.empty(),
        );
        await service.ready;
        return service;
      }))!;

      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = shot.size;
      addTearDown(tester.view.reset);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      debugDefaultTargetPlatformOverride = shot.desktop
          ? TargetPlatform.windows
          : TargetPlatform.android;

      _lastSeeded = seeded;
      final boundary = GlobalKey();
      final extensions = FakeOwnTalkServer();
      if (shot.file == 'phone-details') {
        extensions.setExternally({
          'chat.backgroundPreset': 'ocean',
          'bubble.ownColor': '#2C5E82',
          'bubble.ownTextColor': '#FFFFFF',
        });
      }
      final api = HttpNextcloudApi(client: _client(extensions));
      apis.add(api);
      await tester.pumpWidget(
        _app(
          shot.build(seeded),
          boundary: boundary,
          brightness: shot.brightness,
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            // The real stores write files, which never completes in the test
            // clock; the extras provider treats a missing cache as empty.
            ownTalkSettingsStoreProvider.overrideWith(
              (ref) => Future<OwnTalkSettingsStore>.error(StateError('no store')),
            ),
            emojiUsageStoreProvider.overrideWithValue(_MemoryEmojiUsageStore()),
            callAudioInterruptionsProvider.overrideWithValue(
              const SilentCallAudioInterruptions(),
            ),
            conversationAvatarProvider.overrideWith((ref, key) async => null),
            attachmentSourceProvider.overrideWith((ref) async => sourceStore),
            attachmentServiceProvider.overrideWith(
              (ref) async => attachmentService,
            ),
            chatMediaProvider.overrideWith(
              (ref, key) async => ChatMediaImage.takeOwnership(
                body: picture!,
                contentType: 'image/png',
              ),
            ),
          ],
        ),
      );
      await _until(tester, shot.ready, extra: 400);
      await _settle(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 200));
      await shot.after?.call(tester);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('temporarily unavailable'),
        findsNothing,
        reason: 'the composer must not show the attachments notice',
      );

      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: shot.pixelRatio);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final out = File('$_outDir/${shot.file}.png');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(data!.buffer.asUint8List());
      });

      debugDefaultTargetPlatformOverride = null;
      debugDisableShadows = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      for (final api in apis) {
        api.close();
      }
      await tester.runAsync(() async {
        await attachmentService.close();
        await database.close();
        await attachmentRoot.delete(recursive: true);
      });
    });
  }
}

final class _MemoryEmojiUsageStore implements EmojiUsageStore {
  @override
  Future<void> delete(AccountId accountId) async {}

  @override
  Future<EmojiUsage> read(AccountId accountId) async => EmojiUsage.empty;

  @override
  Future<EmojiUsage> recordSelection(AccountId accountId, String glyph) async =>
      EmojiUsage.empty;

  @override
  Future<EmojiUsage> toggleFavorite(AccountId accountId, String glyph) async =>
      EmojiUsage.empty;
}

Future<void> _loadFonts() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      'C:/work/sources/flutter-sdk/flutter';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      loader.addFont(
        File('$dir/$file').readAsBytes().then((b) => ByteData.view(b.buffer)),
      );
    }
    await loader.load();
  }

  await load('Roboto', const [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-light.ttf',
  ]);
  await load('MaterialIcons', const ['materialicons-regular.otf']);
}

Future<void> _until(WidgetTester tester, Finder finder, {int extra = 0}) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3)),
    );
  }
  await tester.pump(Duration(milliseconds: 200 + extra));
}

/// Waits until no spinner or sync bar is left on screen.
Future<void> _settle(WidgetTester tester) async {
  final busy = find.byWidgetPredicate(
    (w) => w is CircularProgressIndicator || w is LinearProgressIndicator,
  );
  for (var i = 0; i < 160 && busy.evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pump(const Duration(milliseconds: 300));
}

Widget _app(
  Widget home, {
  required GlobalKey boundary,
  required Brightness brightness,
  required List<Override> overrides,
}) {
  final theme = brightness == Brightness.dark
      ? AppTheme.dark()
      : AppTheme.light();
  return ProviderScope(
    overrides: overrides,
    child: RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: home,
      ),
    ),
  );
}

Widget _workspace(
  _Seeded s, {
  required String? selected,
  bool detailsOpen = false,
}) {
  return ConversationWorkspace(
    account: s.account,
    accounts: [s.account],
    unreadByAccount: const {},
    conversations: s.conversations,
    selectedConversationToken: selected,
    loading: false,
    syncing: false,
    onRefresh: () async {},
    onSelectAccount: (_) {},
    onAddAccount: () {},
    onOpenConversation: (_) {},
    onCloseConversation: () {},
    onSelectConversation: (_) {},
    detailsOpen: detailsOpen,
    onOpenDetails: () {},
    onCloseDetails: () {},
  );
}

/// Answers the room settings requests from [extensions], everything else from
/// the seeded cast.
MockClient _client(FakeOwnTalkServer extensions) => MockClient((request) async {
  final path = request.url.path;
  if (path.contains('/room/$_roomToken/settings')) {
    return extensions.handle(request);
  }
  if (path.endsWith('/cloud/capabilities')) {
    final body = capabilitiesJson(
        talkFeatures: const [
          'conversation-v4',
          'chat-v2',
          'threads',
          'chat-reference-id',
          'chat-replies',
          'reactions',
          'edit-messages',
          'delete-messages',
          'geo-location-sharing',
          'media-caption',
          'voice-message-sharing',
        ],
        attachments: const {'allowed': true, 'conversation-subfolders': true},
    );
    final ocs = body['ocs']! as Map<String, Object?>;
    final data = ocs['data']! as Map<String, Object?>;
    (data['capabilities']! as Map<String, Object?>)['owntalk_extensions'] =
        ownTalkCapabilityJson();
    return _json(body);
  }
  if (path.endsWith('/participants')) {
    return _ocs(_participants());
  }
  if (path.contains('/chat/')) {
    return http.Response('', 304);
  }
  return _ocs(const <Object?>[]);
});

/// A 640x400 stand-in for a design mockup: shapes only, so no font and no
/// real picture is involved.
Future<Uint8List> _mockupPicture() async {
  const width = 640.0;
  const height = 400.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint();
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    paint..color = const Color(0xFFE9EFF5),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, 56),
    paint..color = const Color(0xFF2C5E82),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(24, 18, 120, 20),
      const Radius.circular(10),
    ),
    paint..color = const Color(0x66FFFFFF),
  );
  for (var column = 0; column < 2; column++) {
    for (var row = 0; row < 2; row++) {
      final left = 24.0 + column * 304;
      final top = 80.0 + row * 150;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, 288, 134),
          const Radius.circular(14),
        ),
        paint..color = const Color(0xFFFFFFFF),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left + 16, top + 18, 120, 12),
          const Radius.circular(6),
        ),
        paint..color = const Color(0xFF2C5E82),
      );
      for (var line = 0; line < 3; line++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left + 16, top + 46 + line * 22, 256 - line * 52, 8),
            const Radius.circular(4),
          ),
          paint..color = const Color(0xFFC6D1DC),
        );
      }
    }
  }
  final image = await recorder.endRecording().toImage(
    width.toInt(),
    height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Map<String, Object?> _roomWire(
  String token,
  String name,
  int type, {
  int unread = 0,
}) {
  final response =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final rooms =
      (response['ocs']! as Map<String, Object?>)['data']! as List<Object?>;
  final raw = jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
  raw
    ..['token'] = token
    ..['name'] = name
    ..['displayName'] = name
    ..['description'] = ''
    ..['type'] = type
    ..['participantType'] = 2
    ..['permissions'] = 128
    ..['readOnly'] = 0
    ..['lobbyState'] = 0
    ..['unreadMention'] = false
    ..['unreadMessages'] = unread
    ..['notificationLevel'] = 0
    ..remove('remoteServer')
    ..remove('lastMessage');
  return raw;
}

CachedConversation _room(
  String token,
  String name,
  String preview,
  int type, {
  required Duration ago,
  int unread = 0,
  bool favorite = false,
  String? status,
}) {
  final activity = _now - ago.inSeconds;
  return CachedConversation(
    accountId: _accountId,
    token: token,
    displayName: name,
    description: '',
    lastActivity: activity,
    unreadMessages: unread,
    favorite: favorite,
    isArchived: false,
    readOnly: 0,
    roomType: type,
    roomName: name,
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    peerStatus: status,
    peerStatusIcon: null,
    peerStatusMessage: null,
    lastMessageText: preview,
    lastMessageTimestamp: activity,
    rawJson: jsonEncode(_roomWire(token, name, type, unread: unread)),
  );
}

List<CachedConversation> _rooms() => [
  _room(
    _roomToken,
    'Product Team',
    'Sam: Works for me.',
    2,
    ago: const Duration(minutes: 5),
    favorite: true,
  ),
  _room(
    'notes0001',
    'Note to self',
    'Remember to send the meeting notes',
    6,
    ago: const Duration(hours: 1),
  ),
  _room(
    'samcarter1',
    'Sam Carter',
    'Sounds good, talk tomorrow',
    1,
    ago: const Duration(days: 1, hours: 2),
    status: 'online',
  ),
  _room(
    'designrev1',
    'Design Review',
    'The new icons are in the shared folder',
    2,
    ago: const Duration(days: 2, hours: 3),
    unread: 3,
  ),
  _room(
    'release001',
    'Release planning',
    'Friday works for everybody',
    2,
    ago: const Duration(days: 3, hours: 1),
  ),
  _room(
    'started001',
    "Let's get started!",
    'Adding the team now',
    2,
    ago: const Duration(days: 5),
  ),
];

List<Object?> _participants() {
  Map<String, Object?> person(int id, String actor, String name, int type) => {
    'attendeeId': id,
    'actorType': 'users',
    'actorId': actor,
    'displayName': name,
    'participantType': type,
    'lastPing': _now,
    'sessionIds': const <String>[],
    'permissions': 254,
    'attendeePermissions': 0,
    'inCall': 0,
  };
  return [
    person(1, _login, 'Alex Morgan', 1),
    person(2, 'sam', 'Sam Carter', 3),
    person(3, 'ada', 'Ada Nováková', 3),
  ];
}

Map<String, Object?> _message(
  int id,
  String actor,
  String name,
  String text,
  int minutesAgo, {
  Map<String, Object?> params = const {},
}) => {
  'id': id,
  'token': _roomToken,
  'actorType': 'users',
  'actorId': actor,
  'actorDisplayName': name,
  'timestamp': _now - minutesAgo * 60,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'ref-$id',
  'message': text,
  'messageParameters': params,
  'markdown': false,
  'reactions': const <String, Object?>{},
  'reactionsSelf': const <Object?>[],
  'deleted': null,
  'threadId': null,
  'isThread': false,
  'threadTitle': null,
  'threadReplies': 0,
};

Future<void> _seedChat(AppDatabase database) async {
  final wires = [
    _message(
      900,
      'sam',
      'Sam Carter',
      'Mockups are ready for review, in the shared folder.',
      27,
    ),
    _message(
      901,
      'sam',
      'Sam Carter',
      'The spacing notes are in there too.',
      26,
    ),
    _message(
      902,
      _login,
      'Alex Morgan',
      'Thanks! I will go through them this afternoon.',
      21,
    ),
    _message(
      903,
      'ada',
      'Ada Nováková',
      'The spacing on the second screen still looks tight.',
      17,
    ),
    _message(
      904,
      'sam',
      'Sam Carter',
      '{file}',
      15,
      params: {
        'file': {
          'type': 'file',
          'id': '904',
          'name': 'second-screen.png',
          'path': 'Talk/second-screen.png',
          'link': '/index.php/f/904',
          'mimetype': 'image/png',
          'preview-available': 'yes',
          'width': 640,
          'height': 400,
        },
      },
    ),
    _message(
      905,
      'sam',
      'Sam Carter',
      'Good catch, I will widen it before Friday.',
      14,
    ),
    _message(
      906,
      _login,
      'Alex Morgan',
      'Shall we do a quick call after lunch?',
      9,
    ),
    _message(907, 'sam', 'Sam Carter', 'Works for me.', 5),
  ];
  for (final wire in wires) {
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: _accountId,
            roomToken: _roomToken,
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
            threadId: const Value(null),
            rawJson: jsonEncode(wire),
          ),
        );
  }
  final first = wires.first['id']! as int;
  final last = wires.last['id']! as int;
  for (final key in const ['root', 'network-root']) {
    await database
        .into(database.chatScopes)
        .insert(
          ChatScopesCompanion.insert(
            accountId: _accountId,
            roomToken: _roomToken,
            scopeKey: key,
            threadId: const Value(null),
            historyCursor: '$first',
            futureCursor: '$last',
            lastCommonRead: '$last',
            lastReadMessage: last,
            unreadMessages: 0,
            hasHistory: false,
            futureConverged: true,
            blocksJson: '[["$first","$last"]]',
            lastSyncedAtMillis: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }
}

http.Response _ocs(Object? data) => _json(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': data,
  },
});

http.Response _json(Object? body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const <String, String>{
    'content-type': 'application/json; charset=utf-8',
  },
);
