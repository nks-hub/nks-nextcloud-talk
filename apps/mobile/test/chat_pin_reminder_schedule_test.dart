import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_pin_reminder_schedule.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations_en.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Everything pin, reminder and scheduled send need, plus what the room pane
/// itself needs to render at all.
const _fullFeatures = <String>[
  'conversation-v4',
  'chat-v2',
  'chat-reference-id',
  'pinned-messages',
  'remind-me-later',
];

/// Bounded replacement for `pumpAndSettle`: the pane keeps an indeterminate
/// sync progress bar on screen while its foreground loop runs, so settling can
/// never complete here. Real async turns let Drift and HTTP finish between
/// frames, matching the lifecycle used by the working message-jump harness.
Future<void> settle(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 120));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

/// Lets the real Drift and HTTP work behind an action finish. `testWidgets`
/// runs on a fake clock, so a round trip needs `runAsync` to progress.
Future<void> flush(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
  await settle(tester);
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}

Future<void> teardownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late List<String> requestLog;

  setUp(() async {
    requestLog = <String>[];
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  Future<CachedConversation> insertRoom({
    int lastPinnedId = 0,
    int hiddenPinnedId = 0,
    int hasScheduledMessages = 0,
    int participantType = 3,
    List<String>? localFeatures,
  }) async {
    final room = _roomJson(
      lastPinnedId: lastPinnedId,
      hiddenPinnedId: hiddenPinnedId,
      hasScheduledMessages: hasScheduledMessages,
      participantType: participantType,
    );
    final parsed = ConversationRoom.fromJson(room);
    await database
        .into(database.cachedConversations)
        .insertOnConflictUpdate(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: parsed.token.value,
            displayName: parsed.displayName,
            description: parsed.description,
            lastActivity: parsed.lastActivity,
            unreadMessages: parsed.unreadMessages,
            favorite: parsed.isFavorite,
            readOnly: Value(parsed.readOnly),
            roomType: Value(parsed.type),
            roomName: Value(parsed.name),
            objectType: Value(parsed.objectType),
            // Avatars are out of scope and would issue real network requests.
            avatarVersion: const Value(''),
            isCustomAvatar: const Value(false),
            rawJson: jsonEncode(room),
          ),
        );
    // A scope that has already synchronized once makes the pane skip the
    // initial history page, so every test below drives exactly the requests it
    // asserts on and the timeline never moves underneath it. The block spans
    // every message id these tests use, which is what keeps a cached row
    // visible: the pane only shows messages a confirmed block covers.
    await database
        .into(database.chatScopes)
        .insertOnConflictUpdate(
          ChatScopesCompanion.insert(
            accountId: account.id,
            roomToken: 'rooma123',
            scopeKey: 'root',
            historyCursor: '1',
            futureCursor: '1000',
            lastCommonRead: '1000',
            lastReadMessage: 0,
            unreadMessages: 0,
            hasHistory: false,
            futureConverged: false,
            blocksJson: '[["1","1000"]]',
            lastSyncedAtMillis: const Value(1724300000000),
          ),
        );
    return (database.select(
      database.cachedConversations,
    )..where((row) => row.token.equals('rooma123'))).getSingle();
  }

  Future<void> insertMessage({
    int messageId = 10,
    String text = 'Cached hello',
  }) async {
    await database
        .into(database.cachedChatMessages)
        .insertOnConflictUpdate(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: 'rooma123',
            messageId: messageId,
            actorType: 'users',
            actorId: 'someone-else',
            actorDisplayName: 'Other person',
            timestamp: 1724300000,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'fixture-reference-$messageId',
            displayText: text,
            deleted: false,
            rawJson: jsonEncode(_messageJson(messageId: messageId, text: text)),
          ),
        );
  }

  HttpNextcloudApi buildApi({
    List<String> talkFeatures = _fullFeatures,
    List<String> localFeatures = const <String>[],
    http.Response Function(http.Request request)? onRichChat,
  }) {
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _capabilitiesJson(
                talkFeatures: talkFeatures,
                localFeatures: localFeatures,
              ),
            ),
            200,
          );
        }
        // Avatars are out of scope here and must be answered explicitly:
        // letting them fall through to the "nothing new" default leaves the
        // avatar loader waiting on a body that never comes.
        if (path.contains('/avatar')) {
          return http.Response('', 404);
        }
        if (path.contains('/pin') ||
            path.contains('/reminder') ||
            path.contains('/schedule')) {
          requestLog.add('${request.method} $path');
          if (onRichChat != null) {
            return onRichChat(request);
          }
          return http.Response(jsonEncode(_emptyOcs(200)), 200);
        }
        // The room's own live sync always reports "nothing new", so the
        // timeline never moves underneath a test and the foreground loop
        // has nothing to re-render.
        return http.Response('', 403);
      }),
    );
    addTearDown(api.close);
    return api;
  }

  Widget wrap({required HttpNextcloudApi api, required Widget home}) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        // None of these features touch attachment transport; resolving the
        // dependency as unavailable keeps the media buttons settled instead of
        // spinning forever.
        chatAttachmentDependenciesProvider.overrideWith(
          (ref, key) => Future<ChatAttachmentDependencies>.error(
            StateError('attachment dependencies are not wired in this suite'),
            StackTrace.empty,
          ),
        ),
      ],
      child: localizedTestApp(home: home),
    );
  }

  group('pinned message banner', () {
    // Both entry points the app actually opens a room through wrap the same
    // pane, so the banner has to appear in both. A feature visible only from
    // the test-only `ChatRoomScreen` is not shipped.
    testWidgets('appears in the presence chat room screen', (tester) async {
      final conversation = await insertRoom(lastPinnedId: 10);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsOneWidget);
      expect(find.text('Pinned message'), findsOneWidget);
      expect(find.text('Cached hello'), findsWidgets);

      await teardownTree(tester);
    });

    testWidgets('appears in the presence chat room pane', (tester) async {
      final conversation = await insertRoom(lastPinnedId: 10);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: Scaffold(
            body: PresenceChatRoomPane(
              account: account,
              conversation: conversation,
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('stays away when nothing is pinned', (tester) async {
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsNothing);

      await teardownTree(tester);
    });

    // `hiddenPinnedId == lastPinnedId` is exactly how the server reports
    // "this attendee hid the pin".
    testWidgets('stays away once this account hid the pin', (tester) async {
      final conversation = await insertRoom(
        lastPinnedId: 10,
        hiddenPinnedId: 10,
      );
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('hiding it calls pin/self for this account only', (
      tester,
    ) async {
      final conversation = await insertRoom(lastPinnedId: 10);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('chat-pinned-banner-hide')));
      await flush(tester);

      expect(
        requestLog,
        contains(
          'DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/pin/self',
        ),
      );

      await teardownTree(tester);
    });
  });

  group('pin action', () {
    testWidgets('a moderator can pin a message', (tester) async {
      // participantType 2 is a moderator.
      final conversation = await insertRoom(participantType: 2);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) =>
                http.Response(jsonEncode(_pinResponse()), 200),
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      expect(find.byKey(const Key('message-action-pin')), findsOneWidget);
      expect(find.byKey(const Key('message-action-unpin')), findsNothing);

      await tester.tap(find.byKey(const Key('message-action-pin')));
      await flush(tester);
      await pumpUntil(
        tester,
        () => find.byKey(const Key('chat-pin-success')).evaluate().isNotEmpty,
      );

      expect(
        requestLog,
        contains('POST /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/pin'),
      );
      expect(find.byKey(const Key('chat-pin-success')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('the already pinned message offers unpin instead', (
      tester,
    ) async {
      final conversation = await insertRoom(
        participantType: 2,
        lastPinnedId: 10,
      );
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) =>
                http.Response(jsonEncode(_pinResponse()), 200),
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      expect(find.byKey(const Key('message-action-pin')), findsNothing);

      await tester.tap(find.byKey(const Key('message-action-unpin')));
      await flush(tester);

      expect(
        requestLog,
        contains('DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/pin'),
      );

      await teardownTree(tester);
    });

    // `#[RequireModeratorParticipant]` guards both pin routes, so an ordinary
    // participant must never be offered the action.
    testWidgets('an ordinary participant is not offered pinning', (
      tester,
    ) async {
      final conversation = await insertRoom(participantType: 3);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);

      expect(find.byKey(const Key('message-action-pin')), findsNothing);
      expect(find.byKey(const Key('message-action-unpin')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('a server without pinned-messages offers nothing', (
      tester,
    ) async {
      final conversation = await insertRoom(participantType: 2);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            talkFeatures: const <String>[
              'conversation-v4',
              'chat-v2',
              'chat-reference-id',
            ],
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);

      expect(find.byKey(const Key('message-action-pin')), findsNothing);
      expect(find.byKey(const Key('message-action-remind')), findsNothing);

      await teardownTree(tester);
    });
  });

  group('reminder action', () {
    testWidgets('setting a reminder posts the chosen timestamp', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) {
              if (request.method == 'GET') {
                // No reminder yet: Talk answers 404, which must read as
                // "none set" rather than as a failure.
                return http.Response(jsonEncode(_failureOcs(404)), 404);
              }
              return http.Response(
                jsonEncode(
                  _reminderOcs(
                    201,
                    int.parse(request.bodyFields['timestamp']!),
                  ),
                ),
                201,
              );
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('message-action-remind')));
      await flush(tester);

      expect(find.byKey(const Key('reminder-sheet-title')), findsOneWidget);
      // With no reminder set there is nothing to remove.
      expect(find.byKey(const Key('reminder-remove')), findsNothing);

      final presets = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.key.toString().contains('reminder-preset-'),
      );
      expect(presets, findsWidgets);
      await tester.tap(presets.first);
      await flush(tester);

      expect(
        requestLog.where((entry) => entry.startsWith('POST')),
        contains(
          'POST /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/reminder',
        ),
      );
      expect(find.byKey(const Key('chat-reminder-set')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('an existing reminder can be removed', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) {
              if (request.method == 'GET') {
                return http.Response(
                  jsonEncode(_reminderOcs(200, 4102444800)),
                  200,
                );
              }
              return http.Response(jsonEncode(_emptyOcs(200)), 200);
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('message-action-remind')));
      await flush(tester);

      final remove = find.byKey(const Key('reminder-remove'));
      expect(remove, findsOneWidget);
      await tester.ensureVisible(remove);
      await settle(tester);
      await tester.tap(remove);
      await flush(tester);

      expect(
        requestLog,
        contains(
          'DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/reminder',
        ),
      );
      expect(find.byKey(const Key('chat-reminder-removed')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('a server without remind-me-later offers nothing', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            talkFeatures: const <String>[
              'conversation-v4',
              'chat-v2',
              'chat-reference-id',
              'pinned-messages',
            ],
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);

      expect(find.byKey(const Key('message-action-remind')), findsNothing);

      await teardownTree(tester);
    });
  });

  group('scheduled send', () {
    // `scheduled-messages` is announced only under `features-local`.
    testWidgets('the button stays hidden without the local capability', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(localFeatures: const <String>[]),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('schedule-message')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('a global feature entry does not enable it either', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            talkFeatures: const <String>[
              ..._fullFeatures,
              'scheduled-messages',
            ],
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('schedule-message')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('scheduling posts the composed text and clears it', (
      tester,
    ) async {
      final conversation = await insertRoom();
      String? postedMessage;
      int? postedSendAt;
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            localFeatures: const <String>['scheduled-messages'],
            onRichChat: (request) {
              postedMessage = request.bodyFields['message'];
              postedSendAt = int.tryParse(request.bodyFields['sendAt'] ?? '');
              return http.Response(
                jsonEncode(_scheduleOcs(201, postedSendAt ?? 0)),
                201,
              );
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'Send this later',
      );
      await settle(tester);

      final button = find.byKey(const Key('schedule-message'));
      expect(button, findsOneWidget);
      await tester.tap(button);
      await settle(tester);

      expect(find.byKey(const Key('send-later-title')), findsOneWidget);
      final presets = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.key.toString().contains('send-later-preset-'),
      );
      expect(presets, findsWidgets);
      await tester.tap(presets.first);
      await flush(tester);

      expect(postedMessage, 'Send this later');
      expect(postedSendAt, isNotNull);
      expect(
        postedSendAt!,
        greaterThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      );
      expect(
        requestLog,
        contains('POST /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/schedule'),
      );
      expect(find.byKey(const Key('chat-schedule-success')), findsOneWidget);
      // The text left the composer only because the server accepted it.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-composer')))
            .controller
            ?.text,
        isEmpty,
      );

      await teardownTree(tester);
    });

    // The whole point of not putting this in the durable outbox: a scheduled
    // message must never appear as a pending text send, because the outbox
    // would have nothing to correlate against until the server fires it.
    testWidgets('a scheduled send creates no text outbox operation', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            localFeatures: const <String>['scheduled-messages'],
            onRichChat: (request) => http.Response(
              jsonEncode(
                _scheduleOcs(201, int.parse(request.bodyFields['sendAt']!)),
              ),
              201,
            ),
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'Send this later',
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('schedule-message')));
      await settle(tester);
      await tester.tap(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is ListTile &&
                  widget.key.toString().contains('send-later-preset-'),
            )
            .first,
      );
      await flush(tester);

      final operations = await database
          .select(database.textSendOperations)
          .get();
      expect(operations, isEmpty);

      await teardownTree(tester);
    });

    testWidgets('the scheduled list opens and can delete an entry', (
      tester,
    ) async {
      final conversation = await insertRoom(hasScheduledMessages: 1);
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            localFeatures: const <String>['scheduled-messages'],
            onRichChat: (request) {
              if (request.method == 'GET') {
                return http.Response(
                  jsonEncode(
                    _ocs(200, <Object?>[_scheduledMessageJson(4102444800)]),
                  ),
                  200,
                );
              }
              // Talk answers a schedule delete with an empty object.
              return http.Response(
                jsonEncode(_ocs(200, <String, Object?>{})),
                200,
              );
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('open-scheduled-messages')));
      await flush(tester);

      expect(find.byKey(const Key('scheduled-messages-sheet')), findsOneWidget);
      final row = find.byKey(const Key('scheduled-message-77'));
      expect(row, findsOneWidget);
      expect(find.text('Scheduled hello'), findsOneWidget);

      await tester.tap(find.byKey(const Key('delete-scheduled-77')));
      await flush(tester);

      expect(
        requestLog,
        contains(
          'DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/schedule/77',
        ),
      );
      expect(
        find.byKey(const Key('scheduled-message-deleted')),
        findsOneWidget,
      );

      await teardownTree(tester);
    });

    testWidgets('the scheduled list entry point stays hidden when empty', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(localFeatures: const <String>['scheduled-messages']),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('open-scheduled-messages')), findsNothing);

      await teardownTree(tester);
    });
  });

  group('time presets', () {
    // The server refuses a reminder or a send time in the past, so a preset
    // that has already gone by must not be offered at all.
    test('a preset already gone by today is dropped', () {
      final strings = AppLocalizationsEn();
      final evening = DateTime(2026, 8, 25, 22);
      final labels = timePresets(
        strings,
        evening,
      ).map((preset) => preset.label).toList();
      expect(labels, isNot(contains(strings.reminderLaterToday)));
      expect(labels, contains(strings.reminderTomorrow));
    });

    test('every preset is in the future', () {
      final now = DateTime(2026, 8, 25, 9, 30);
      for (final preset in timePresets(AppLocalizationsEn(), now)) {
        expect(preset.at.isAfter(now), isTrue, reason: preset.label);
      }
    });

    // 25 August 2026 is a Tuesday, so the weekend is that Saturday and the
    // next week starts the following Monday.
    test('the weekend and next week land on the right days', () {
      final presets = timePresets(
        AppLocalizationsEn(),
        DateTime(2026, 8, 25, 9, 30),
      );
      final strings = AppLocalizationsEn();
      final weekend = presets.firstWhere(
        (preset) => preset.label == strings.reminderThisWeekend,
      );
      final nextWeek = presets.firstWhere(
        (preset) => preset.label == strings.reminderNextWeek,
      );
      expect(weekend.at.weekday, DateTime.saturday);
      expect(nextWeek.at.weekday, DateTime.monday);
      expect(nextWeek.at.isAfter(weekend.at), isTrue);
    });
  });

  group('pinned message state', () {
    test('a conversation cached without a room body reports no pin', () {
      final state = PinnedMessageState.fromCachedConversation(
        _bareConversation('{}'),
      );
      expect(state.isVisible, isFalse);
      expect(scheduledMessageCount(_bareConversation('{}')), 0);
    });

    test('an unreadable payload reports no pin', () {
      final state = PinnedMessageState.fromCachedConversation(
        _bareConversation('not json'),
      );
      expect(state.isVisible, isFalse);
    });
  });
}

