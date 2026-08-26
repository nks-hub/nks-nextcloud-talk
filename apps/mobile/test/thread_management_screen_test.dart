import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/thread_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/threads/thread_management_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

const _server = 'https://cloud.example.invalid';
const _accountId = 'account-a';
const _roomToken = 'rooma123';

typedef _RequestHandler =
    FutureOr<http.Response> Function(http.Request request);

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ThreadRepository threads;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;
  late List<HttpNextcloudApi> testApis;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    threads = ThreadRepository(database);
    testApis = <HttpNextcloudApi>[];
    vault = MemoryCredentialVault()..values[_accountId] = 'fixture-password';
    account = await accounts.upsertAccount(
      accountId: _accountId,
      serverUrl: _server,
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      talkFeatures: const <String>{'conversation-v4', 'chat-v2', 'threads'},
      createdAt: DateTime.utc(2026, 8, 26),
    );
    await _insertRoom(database);
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
  });

  Widget buildApp({required Widget home, required _RequestHandler handler}) {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/ocs/v2.php/cloud/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const <String>[
                'conversation-v4',
                'chat-v2',
                'threads',
              ],
            ),
          ),
          200,
        );
      }
      return handler(request);
    });
    final api = HttpNextcloudApi(client: client);
    testApis.add(api);
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        chatAttachmentDependenciesProvider.overrideWith(
          (ref, key) => Future<ChatAttachmentDependencies>.error(
            StateError('attachments are outside this suite'),
            StackTrace.empty,
          ),
        ),
      ],
      child: localizedTestApp(home: home),
    );
  }

  Future<void> disposeHarness(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    for (final api in testApis) {
      api.close();
    }
    var closed = false;
    final closing = database.close().whenComplete(() => closed = true);
    for (var attempt = 0; attempt < 20 && !closed; attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    await closing;
  }

  Future<void> openDetail(
    WidgetTester tester, {
    required _RequestHandler handler,
  }) async {
    await tester.pumpWidget(
      buildApp(
        home: ThreadManagementScreen(
          account: account,
          conversation: conversation,
        ),
        handler: handler,
      ),
    );
    await _pumpUntil(tester, () => find.text('Design').evaluate().isNotEmpty);
    await tester.tap(
      find.byKey(const Key('thread-management-item-rooma123-120')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('thread-management-detail-screen'))
          .evaluate()
          .isNotEmpty,
    );
    await _pumpUntil(tester, () {
      final tile = tester.widget<ListTile>(
        find.byKey(const Key('thread-management-rename')),
      );
      return tile.enabled;
    });
  }

  testWidgets('compact room header opens full thread management screen', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    await tester.pumpWidget(
      buildApp(
        home: PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
        ),
        handler: _successfulHandler,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('open-thread-management')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-thread-management')));
    await _pumpUntil(
      tester,
      () => find.byType(ThreadManagementScreen).evaluate().isNotEmpty,
    );
    expect(find.byType(ThreadManagementScreen), findsOneWidget);
    expect(find.byKey(const Key('thread-management-screen')), findsOneWidget);
    expect(
      find.byKey(const Key('thread-management-recent-tab')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('thread-management-subscribed-tab')),
      findsOneWidget,
    );
    await disposeHarness(tester);
  });

  testWidgets('expanded room header opens full thread management screen', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    await tester.pumpWidget(
      buildApp(
        home: Scaffold(
          body: PresenceChatRoomPane(
            account: account,
            conversation: conversation,
          ),
        ),
        handler: _successfulHandler,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('open-thread-management')));
    await _pumpUntil(
      tester,
      () => find.byType(ThreadManagementScreen).evaluate().isNotEmpty,
    );

    expect(find.byType(ThreadManagementScreen), findsOneWidget);
    expect(find.text('Threads'), findsOneWidget);
    await disposeHarness(tester);
  });

  testWidgets('recent tab keeps cached rows visible while refresh is pending', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    await threads.replaceRecent(
      accountId: _accountId,
      roomToken: _roomToken,
      server: ServerBase.parse(_server),
      values: <RichChatThread>[
        _thread(id: 80, title: 'Cached thread', roomToken: _roomToken),
      ],
    );
    final response = Completer<http.Response>();
    addTearDown(() {
      if (!response.isCompleted) {
        response.complete(_ocsResponse(statusCode: 503, data: const []));
      }
    });

    await tester.pumpWidget(
      buildApp(
        home: ThreadManagementScreen(
          account: account,
          conversation: conversation,
        ),
        handler: (request) {
          if (request.url.path.endsWith('/threads/recent')) {
            return response.future;
          }
          return _ocsResponse(statusCode: 404, data: const {});
        },
      ),
    );
    await _pumpUntil(
      tester,
      () => find.text('Cached thread').evaluate().isNotEmpty,
    );

    expect(find.text('Cached thread'), findsOneWidget);
    expect(
      find.byKey(const Key('thread-management-list-progress')),
      findsOneWidget,
    );

    response.complete(_fixtureResponse('recent-threads-success'));
    await _pumpUntil(tester, () => find.text('Design').evaluate().isNotEmpty);
    expect(find.text('Cached thread'), findsNothing);
    await disposeHarness(tester);
  });

  testWidgets('empty recent failure exposes retry and then recovers', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    var recentRequests = 0;
    await tester.pumpWidget(
      buildApp(
        home: ThreadManagementScreen(
          account: account,
          conversation: conversation,
        ),
        handler: (request) {
          if (request.url.path.endsWith('/threads/recent')) {
            recentRequests++;
            return recentRequests == 1
                ? _ocsResponse(statusCode: 503, data: const {})
                : _fixtureResponse('recent-threads-success');
          }
          return _ocsResponse(statusCode: 404, data: const {});
        },
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('thread-management-error-retry'))
          .evaluate()
          .isNotEmpty,
    );

    expect(recentRequests, 1);
    await tester.tap(find.byKey(const Key('thread-management-error-retry')));
    await _pumpUntil(tester, () => find.text('Design').evaluate().isNotEmpty);

    expect(recentRequests, 2);
    expect(find.text('Design'), findsOneWidget);
    await disposeHarness(tester);
  });

  testWidgets('subscribed tab loads account-wide threads on demand', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    var subscribedRequests = 0;
    await tester.pumpWidget(
      buildApp(
        home: ThreadManagementScreen(
          account: account,
          conversation: conversation,
        ),
        handler: (request) {
          if (request.url.path.endsWith('/threads/recent')) {
            return _ocsResponse(statusCode: 200, data: const []);
          }
          if (request.url.path.endsWith('/subscribed-threads')) {
            subscribedRequests++;
            return _ocsResponse(
              statusCode: 200,
              data: <Object?>[
                _threadWire(
                  id: 130,
                  title: 'Subscribed thread',
                  roomToken: _roomToken,
                ),
              ],
            );
          }
          return _ocsResponse(statusCode: 404, data: const {});
        },
      ),
    );
    await _pumpUntil(
      tester,
      () => find.text('No recent threads').evaluate().isNotEmpty,
    );
    expect(subscribedRequests, 0);

    await tester.tap(find.byKey(const Key('thread-management-subscribed-tab')));
    await _pumpUntil(
      tester,
      () => find.text('Subscribed thread').evaluate().isNotEmpty,
    );

    expect(subscribedRequests, 1);
    expect(find.text('Subscribed thread'), findsOneWidget);
    await disposeHarness(tester);
  });

  testWidgets('detail renames thread and changes notification level', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    var mutationCount = 0;
    await openDetail(
      tester,
      handler: (request) {
        if (request.url.path.endsWith('/threads/recent')) {
          return _fixtureResponse('recent-threads-success');
        }
        if (request.method == 'PUT') {
          mutationCount++;
          return _fixtureResponse('thread-rename-success');
        }
        if (request.method == 'POST' && request.url.path.endsWith('/notify')) {
          mutationCount++;
          final data = _threadWire(
            id: 120,
            title: 'Updated design',
            roomToken: _roomToken,
          )..['attendee'] = const <String, Object?>{'notificationLevel': 3};
          return _ocsResponse(statusCode: 200, data: data);
        }
        return _fixtureResponse('thread-detail-success');
      },
    );

    expect(
      find.byKey(const Key('thread-management-detail-screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('thread-management-notification-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('thread-management-notification-3')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('thread-management-rename')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('thread-management-rename-field')),
      'Updated design',
    );
    await tester.tap(find.byKey(const Key('thread-management-rename-save')));
    final updatedDetailTitle = find.descendant(
      of: find.byKey(const Key('thread-management-detail-screen')),
      matching: find.text('Updated design'),
    );
    await _pumpUntil(tester, () => updatedDetailTitle.evaluate().isNotEmpty);
    await _pumpUntil(tester, () {
      return tester
          .widget<ListTile>(find.byKey(const Key('thread-management-rename')))
          .enabled;
    });

    await tester.tap(find.byKey(const Key('thread-management-notification-3')));
    await _pumpUntil(tester, () async {
      final cached = await threads.get(
        accountId: _accountId,
        roomToken: _roomToken,
        threadId: 120,
      );
      return cached?.notificationLevel == 3;
    });
    await _pumpUntil(tester, () {
      return tester
          .widget<ListTile>(find.byKey(const Key('thread-management-rename')))
          .enabled;
    });

    expect(mutationCount, 2);
    expect(updatedDetailTitle, findsOneWidget);
    await disposeHarness(tester);
  });

  testWidgets('detail allows only one server operation at a time', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    var detailRequests = 0;
    var renameRequests = 0;
    final delayedDetail = Completer<http.Response>();
    final delayedRename = Completer<http.Response>();
    addTearDown(() {
      if (!delayedDetail.isCompleted) {
        delayedDetail.complete(_fixtureResponse('thread-detail-success'));
      }
      if (!delayedRename.isCompleted) {
        delayedRename.complete(_fixtureResponse('thread-rename-success'));
      }
    });
    await openDetail(
      tester,
      handler: (request) {
        if (request.url.path.endsWith('/threads/recent')) {
          return _fixtureResponse('recent-threads-success');
        }
        if (request.method == 'PUT') {
          renameRequests++;
          return delayedRename.future;
        }
        detailRequests++;
        return detailRequests == 1
            ? _fixtureResponse('thread-detail-success')
            : delayedDetail.future;
      },
    );

    tester
        .widget<IconButton>(
          find.byKey(const Key('thread-management-detail-refresh')),
        )
        .onPressed!();
    await tester.pump();
    await _pumpUntil(tester, () => detailRequests == 2);
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('thread-management-rename')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('thread-management-open-thread')),
          )
          .onPressed,
      isNull,
    );

    delayedDetail.complete(_fixtureResponse('thread-detail-success'));
    await _pumpUntil(tester, () {
      return tester
          .widget<ListTile>(find.byKey(const Key('thread-management-rename')))
          .enabled;
    });
    await tester.tap(find.byKey(const Key('thread-management-rename')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('thread-management-rename-field')),
      'Serialized title',
    );
    await tester.tap(find.byKey(const Key('thread-management-rename-save')));
    await _pumpUntil(tester, () => renameRequests == 1);

    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('thread-management-detail-refresh')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('thread-management-open-thread')),
          )
          .onPressed,
      isNull,
    );

    delayedRename.complete(_fixtureResponse('thread-rename-success'));
    await _pumpUntil(
      tester,
      () => find.text('Updated design').evaluate().isNotEmpty,
    );
    expect(detailRequests, 3);
    expect(renameRequests, 1);
    await disposeHarness(tester);
  });

  testWidgets('ambiguous rename is shown once without automatic replay', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    var puts = 0;
    await openDetail(
      tester,
      handler: (request) {
        if (request.url.path.endsWith('/threads/recent')) {
          return _fixtureResponse('recent-threads-success');
        }
        if (request.method == 'PUT') {
          puts++;
          return _ocsResponse(statusCode: 503, data: const {});
        }
        return _fixtureResponse('thread-detail-success');
      },
    );

    await tester.tap(find.byKey(const Key('thread-management-rename')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('thread-management-rename-field')),
      'Uncertain title',
    );
    await tester.tap(find.byKey(const Key('thread-management-rename-save')));
    await _pumpUntil(
      tester,
      () => find.textContaining('may have applied').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(seconds: 1));

    expect(puts, 1);
    expect(find.text('Design'), findsOneWidget);
    await disposeHarness(tester);
  });

  testWidgets('rename survives an open IME composing region', (tester) async {
    await _setLargeSurface(tester);
    var puts = 0;
    await openDetail(
      tester,
      handler: (request) {
        if (request.url.path.endsWith('/threads/recent')) {
          return _fixtureResponse('recent-threads-success');
        }
        if (request.method == 'PUT') {
          puts++;
          return _fixtureResponse('thread-rename-success');
        }
        return _fixtureResponse('thread-detail-success');
      },
    );

    await tester.tap(find.byKey(const Key('thread-management-rename')));
    await tester.pump();
    await tester.showKeyboard(
      find.byKey(const Key('thread-management-rename-field')),
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Updated design',
        selection: TextSelection.collapsed(offset: 14),
        composing: TextRange(start: 8, end: 14),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('thread-management-rename-save')));
    await _pumpUntil(tester, () => puts == 1);
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(puts, 1);
    await disposeHarness(tester);
  });

  testWidgets('open action routes through validated canonical thread root', (
    tester,
  ) async {
    await _setLargeSurface(tester);
    await openDetail(tester, handler: _successfulHandler);

    await tester.tap(find.byKey(const Key('thread-management-open-thread')));
    await _pumpUntil(
      tester,
      () => find.byType(ChatThreadScreen).evaluate().isNotEmpty,
    );

    final route = tester.widget<ChatThreadScreen>(
      find.byType(ChatThreadScreen),
    );
    expect(route.threadContext.rootMessageId, 120);
    expect(route.threadContext.roomToken, _roomToken);
    expect(route.threadContext.accountId, _accountId);

    Navigator.of(tester.element(find.byType(ChatThreadScreen))).pop();
    await tester.pump();
    await disposeHarness(tester);
  });
}

