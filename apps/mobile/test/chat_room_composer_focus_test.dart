import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Covers the composer focus rules: auto-focusing a freshly opened thread on
/// desktop only, and keeping (or restoring) the caret across the emoji
/// panel on desktop.
///
/// `desktop` is faked through `Theme.of(context).visualDensity` (compact vs.
/// standard) — the exact signal `context.sendsOnEnter` reads — rather than
/// `debugDefaultTargetPlatformOverride`.
void main() {
  Future<({StoredAccount account, CachedConversation conversation})>
  pumpRoom(
    WidgetTester tester, {
    required bool desktop,
    int? threadId,
  }) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final chat = ChatRepository(database);
    final vault = MemoryCredentialVault();
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user-a',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    vault.values[account.id] = 'fixture-app-password-never-use';

    final roomWire = _roomJson();
    final room = ConversationRoom.fromJson(roomWire);
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: room.token.value,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            rawJson: jsonEncode(roomWire),
          ),
        );
    final conversation = (await chat.getConversation(
      accountId: account.id,
      roomToken: room.token.value,
    ))!;
    await chat.ensureRootScope(account: account, conversation: conversation);
    if (threadId != null) {
      await chat.ensureThreadScope(
        account: account,
        conversation: conversation,
        threadId: threadId,
      );
    }

    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-read-marker',
                  'chat-read-last',
                  'chat-keep-notifications',
                ],
              ),
            ),
            200,
          );
        }
        if (request.url.path.contains('/avatar/')) {
          return http.Response('', 404);
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);

    // The default 800x600 test surface clips the emoji panel plus the
    // composer below it; a desktop window is never that short.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          nextcloudApiProvider.overrideWithValue(api),
          connectivityWakeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
        ],
        child: localizedTestApp(
          // `context.sendsOnEnter` reads `Theme.of(context).visualDensity`
          // directly, so setting it here is enough.
          theme: ThemeData(
            visualDensity: desktop
                ? VisualDensity.compact
                : VisualDensity.standard,
          ),
          home: ChatRoomPane(
            account: account,
            conversation: conversation,
            threadId: threadId,
          ),
        ),
      ),
    );
    // The live sync loop behind `ChatRoomPane` uses real `Timer`s, which a
    // plain `tester.pump(duration)` never drives — only `runAsync` lets them
    // actually fire, the same pattern every other `ChatRoomPane` test uses.
    for (var attempt = 0; attempt < 5; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    return (account: account, conversation: conversation);
  }

  /// Unmounts the tree before the test body returns, so a drift stream's
  /// close timer cannot trip the pending-timer check on a LATER test.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  bool composerHasFocus(WidgetTester tester) {
    final textField = tester.widget<TextField>(
      find.byKey(const Key('chat-composer')),
    );
    return textField.focusNode!.hasFocus;
  }

  // The touch side of the same rule is not mounted here on purpose. Both
  // production call sites read `context.sendsOnEnter`, and that flag already
  // has direct coverage in `composer_enter_key_test.dart` — pointer density
  // yields true, finger density false, and the shipped theme agrees per
  // platform.

  testWidgets(
    'opening a thread autofocuses the composer on desktop',
    (tester) async {
      await pumpRoom(tester, desktop: true, threadId: 42);
      expect(composerHasFocus(tester), isTrue);
      await settle(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'opening the root room does not autofocus on desktop',
    (tester) async {
      await pumpRoom(tester, desktop: true);
      expect(composerHasFocus(tester), isFalse);
      await settle(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'opening the emoji panel keeps the composer focused on desktop',
    (tester) async {
      await pumpRoom(tester, desktop: true);
      await tester.tap(find.byKey(const Key('chat-composer')));
      await tester.pump();
      expect(composerHasFocus(tester), isTrue);

      await tester.tap(find.byKey(const Key('open-emoji-picker')));
      await tester.pump();

      expect(find.byKey(const Key('inline-emoji-panel')), findsOneWidget);
      expect(composerHasFocus(tester), isTrue);
      await settle(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'closing the emoji panel restores composer focus on desktop',
    (tester) async {
      await pumpRoom(tester, desktop: true);
      await tester.tap(find.byKey(const Key('chat-composer')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('open-emoji-picker')));
      await tester.pump();
      expect(composerHasFocus(tester), isTrue);

      // Something other than the composer steals focus while picking, the
      // way a search inside the picker would.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(composerHasFocus(tester), isFalse);

      await tester.tap(find.byKey(const Key('emoji-close')));
      await tester.pump();

      expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);
      expect(composerHasFocus(tester), isTrue);
      await settle(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Map<String, Object?> _roomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  )..['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}