CachedConversation _bareConversation(String rawJson) => CachedConversation(
  accountId: 'account-a',
  token: 'rooma123',
  displayName: 'Room',
  description: '',
  lastActivity: 0,
  unreadMessages: 0,
  favorite: false,
  readOnly: 0,
  roomType: 2,
  roomName: 'room',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  isArchived: false,
  rawJson: rawJson,
);

Map<String, Object?> _capabilitiesJson({
  required List<String> talkFeatures,
  required List<String> localFeatures,
}) {
  final json = capabilitiesJson(talkFeatures: talkFeatures);
  final ocs = json['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['features-local'] = <Object?>[...localFeatures];
  return json;
}

Map<String, Object?> _ocs(int statusCode, Object? data) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': statusCode,
      'message': 'OK',
    },
    'data': data,
  },
};

Map<String, Object?> _emptyOcs(int statusCode) =>
    _ocs(statusCode, <String, Object?>{});

Map<String, Object?> _failureOcs(int statusCode) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'failure',
      'statuscode': statusCode,
      'message': 'Not found',
    },
    'data': <String, Object?>{'error': 'message'},
  },
};

Map<String, Object?> _reminderOcs(int statusCode, int timestamp) =>
    _ocs(statusCode, <String, Object?>{
      'userId': 'fixture-user',
      'token': 'rooma123',
      'messageId': 10,
      'timestamp': timestamp,
    });