Future<void> _setLargeSurface(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 1600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  FutureOr<bool> Function() condition,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (await condition()) {
      return;
    }
  }
  fail('Condition was not reached before the test deadline.');
}

Future<http.Response> _successfulHandler(http.Request request) async {
  if (request.url.path.endsWith('/threads/recent')) {
    return _fixtureResponse('recent-threads-success');
  }
  if (request.url.path.contains('/threads/')) {
    return _fixtureResponse('thread-detail-success');
  }
  return _ocsResponse(statusCode: 404, data: const {});
}

Future<void> _insertRoom(AppDatabase database) {
  final raw = _roomJson();
  final room = ConversationRoom.fromJson(raw);
  return database
      .into(database.cachedConversations)
      .insertOnConflictUpdate(
        CachedConversationsCompanion.insert(
          accountId: _accountId,
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
          rawJson: jsonEncode(raw),
        ),
      );
}

Map<String, Object?> _roomJson() {
  final response =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
  room
    ..['token'] = _roomToken
    ..['participantType'] = 3
    ..['permissions'] = 128
    ..['readOnly'] = 0
    ..['lobbyState'] = 0
    ..remove('remoteServer');
  return room;
}

RichChatThread _thread({
  required int id,
  required String title,
  required String roomToken,
}) {
  return RichChatThread.fromJson(
    _threadWire(id: id, title: title, roomToken: roomToken),
  );
}

