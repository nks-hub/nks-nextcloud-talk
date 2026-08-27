import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Covers the composer focus rules: auto-focusing a freshly opened thread on
/// desktop only, and keeping (or restoring) the caret across the emoji
/// panel on desktop while leaving the touch unfocus-on-open behavior alone.
///
/// `debugDefaultTargetPlatformOverride` must be reset in the BODY of each
/// test, not via `addTearDown` — the "foundation debug variable" invariant
/// is checked before teardowns run, so an `addTearDown` reset trips it on
/// the NEXT test.
void main() {
  Future<({StoredAccount account, CachedConversation conversation})>
  pumpRoom(
    WidgetTester tester, {
    required TargetPlatform platform,
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
                  'threads',
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

    debugDefaultTargetPlatformOverride = platform;
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
          theme: AppTheme.light(),
          home: ChatRoomPane(
            account: account,
            conversation: conversation,
            threadId: threadId,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    return (account: account, conversation: conversation);
  }

  /// Unmounts the tree and clears the platform override before the test
  /// body returns, so the next test's invariant check starts clean.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  bool composerHasFocus(WidgetTester tester) {
    final textField = tester.widget<TextField>(
      find.byKey(const Key('chat-composer')),
    );
    return textField.focusNode!.hasFocus;
  }

  testWidgets('opening a thread autofocuses the composer on desktop', (
    tester,
  ) async {
    await pumpRoom(tester, platform: TargetPlatform.windows, threadId: 42);
    expect(composerHasFocus(tester), isTrue);
    await settle(tester);
  });

  testWidgets('opening a thread leaves the composer unfocused on touch', (
    tester,
  ) async {
    await pumpRoom(tester, platform: TargetPlatform.android, threadId: 42);
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets('opening the root room does not autofocus on desktop', (
    tester,
  ) async {
    await pumpRoom(tester, platform: TargetPlatform.windows);
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets(
    'opening the emoji panel keeps the composer focused on desktop',
    (tester) async {
      await pumpRoom(tester, platform: TargetPlatform.windows);
      await tester.tap(find.byKey(const Key('chat-composer')));
      await tester.pump();
      expect(composerHasFocus(tester), isTrue);

      await tester.tap(find.byKey(const Key('open-emoji-picker')));
      await tester.pump();

      expect(find.byKey(const Key('inline-emoji-panel')), findsOneWidget);
      expect(composerHasFocus(tester), isTrue);
      await settle(tester);
    },
  );

  testWidgets('opening the emoji panel unfocuses the composer on touch', (
    tester,
  ) async {
    await pumpRoom(tester, platform: TargetPlatform.android);
    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pump();
    expect(composerHasFocus(tester), isTrue);

    await tester.tap(find.byKey(const Key('open-emoji-picker')));
    await tester.pump();

    expect(find.byKey(const Key('inline-emoji-panel')), findsOneWidget);
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets('closing the emoji panel restores composer focus on desktop', (
    tester,
  ) async {
    await pumpRoom(tester, platform: TargetPlatform.windows);
    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-emoji-picker')));
    await tester.pump();
    expect(composerHasFocus(tester), isTrue);

    // Something other than the composer steals focus while picking, the way
    // a search inside the picker would.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(composerHasFocus(tester), isFalse);

    await tester.tap(find.byKey(const Key('emoji-close')));
    await tester.pump();

    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);
    expect(composerHasFocus(tester), isTrue);
    await settle(tester);
  });
}

Map<String, Object?> _roomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}
