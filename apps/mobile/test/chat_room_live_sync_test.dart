import 'dart:async';
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
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('root pane keeps background long poll silent and converges', (
    tester,
  ) async {
    await _verifyLiveBridge(tester, threadId: null);
  });

  testWidgets('thread pane keeps background long poll silent and converges', (
    tester,
  ) async {
    await _verifyLiveBridge(tester, threadId: 109);
  });
}

Future<void> _verifyLiveBridge(
  WidgetTester tester, {
  required int? threadId,
}) async {
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final chat = ChatRepository(database);
  final vault = MemoryCredentialVault();
  final account = await accounts.upsertAccount(
    accountId: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  vault.values[account.id] = 'fixture-app-password-never-use';

  final roomJson = _conversationRoomJson();
  final room = ConversationRoom.fromJson(roomJson);
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
          readOnly: Value(room.readOnly),
          roomType: Value(room.type),
          roomName: Value(room.name),
          objectType: Value(room.objectType),
          avatarVersion: Value(room.avatarVersion),
          isCustomAvatar: Value(room.isCustomAvatar),
          rawJson: jsonEncode(roomJson),
        ),
      );
  final conversation = await chat.getConversation(
    accountId: account.id,
    roomToken: room.token.value,
  );
  expect(conversation, isNotNull);

  final futureTimeouts = <String?>[];
  final initialResponse = Completer<http.Response>();
  final longPollResponse = Completer<http.Response>();
  final retryResponse = Completer<http.Response>();
  final convergenceResponse = Completer<http.Response>();
  final steadyPollResponse = Completer<http.Response>();
  final steadyPollReleased = Completer<void>();
  final messageText = threadId == null
      ? 'External root live message'
      : 'External thread live message';
  final api = HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const <String>[
                'conversation-v4',
                'chat-v2',
                'chat-reference-id',
                'chat-keep-notifications',
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

      expect(request.method, 'GET');
      expect(request.url.path, endsWith('/apps/spreed/api/v1/chat/rooma123'));
      expect(request.headers['Authorization'], startsWith('Basic '));
      expect(request.url.queryParameters['threadId'], threadId?.toString());
      if (request.url.queryParameters['lookIntoFuture'] == '0') {
        return http.Response('', 304);
      }

      futureTimeouts.add(request.url.queryParameters['timeout']);
      final interactiveCatchUp = const <int>{
        1,
        3,
        4,
      }.contains(futureTimeouts.length);
      expect(
        request.url.queryParameters['noStatusUpdate'],
        interactiveCatchUp ? '0' : '1',
      );
      expect(
        request.url.queryParameters['markNotificationsAsRead'],
        interactiveCatchUp ? '1' : '0',
      );
      switch (futureTimeouts.length) {
        case 1:
          expect(request.url.queryParameters['lastKnownMessageId'], '109');
          return await initialResponse.future;
        case 2:
          expect(request.url.queryParameters['lastKnownMessageId'], '109');
          return await longPollResponse.future;
        case 3:
          expect(request.url.queryParameters['lastKnownMessageId'], '109');
          return await retryResponse.future;
        case 4:
          expect(request.url.queryParameters['lastKnownMessageId'], '120');
          return await convergenceResponse.future;
        case 5:
          expect(request.url.queryParameters['lastKnownMessageId'], '120');
          try {
            return await steadyPollResponse.future;
          } finally {
            steadyPollReleased.complete();
          }
        default:
          fail('Unexpected extra future request');
      }
    }),
  );
  addTearDown(api.close);

  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
      ],
      child: localizedTestApp(
        home: ChatRoomPane(
          account: account,
          conversation: conversation!,
          threadId: threadId,
        ),
      ),
    ),
  );

  await _pumpUntil(tester, () => futureTimeouts.length == 1);
  expect(
    _syncIndicatorVisible(),
    isTrue,
    reason: 'The initial foreground synchronization must show progress',
  );
  expect(
    tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .semanticsLabel,
    'Syncing…',
  );
  initialResponse.complete(http.Response('', 304));
  await _pumpUntil(tester, () => !_syncIndicatorVisible());
  await tester.pump(const Duration(seconds: 1));
  await _pumpUntil(tester, () => futureTimeouts.length == 2);
  final showedProgressDuringBackgroundPoll = _syncIndicatorVisible();
  longPollResponse.complete(http.Response('', 503));
  await _pumpUntil(
    tester,
    () => find.byIcon(Icons.cloud_off_rounded).evaluate().isNotEmpty,
  );
  expect(_syncIndicatorVisible(), isFalse);
  await tester.tap(find.byKey(const Key('retry-chat-sync')));
  await _pumpUntil(
    tester,
    () => futureTimeouts.length == 3 && _syncIndicatorVisible(),
  );
  expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  retryResponse.complete(
    http.Response(
      jsonEncode(
        _externalMessageResponse(message: messageText, threadId: threadId),
      ),
      200,
      headers: const <String, String>{
        'X-Chat-Last-Given': '120',
        'X-Chat-Last-Common-Read': '110',
      },
    ),
  );
  await _pumpUntil(
    tester,
    () => find.text(messageText, findRichText: true).evaluate().isNotEmpty,
  );
  await _pumpUntil(tester, () => futureTimeouts.length == 4);
  expect(_syncIndicatorVisible(), isTrue);
  expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  convergenceResponse.complete(http.Response('', 304));
  await _pumpUntil(
    tester,
    () => find.byIcon(Icons.cloud_off_rounded).evaluate().isEmpty,
  );
  await _pumpUntil(tester, () => !_syncIndicatorVisible());
  await tester.pump(const Duration(seconds: 1));
  await _pumpUntil(
    tester,
    () => futureTimeouts.length == 5 && !_syncIndicatorVisible(),
  );
  expect(
    showedProgressDuringBackgroundPoll,
    isFalse,
    reason: 'A waiting background long poll must not look like active loading',
  );

  expect(futureTimeouts, ['0', '30', '0', '0', '30']);
  expect(find.text(messageText, findRichText: true), findsOneWidget);

  late List<CachedChatMessage> activeMessages;
  late List<CachedChatMessage> isolatedMessages;
  StoredChatScope? scope;
  StoredChatScope? isolatedScope;
  await tester.runAsync(() async {
    activeMessages = await chat
        .watchMessages(
          accountId: account.id,
          roomToken: room.token.value,
          threadId: threadId,
        )
        .first
        .timeout(const Duration(seconds: 2));
    isolatedMessages = await chat
        .watchMessages(
          accountId: account.id,
          roomToken: room.token.value,
          threadId: threadId == null ? 109 : null,
        )
        .first
        .timeout(const Duration(seconds: 2));
    scope = await chat.getScope(
      accountId: account.id,
      roomToken: room.token.value,
      threadId: threadId,
    );
    isolatedScope = await chat.getScope(
      accountId: account.id,
      roomToken: room.token.value,
      threadId: threadId == null ? 109 : null,
    );
  });

  expect(activeMessages.map((message) => message.messageId), [120]);
  expect(activeMessages.single.displayText, messageText);
  expect(isolatedMessages, isEmpty);
  expect(scope?.futureCursor, '120');
  expect(scope?.futureConverged, isTrue);
  expect(scope?.lastSyncError, isNull);
  expect(isolatedScope, isNull);
  expect(tester.takeException(), isNull);

  await tester.pumpWidget(const SizedBox.shrink());
  steadyPollResponse.complete(http.Response('', 304));
  await _pumpUntil(tester, () => steadyPollReleased.isCompleted);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

bool _syncIndicatorVisible() =>
    find.byType(LinearProgressIndicator).evaluate().isNotEmpty;

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
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

Map<String, Object?> _conversationRoomJson() {
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
  );
  lastMessage['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _externalMessageResponse({
  required String message,
  required int? threadId,
}) {
  final response =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-future.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  final external = Map<String, Object?>.from(
    messages.first! as Map<String, Object?>,
  );
  external['id'] = 120;
  external['timestamp'] = 1770000120;
  external['message'] = message;
  external['messageParameters'] = <String, Object?>{};
  if (threadId != null) {
    external['threadId'] = threadId;
  }
  ocs['data'] = <Object?>[external];
  return response;
}