Map<String, Object?> _threadWire({
  required int id,
  required String title,
  required String roomToken,
}) {
  return <String, Object?>{
    'thread': <String, Object?>{
      'id': id,
      'roomToken': roomToken,
      'title': title,
      'lastMessageId': id,
      'lastActivity': 1787443000 + id,
      'numReplies': 0,
    },
    'attendee': const <String, Object?>{'notificationLevel': 1},
    'first': null,
    'last': null,
  };
}

http.Response _fixtureResponse(String id) {
  final manifest =
      readFixtureJson('rich-chat/fixtures/responses.cases.json')!
          as Map<String, Object?>;
  final cases = manifest['cases']! as List<Object?>;
  final item = cases.cast<Map<String, Object?>>().singleWhere(
    (candidate) => candidate['id'] == id,
  );
  final body = jsonDecode(jsonEncode(item['body'])) as Map<String, Object?>;
  final meta =
      (body['ocs']! as Map<String, Object?>)['meta']! as Map<String, Object?>;
  return _jsonResponse(body, meta['statuscode']! as int);
}

http.Response _ocsResponse({required int statusCode, required Object? data}) {
  final success = statusCode >= 200 && statusCode < 300;
  return _jsonResponse(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': success ? 'ok' : 'failure',
        'statuscode': statusCode,
        'message': success ? 'OK' : 'Failure',
      },
      'data': data,
    },
  }, statusCode);
}

http.Response _jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}