Map<String, Object?> _scheduleOcs(int statusCode, int sendAt) =>
    _ocs(statusCode, _scheduledMessageJson(sendAt));

Map<String, Object?> _scheduledMessageJson(int sendAt) => <String, Object?>{
  'id': '77',
  'actorId': 'fixture-user',
  'actorType': 'users',
  'threadId': 0,
  'message': 'Scheduled hello',
  'messageType': 'comment',
  'createdAt': 1724300000,
  'sendAt': sendAt,
  'silent': false,
};

/// A pin answers with the system message about the pinning, carrying the
/// pinned message itself as its parent.
Map<String, Object?> _pinResponse() => _ocs(200, <String, Object?>{
  ..._messageJson(messageId: 11, text: '', systemMessage: 'message_pinned'),
  'parent': _messageJson(messageId: 10, text: 'Cached hello'),
});

Map<String, Object?> _messageJson({
  required int messageId,
  required String text,
  String systemMessage = '',
}) => <String, Object?>{
  'id': messageId,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'someone-else',
  'actorDisplayName': 'Other person',
  'timestamp': 1724300000,
  'message': text,
  'messageParameters': <String, Object?>{},
  'messageType': systemMessage.isEmpty ? 'comment' : 'system',
  'systemMessage': systemMessage,
  'expirationTimestamp': 0,
  'referenceId': 'fixture-reference-$messageId',
  'isReplyable': true,
  'markdown': true,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'threadId': messageId,
};

Map<String, Object?> _roomJson({
  required int lastPinnedId,
  required int hiddenPinnedId,
  required int hasScheduledMessages,
  required int participantType,
}) {
  final response =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
  room['token'] = 'rooma123';
  room['readOnly'] = 0;
  room['lastPinnedId'] = lastPinnedId;
  room['hiddenPinnedId'] = hiddenPinnedId;
  room['hasScheduledMessages'] = hasScheduledMessages;
  room['participantType'] = participantType;
  // PERMISSIONS_MAX_DEFAULT: every permission granted without an override.
  room['permissions'] = 510;
  room['attendeePermissions'] = 0;
  room.remove('remoteServer');
  return room;
}
