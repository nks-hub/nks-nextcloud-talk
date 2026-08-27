import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/push/windows_notification.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WindowsNotificationChannel.channelName);

  testWidgets(
    'native open selects the exact account and room on a shared host',
    (tester) async {
      final database = openTestDatabase();
      final accounts = AccountRepository(database);
      final vault = MemoryCredentialVault();
      final accountA = await _seedAccount(accounts, 'account-a');
      final accountB = await _seedAccount(accounts, 'account-b');
      final roomA = await _insertRoom(
        database,
        accountId: accountA.id,
        token: 'sharedroom',
        displayName: 'Room from account A',
        unreadMessages: 0,
        lastMessageId: 41,
      );
      final roomB = await _insertRoom(
        database,
        accountId: accountB.id,
        token: 'sharedroom',
        displayName: 'Room from account B',
        unreadMessages: 1,
        lastMessageId: 42,
      );
      await accounts.selectAccount(accountA.id);

      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          throw StateError('Open routing must not reach ${request.url}');
        }),
      );
      final selectedAccounts = StreamController<StoredAccount?>();
      final observedChatKeys = <ChatRoomProviderKey>{};

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => true);
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await selectedAccounts.close();
        api.close();
        await database.close();
      });

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            clientPushEnabledProvider.overrideWithValue(true),
            accountsProvider.overrideWith(
              (ref) => const Stream<List<StoredAccount>>.empty(),
            ),
            selectedAccountProvider.overrideWith(
              (ref) => selectedAccounts.stream,
            ),
            conversationsProvider.overrideWith(
              (ref, accountId) =>
                  Stream.value(accountId == accountA.id ? [roomA] : [roomB]),
            ),
            chatMessagesProvider.overrideWith((ref, key) {
              observedChatKeys.add(key);
              return Stream.value(const <CachedChatMessage>[]);
            }),
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
            chatAttachmentDependenciesProvider.overrideWith(
              (ref, key) => Future<ChatAttachmentDependencies>.error(
                StateError('Attachments are outside notification routing'),
                StackTrace.empty,
              ),
            ),
          ],
          child: localizedTestApp(home: const ConversationShell()),
        ),
      );
      selectedAccounts.add(accountA);
      await tester.pump();
      await tester.pump();

      final response = await _dispatchNative(
        const MethodCall('notificationOpened', <String, Object>{
          'accountId': 'account-b',
          'roomToken': 'sharedroom',
        }),
      );
      expect(response, isTrue);

      await _pumpUntilAsync(
        tester,
        () async => (await accounts.getAccount(accountB.id))?.selected == true,
      );
      selectedAccounts.add(accountB);
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-room-pane')).evaluate().isNotEmpty,
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('chat-room-header')),
          matching: find.text('Room from account B'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-room-header')),
          matching: find.text('Room from account A'),
        ),
        findsNothing,
      );
      expect(
        observedChatKeys,
        contains((
          accountId: accountB.id,
          roomToken: roomB.token,
          threadId: null,
        )),
      );
      expect((await accounts.getAccount(accountA.id))?.selected, isFalse);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  test('native actions use the target account durable services', () async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final chat = ChatRepository(database);
    final vault = MemoryCredentialVault();
    final accountA = await _seedAccount(accounts, 'account-a');
    final accountB = await _seedAccount(accounts, 'account-b');
    vault.values[accountA.id] = 'password-a';
    vault.values[accountB.id] = 'password-b';
    await _insertRoom(
      database,
      accountId: accountA.id,
      token: 'sharedroom',
      displayName: 'Room from account A',
      unreadMessages: 7,
      lastMessageId: 99,
    );
    await _insertRoom(
      database,
      accountId: accountB.id,
      token: 'sharedroom',
      displayName: 'Room from account B',
      unreadMessages: 2,
      lastMessageId: 4242,
    );

    const features = <String>{
      'conversation-v4',
      'chat-v2',
      'chat-reference-id',
      'chat-read-marker',
      'chat-read-last',
    };
    await accounts.updateTalkFeatures(accountB.id, features);
    await chat.recordCapabilities(
      accountId: accountB.id,
      talkFeatures: features,
      observedAt: DateTime.utc(2026, 1, 1),
    );

    var online = false;
    var roomReads = 0;
    final targetRequests = <http.Request>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (!online) {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            throw http.ClientException('Synthetic offline state', request.url);
          }
          throw StateError('Offline reply reached ${request.url}');
        }
        targetRequests.add(request);
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(capabilitiesJson(talkFeatures: features.toList())),
            200,
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/apps/spreed/api/v4/room')) {
          return http.Response(
            jsonEncode(
              _conversationResponse(
                token: 'sharedroom',
                displayName: 'Room from account B',
                unreadMessages: roomReads == 0 ? 2 : 0,
                lastMessageId: 4242,
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Nextcloud-Talk-Hash': 'windows-action-hash',
              'X-Nextcloud-Talk-Modified-Before': '1787864000',
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/chat/sharedroom/read')) {
          roomReads++;
          return http.Response(
            jsonEncode(
              _readResponse(roomToken: 'sharedroom', lastReadMessage: 4242),
            ),
            200,
          );
        }
        if (request.url.path.contains('/avatar')) {
          return http.Response('', 404);
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.url}',
        );
      }),
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        clientPushEnabledProvider.overrideWithValue(true),
        accountsProvider.overrideWith(
          (ref) => const Stream<List<StoredAccount>>.empty(),
        ),
      ],
    );
    final service = container.read(windowsNotificationServiceProvider);
    expect(service, isNotNull);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      api.close();
      await database.close();
    });

    final replyResponse = await _dispatchNative(
      const MethodCall('notificationAction', <String, Object>{
        'kind': 'reply',
        'accountId': 'account-b',
        'roomToken': 'sharedroom',
        'replyText': 'Reply from Windows',
      }),
    );
    expect(replyResponse, isTrue);

    final queued = await database.select(database.textSendOperations).get();
    expect(queued, hasLength(1));
    expect(queued.single.accountId, accountB.id);
    expect(queued.single.roomToken, 'sharedroom');
    expect(queued.single.message, 'Reply from Windows');
    expect(queued.single.outboxState, 'queued');

    online = true;
    final markReadResponse = await _dispatchNative(
      const MethodCall('notificationAction', <String, Object>{
        'kind': 'markRead',
        'accountId': 'account-b',
        'roomToken': 'sharedroom',
      }),
    );
    expect(markReadResponse, isTrue);
    expect(roomReads, 1);
    expect(
      targetRequests.where(
        (request) => request.url.path.endsWith('/chat/sharedroom/read'),
      ),
      hasLength(1),
    );
    expect(
      targetRequests.every(
        (request) =>
            request.url.host == 'shared.example.invalid' &&
            request.headers['Authorization'] ==
                'Basic ${base64Encode(utf8.encode('user-account-b:password-b'))}',
      ),
      isTrue,
    );
    final storedA = await accounts.getConversation(
      accountId: accountA.id,
      token: 'sharedroom',
    );
    final storedB = await accounts.getConversation(
      accountId: accountB.id,
      token: 'sharedroom',
    );
    expect(storedA?.unreadMessages, 7);
    expect(storedB?.unreadMessages, 0);
  });
}

