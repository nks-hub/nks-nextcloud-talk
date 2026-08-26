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

part 'chat_room_connectivity_wake_test.part.dart';
part 'chat_room_read_marker_serialization_test.part.dart';

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

  testWidgets('ordinary thread pane never moves the root read marker', (
    tester,
  ) async {
    await _verifyThreadReadSuppressed(tester, namedThread: false);
  });

  testWidgets('named thread pane never moves the root read marker', (
    tester,
  ) async {
    await _verifyThreadReadSuppressed(tester, namedThread: true);
  });

  testWidgets('paused root pane never moves the read marker', (tester) async {
    await _verifySuppressedRootRead(
      tester,
      lifecycleState: AppLifecycleState.paused,
    );
  });

  testWidgets('hidden root pane never moves the read marker', (tester) async {
    await _verifySuppressedRootRead(
      tester,
      lifecycleState: AppLifecycleState.hidden,
    );
  });

  testWidgets(
    'jumping to an older message never marks the newer message read',
    (tester) async {
      await _verifySuppressedRootRead(tester, jumpToMessageId: 119);
    },
  );

  testWidgets('disposing a stale room generation prevents its read request', (
    tester,
  ) async {
    await _verifySuppressedRootRead(tester, disposeBeforeResponse: true);
  });

  _registerConnectivityWakeTest();
  _registerReadMarkerSerializationTest();
}

