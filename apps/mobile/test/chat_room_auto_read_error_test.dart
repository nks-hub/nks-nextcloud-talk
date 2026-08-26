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
  testWidgets('auto-read reports each preparation invariant only once', (
    tester,
  ) async {
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

    var capabilityRequests = 0;
    var futureRequests = 0;
    var readPosts = 0;
    var serveNextMessage = false;
    var nextMessageServed = false;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          capabilityRequests++;
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
          readPosts++;
          final target = int.parse(
            Uri.splitQueryString(request.body)['lastReadMessage']!,
          );
          return http.Response(jsonEncode(_readMarkerResponse(target)), 200);
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response('', 304);
        }

        futureRequests++;
        if (futureRequests == 1) {
          await _corruptConversationToken(database, roomWire);
          return _messageResponse(120, 'Message 120');
        }
        if (futureRequests == 2) {
          return http.Response('', 304);
        }
        if (serveNextMessage && !nextMessageServed) {
          nextMessageServed = true;
          return _messageResponse(121, 'Message 121');
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);

    final errors = <Object>[];
    final previousFlutterErrorHandler = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previousFlutterErrorHandler);
    FlutterError.onError = (details) {
      if (details.library == 'Nextcloud Talk chat') {
        errors.add(details.exception);
        return;
      }
      previousFlutterErrorHandler?.call(details);
    };
    late int attemptsAfterFirstError;
    late int attemptsAfterSameMarkerCycle;
    late int reportsAfterSameMarkerCycle;
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
          home: ChatRoomPane(account: account, conversation: conversation),
        ),
      ),
    );

    await _pumpUntil(tester, () => errors.length == 1);
    attemptsAfterFirstError = capabilityRequests;

    final requestsBeforeSameMarkerCycle = futureRequests;
    await _pumpUntil(
      tester,
      () => futureRequests > requestsBeforeSameMarkerCycle,
    );
    await _pumpFrames(tester, 3);
    attemptsAfterSameMarkerCycle = capabilityRequests;
    reportsAfterSameMarkerCycle = errors.length;

    serveNextMessage = true;
    await _pumpUntil(tester, () => nextMessageServed);
    final nextMessage = find.byKey(
      const ValueKey('chat-message-account-a-rooma123-121'),
    );
    await _pumpUntil(tester, () => nextMessage.evaluate().isNotEmpty);
    await tester.ensureVisible(nextMessage);
    await tester.pump();
    await _pumpUntil(tester, () => errors.length == 2);
    FlutterError.onError = previousFlutterErrorHandler;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(
      errors,
      everyElement(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Conversation token does not match its payload',
        ),
      ),
    );
    expect(attemptsAfterFirstError, 1);
    expect(attemptsAfterSameMarkerCycle, 1);
    expect(reportsAfterSameMarkerCycle, 1);
    expect(capabilityRequests, 1);
    expect(errors, hasLength(2));
    expect(readPosts, 0);
  });

  testWidgets('auto-read retries a retryable room settings failure', (
    tester,
  ) async {
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

    var futureRequests = 0;
    final readTargets = <int>[];
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
          if (readTargets.length == 1) {
            return http.Response('', 503);
          }
          return http.Response(jsonEncode(_readMarkerResponse(target)), 200);
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response('', 304);
        }

        futureRequests++;
        if (futureRequests == 1) {
          return _messageResponse(120, 'Message 120');
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
          home: ChatRoomPane(account: account, conversation: conversation),
        ),
      ),
    );

    await _pumpUntil(tester, () => readTargets.length == 1);
    await _pumpUntil(tester, () => readTargets.length == 2);
    final requestsBeforeSettledCycle = futureRequests;
    await _pumpUntil(tester, () => futureRequests > requestsBeforeSettledCycle);
    await _pumpFrames(tester, 3);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(readTargets, [120, 120]);
  });
}

Future<void> _corruptConversationToken(
  AppDatabase database,
  Map<String, Object?> roomWire,
) async {
  final corruptedRoom = Map<String, Object?>.from(roomWire)
    ..['token'] = 'wrongroom';
  final lastMessage = corruptedRoom['lastMessage'];
  if (lastMessage is Map<String, Object?>) {
    corruptedRoom['lastMessage'] = Map<String, Object?>.from(lastMessage)
      ..['token'] = 'wrongroom';
  }
  await (database.update(database.cachedConversations)..where(
        (row) =>
            row.accountId.equals('account-a') & row.token.equals('rooma123'),
      ))
      .write(
        CachedConversationsCompanion(rawJson: Value(jsonEncode(corruptedRoom))),
      );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await _pumpFrames(tester, 1);
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
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
  )..['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

http.Response _messageResponse(int messageId, String message) {
  final root =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-future.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  final wire =
      Map<String, Object?>.from(messages.first! as Map<String, Object?>)
        ..['id'] = messageId
        ..['timestamp'] = 1770000000 + messageId
        ..['message'] = message
        ..['messageParameters'] = <String, Object?>{};
  ocs['data'] = <Object?>[wire];
  return http.Response(
    jsonEncode(root),
    200,
    headers: <String, String>{
      'X-Chat-Last-Given': '$messageId',
      'X-Chat-Last-Common-Read': '109',
    },
  );
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