Future<StoredAccount> _seedAccount(
  AccountRepository accounts,
  String accountId,
) {
  return accounts.upsertAccount(
    accountId: accountId,
    serverUrl: 'https://shared.example.invalid',
    loginName: 'user-$accountId',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026),
  );
}

Future<CachedConversation> _insertRoom(
  AppDatabase database, {
  required String accountId,
  required String token,
  required String displayName,
  required int unreadMessages,
  required int lastMessageId,
}) async {
  final roomJson = _roomJson(
    token: token,
    displayName: displayName,
    unreadMessages: unreadMessages,
    lastMessageId: lastMessageId,
  );
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
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
          lastMessageText: Value(room.lastMessage?.message),
          lastMessageTimestamp: Value(room.lastMessage?.timestamp),
          rawJson: jsonEncode(roomJson),
        ),
      );
  return (await AccountRepository(
    database,
  ).getConversation(accountId: accountId, token: token))!;
}

Map<String, Object?> _roomJson({
  required String token,
  required String displayName,
  required int unreadMessages,
  required int lastMessageId,
}) {
  final root =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'conversation-list/fixtures/conversations-full.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>)
    ..['token'] = token
    ..['displayName'] = displayName
    ..['unreadMessages'] = unreadMessages;
  final lastMessage =
      Map<String, Object?>.from(room['lastMessage']! as Map<String, Object?>)
        ..['token'] = token
        ..['id'] = lastMessageId;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _conversationResponse({
  required String token,
  required String displayName,
  required int unreadMessages,
  required int lastMessageId,
}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <Object?>[
        _roomJson(
          token: token,
          displayName: displayName,
          unreadMessages: unreadMessages,
          lastMessageId: lastMessageId,
        ),
      ],
    },
  };
}

Map<String, Object?> _readResponse({
  required String roomToken,
  required int lastReadMessage,
}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'token': roomToken,
        'lastReadMessage': lastReadMessage,
        'lastCommonReadMessage': lastReadMessage,
        'unreadMessages': 0,
      },
    },
  };
}

Future<Object?> _dispatchNative(MethodCall call) async {
  final response = await TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        WindowsNotificationChannel.channelName,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );
  return const StandardMethodCodec().decodeEnvelope(response!);
}

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

Future<void> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() condition,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    final reached = await tester.runAsync(condition);
    if (reached == true) {
      return;
    }
  }
  fail('Condition was not reached');
}