Future<void> _verifyThreadReadSuppressed(
  WidgetTester tester, {
  required bool namedThread,
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
    createdAt: DateTime.utc(2026),
  );
  vault.values[account.id] = 'fixture-app-password-never-use';
  final roomWire = _conversationRoomJson();
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
  final messageWire = _threadRootMessage(namedThread: namedThread);
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: account.id,
          roomToken: room.token.value,
          messageId: 109,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 1770000109,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'thread-root-109',
          displayText: namedThread
              ? 'Named thread root'
              : 'Ordinary thread root',
          deleted: false,
          threadId: Value(namedThread ? 109 : null),
          rawJson: jsonEncode(messageWire),
        ),
      );
  const features = {
    'chat-v2',
    'chat-read-marker',
    'chat-read-last',
    'chat-keep-notifications',
    'threads',
  };
  await chat.recordCapabilities(
    accountId: account.id,
    talkFeatures: features,
    observedAt: DateTime.utc(2026),
  );
  await chat.ensureRootScope(account: account, conversation: conversation);
  await chat.ensureThreadScope(
    account: account,
    conversation: conversation,
    threadId: 109,
  );
  if (namedThread) {
    await chat.ensureNamedThreadNetworkScope(
      account: account,
      conversation: conversation,
      threadId: 109,
    );
  }

  final readTargets = <int>[];
  final longPollResponse = Completer<http.Response>();
  final longPollReleased = Completer<void>();
  var longPollStarted = false;
  final api = HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return http.Response(
          jsonEncode(capabilitiesJson(talkFeatures: features.toList())),
          200,
        );
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/chat/rooma123/read')) {
        readTargets.add(
          int.parse(Uri.splitQueryString(request.body)['lastReadMessage']!),
        );
        return http.Response(
          jsonEncode(_readMarkerResponse(readTargets.last)),
          200,
        );
      }
      if (request.url.queryParameters['timeout'] == '30') {
        longPollStarted = true;
        try {
          return await longPollResponse.future;
        } finally {
          if (!longPollReleased.isCompleted) {
            longPollReleased.complete();
          }
        }
      }
      return http.Response('', 304);
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
        connectivityWakeEventsProvider.overrideWithValue(
          const Stream<void>.empty(),
        ),
      ],
      child: localizedTestApp(
        home: ChatRoomPane(
          account: account,
          conversation: conversation,
          threadId: 109,
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find
        .text(
          namedThread ? 'Named thread root' : 'Ordinary thread root',
          findRichText: true,
        )
        .evaluate()
        .isNotEmpty,
  );
  await _pumpUntil(tester, () => longPollStarted);
  await tester.pump(const Duration(milliseconds: 100));
  expect(readTargets, isEmpty);
  await tester.pumpWidget(const SizedBox.shrink());
  if (!longPollResponse.isCompleted) {
    longPollResponse.complete(http.Response('', 304));
  }
  if (longPollStarted && !longPollReleased.isCompleted) {
    await _pumpUntil(tester, () => longPollReleased.isCompleted);
  }
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 1)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _verifySuppressedRootRead(
  WidgetTester tester, {
  AppLifecycleState lifecycleState = AppLifecycleState.resumed,
  int? jumpToMessageId,
  bool disposeBeforeResponse = false,
}) async {
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final vault = MemoryCredentialVault();
  final account = await accounts.upsertAccount(
    accountId: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026),
  );
  vault.values[account.id] = 'fixture-app-password-never-use';
  final roomWire = _conversationRoomJson();
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
  final conversation = await ChatRepository(
    database,
  ).getConversation(accountId: account.id, roomToken: room.token.value);

  final delayedResponse = Completer<http.Response>();
  final longPollResponse = Completer<http.Response>();
  final longPollReleased = Completer<void>();
  final readTargets = <int>[];
  var futureRequests = 0;
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
      if (request.method == 'POST' &&
          request.url.path.endsWith('/chat/rooma123/read')) {
        final target = int.parse(
          Uri.splitQueryString(request.body)['lastReadMessage']!,
        );
        readTargets.add(target);
        return http.Response(jsonEncode(_readMarkerResponse(target)), 200);
      }
      if (request.url.queryParameters['lookIntoFuture'] == '0') {
        return http.Response('', 304);
      }
      futureRequests++;
      if (futureRequests == 1 && disposeBeforeResponse) {
        return delayedResponse.future;
      }
      if (futureRequests == 1) {
        return http.Response(
          jsonEncode(
            _externalRootMessagesResponse(
              includeOlder: jumpToMessageId != null,
            ),
          ),
          200,
          headers: const {
            'X-Chat-Last-Given': '120',
            'X-Chat-Last-Common-Read': '110',
          },
        );
      }
      if (futureRequests == 2 && !disposeBeforeResponse) {
        return http.Response('', 304);
      }
      try {
        return await longPollResponse.future;
      } finally {
        if (!longPollReleased.isCompleted) {
          longPollReleased.complete();
        }
      }
    }),
  );
  addTearDown(api.close);

  tester.binding.handleAppLifecycleStateChanged(lifecycleState);
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
        home: ChatRoomPane(
          account: account,
          conversation: conversation!,
          jumpToMessageId: jumpToMessageId,
        ),
      ),
    ),
  );

  if (lifecycleState != AppLifecycleState.resumed) {
    await tester.pump(const Duration(milliseconds: 100));
    expect(futureRequests, 0);
  } else if (disposeBeforeResponse) {
    await _pumpUntil(tester, () => futureRequests == 1);
    await tester.pumpWidget(const SizedBox.shrink());
    delayedResponse.complete(
      http.Response(
        jsonEncode(_externalRootMessagesResponse()),
        200,
        headers: const {
          'X-Chat-Last-Given': '120',
          'X-Chat-Last-Common-Read': '110',
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await _pumpUntil(
      tester,
      () =>
          find.text('Newer message', findRichText: true).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  expect(readTargets, isEmpty);
  await tester.pumpWidget(const SizedBox.shrink());
  if (disposeBeforeResponse) {
    await _pumpUntil(tester, () => futureRequests == 2);
  }
  if (!longPollResponse.isCompleted) {
    longPollResponse.complete(http.Response('', 304));
  }
  if (disposeBeforeResponse && !longPollReleased.isCompleted) {
    await _pumpUntil(tester, () => longPollReleased.isCompleted);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 1)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
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
  final readTargets = <int>[];
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
                'chat-read-marker',
                'chat-read-last',
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
      if (request.method == 'POST' &&
          request.url.path.endsWith('/chat/rooma123/read')) {
        final target = int.parse(
          Uri.splitQueryString(request.body)['lastReadMessage']!,
        );
        readTargets.add(target);
        return http.Response(jsonEncode(_readMarkerResponse(target)), 200);
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
        connectivityWakeEventsProvider.overrideWithValue(
          const Stream<void>.empty(),
        ),
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
  if (threadId == null) {
    await _pumpUntil(tester, () => readTargets.isNotEmpty);
    expect(readTargets, [120]);
  } else {
    expect(readTargets, isEmpty);
  }

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
  if (threadId == null) {
    expect(isolatedScope, isNull);
  } else {
    expect(isolatedScope?.scopeKey, 'root');
    expect(isolatedScope?.futureCursor, '109');
  }
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

Map<String, Object?> _externalRootMessagesResponse({
  bool includeOlder = false,
}) {
  final response = _externalMessageResponse(
    message: 'Newer message',
    threadId: null,
  );
  if (!includeOlder) {
    return response;
  }
  final ocs = response['ocs']! as Map<String, Object?>;
  final newer = Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).single! as Map<String, Object?>,
  );
  final older = Map<String, Object?>.from(newer)
    ..['id'] = 119
    ..['timestamp'] = 1770000119
    ..['message'] = 'Older message';
  ocs['data'] = <Object?>[older, newer];
  return response;
}

Map<String, Object?> _threadRootMessage({required bool namedThread}) {
  final response = _externalMessageResponse(
    message: namedThread ? 'Named thread root' : 'Ordinary thread root',
    threadId: namedThread ? 109 : null,
  );
  final ocs = response['ocs']! as Map<String, Object?>;
  final message =
      Map<String, Object?>.from(
          (ocs['data']! as List<Object?>).single! as Map<String, Object?>,
        )
        ..['id'] = 109
        ..['timestamp'] = 1770000109
        ..['isThread'] = namedThread
        ..['threadTitle'] = namedThread ? 'Named thread' : null;
  if (!namedThread) {
    message.remove('threadId');
  }
  return message;
}

Map<String, Object?> _readMarkerResponse(int messageId) => {
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
      'token': 'rooma123',
      'lastReadMessage': messageId,
      'lastCommonReadMessage': messageId,
      'unreadMessages': 0,
    },
  },
};
