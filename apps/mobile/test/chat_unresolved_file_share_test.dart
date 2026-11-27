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
import 'package:nextcloudtalk/features/chat/unresolved_file_share_refresh.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// A file share the server could not yet resolve for this reader arrives as
/// its "shared a file which is no longer available" stand-in. The cursors
/// never read that id again, so the room re-reads it when it shows it.
void main() {
  late AppDatabase database;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;
  Future<void>? databaseClosing;

  Future<void> closeDatabase() => databaseClosing ??= database.close();

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    var closed = false;
    final closing = closeDatabase().whenComplete(() => closed = true);
    closing.ignore();
    // Drift can still be draining callbacks scheduled on the widget clock.
    await pumpUntilCondition(
      tester,
      () => closed,
      reason: 'the chat database did not close after unmounting',
    );
    await closing;
  }

  setUp(() async {
    database = openTestDatabase();
    databaseClosing = null;
    vault = MemoryCredentialVault();
    account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    vault.values[account.id] = 'fixture-app-password-never-use';
    conversation = await _cacheConversation(database, account.id, 'rooma123');
  });

  tearDown(() async {
    if (databaseClosing == null) await closeDatabase();
  });

  testWidgets('re-reads an unresolved file share and shows the file', (
    tester,
  ) async {
    await _insertMessage(database, _standIn(659));
    await _insertScope(database, from: 659, to: 659);
    final reads = <int>[];
    final api = _server(
      reread: (id) async {
        reads.add(id);
        return _resolved(id);
      },
    );
    addTearDown(api.close);

    try {
      await tester.pumpWidget(
        _app(database, vault, api, account, conversation),
      );
      await pumpUntilCondition(
        tester,
        () => _opensFile(659),
        reason: 'the stale share was never replaced by the resolved copy',
        timeout: const Duration(seconds: 10),
      );
      final row = await _row(database, 659);
      final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
      expect(stored.messageParameters['file']?.name, 'report.pdf');
      expect(reads, [659], reason: 'one re-read per shown message');
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('leaves resolved shares alone', (tester) async {
    await _insertMessage(database, _resolved(659));
    await _insertScope(database, from: 659, to: 659);
    final reads = <int>[];
    var polled = false;
    final api = _server(
      future: (_) async {
        polled = true;
        return null;
      },
      reread: (id) async {
        reads.add(id);
        return _resolved(id);
      },
    );
    addTearDown(api.close);

    try {
      await tester.pumpWidget(
        _app(database, vault, api, account, conversation),
      );
      await pumpUntilCondition(tester, () => polled && _opensFile(659));
      await tester.pump(const Duration(seconds: 1));
      expect(reads, isEmpty);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('tries a live arrival again while the race lasts', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _insertMessage(database, _plain(658, timestamp: now - 60));
    await _insertScope(database, from: 658, to: 658);
    final reads = <int>[];
    final api = _server(
      future: (after) async =>
          after == 658 ? [_standIn(659, timestamp: now)] : null,
      // The first re-read still meets the race the poll met.
      reread: (id) async {
        reads.add(id);
        return reads.length == 1
            ? _standIn(id, timestamp: now)
            : _resolved(id, timestamp: now);
      },
    );
    addTearDown(api.close);

    try {
      await tester.pumpWidget(
        _app(database, vault, api, account, conversation),
      );
      await pumpUntilCondition(tester, () => reads.isNotEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(_opensFile(659), isFalse);
      await pumpUntilCondition(
        tester,
        () => _opensFile(659),
        reason: 'the share was not tried again',
        frame: const Duration(milliseconds: 500),
      );
      expect(reads, [659, 659]);
    } finally {
      await unmount(tester);
    }
  });

  // The pane resets this on every room, thread or account switch and on
  // disposal. Driven directly: a pane switched while a re-read is on the
  // wire leaves the test database unable to close, before this change too.
  test('a reset stops the re-reads of the room left behind', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _insertMessage(database, _standIn(659, timestamp: now));
    await _insertMessage(database, _standIn(660, timestamp: now));
    final rows = [await _row(database, 659), await _row(database, 660)];
    final refresh = UnresolvedFileShareRefresh(
      retryDelays: const [Duration(milliseconds: 20)],
    );
    final gate = Completer<void>();
    final reads = <int>[];
    refresh.observe(rows, (id) async {
      reads.add(id);
      await gate.future;
      return _row(database, id);
    });
    await pumpEventQueue();
    expect(reads, [659]);

    refresh.reset();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(reads, [659], reason: 'neither 660 nor a retry of 659 may follow');
  });

  test('a reset cancels a pending retry', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _insertMessage(database, _standIn(659, timestamp: now));
    final refresh = UnresolvedFileShareRefresh(
      retryDelays: const [Duration(milliseconds: 20)],
    );
    final reads = <int>[];
    refresh.observe([await _row(database, 659)], (id) async {
      reads.add(id);
      return _row(database, id);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(reads, [659, 659], reason: 'a young stand-in is tried again');

    final again = UnresolvedFileShareRefresh(
      retryDelays: const [Duration(milliseconds: 20)],
    );
    final later = <int>[];
    again.observe([await _row(database, 659)], (id) async {
      later.add(id);
      return _row(database, id);
    });
    await pumpEventQueue();
    again.reset();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(later, [659]);
  });
}

bool _opensFile(int id) =>
    find.byKey(Key('chat-attachment-open-action-$id-0')).evaluate().isNotEmpty;

/// What Talk renders for a `file_shared` message whose share it cannot
/// resolve for the reader: a comment that keeps `{actor}` and drops `{file}`.
Map<String, Object?> _standIn(int id, {int timestamp = 1724300000}) =>
    _messageJson(
      id: id,
      timestamp: timestamp,
      message: '*{actor} shared a file which is no longer available*',
      parameters: {'actor': _actor},
    );

Map<String, Object?> _resolved(int id, {int timestamp = 1724300000}) =>
    _messageJson(
      id: id,
      timestamp: timestamp,
      message: '{file}',
      parameters: {
        'actor': _actor,
        'file': <String, Object?>{
          'type': 'file',
          'id': '1693',
          'name': 'report.pdf',
          'size': 2048,
          'path': 'Talk/report.pdf',
          'link': 'https://cloud.example.invalid/f/1693',
          'mimetype': 'application/pdf',
          'preview-available': 'no',
        },
      },
    );

Map<String, Object?> _plain(int id, {required int timestamp}) => _messageJson(
  id: id,
  timestamp: timestamp,
  message: 'Plain message',
  parameters: const {},
);

const _actor = <String, Object?>{
  'type': 'user',
  'id': 'someone-else',
  'name': 'Other person',
};

Map<String, Object?> _messageJson({
  required int id,
  required int timestamp,
  required String message,
  required Map<String, Object?> parameters,
}) => <String, Object?>{
  'id': id,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'someone-else',
  'actorDisplayName': 'Other person',
  'timestamp': timestamp,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-$id',
  'message': message,
  'messageParameters': parameters,
  'markdown': true,
  'reactions': <String, Object?>{},
};

/// Room A's server. [reread] answers the single-message read of an id,
/// [future] the poll after a cursor (null: nothing new); every other chat
/// read is a 304.
HttpNextcloudApi _server({
  required Future<Map<String, Object?>> Function(int id) reread,
  Future<List<Map<String, Object?>>?> Function(int after)? future,
}) {
  return HttpNextcloudApi(
    client: MockClient((request) async {
      final url = request.url;
      if (url.path.endsWith('/cloud/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: <String>[
                'conversation-v4',
                'chat-v2',
                'chat-reference-id',
              ],
            ),
          ),
          200,
        );
      }
      if (url.path.contains('/avatar/')) {
        return http.Response('', 404);
      }
      final query = url.queryParameters;
      final cursor = int.tryParse(query['lastKnownMessageId'] ?? '');
      if (!url.path.endsWith('/chat/rooma123') || cursor == null) {
        return http.Response('', 304);
      }
      List<Map<String, Object?>>? messages;
      if (query['lookIntoFuture'] == '0' &&
          query['includeLastKnown'] == '1' &&
          query['limit'] == '1') {
        messages = [await reread(cursor)];
      } else if (query['lookIntoFuture'] == '1') {
        messages = await future?.call(cursor);
      }
      if (messages == null) {
        return http.Response('', 304);
      }
      return http.Response(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{'status': 'ok', 'statuscode': 200},
            'data': messages,
          },
        }),
        200,
        headers: {'X-Chat-Last-Given': '${messages.last['id']}'},
      );
    }),
  );
}

Widget _app(
  AppDatabase database,
  MemoryCredentialVault vault,
  HttpNextcloudApi api,
  StoredAccount account,
  CachedConversation conversation,
) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(vault),
      nextcloudApiProvider.overrideWithValue(api),
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment dependencies are not wired in this suite'),
          StackTrace.empty,
        ),
      ),
    ],
    child: localizedTestApp(
      home: PresenceChatRoomScreen(
        account: account,
        conversation: conversation,
      ),
    ),
  );
}

Future<CachedConversation> _cacheConversation(
  AppDatabase database,
  String accountId,
  String token,
) async {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final rooms = (root['ocs']! as Map<String, Object?>)['data']! as List;
  final roomJson = Map<String, Object?>.from(rooms.first! as Map);
  roomJson['token'] = token;
  roomJson['lastMessage'] = {
    ...(roomJson['lastMessage']! as Map<String, Object?>),
    'token': token,
  };
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
          rawJson: jsonEncode(roomJson),
        ),
      );
  return (database.select(
    database.cachedConversations,
  )..where((row) => row.token.equals(token))).getSingle();
}

Future<CachedChatMessage> _row(AppDatabase database, int id) =>
    (database.select(
      database.cachedChatMessages,
    )..where((row) => row.messageId.equals(id))).getSingle();

Future<void> _insertMessage(AppDatabase database, Map<String, Object?> wire) {
  final message = ChatMessage.fromJson(wire);
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: message.messageId,
          actorType: message.actorType,
          actorId: message.actorId,
          actorDisplayName: message.actorDisplayName,
          timestamp: message.timestamp,
          systemMessage: message.systemMessage,
          messageType: message.messageType,
          referenceId: message.referenceId,
          displayText: 'Other person shared a file',
          deleted: false,
          rawJson: jsonEncode(message.wire),
        ),
      );
}

Future<void> _insertScope(
  AppDatabase database, {
  required int from,
  required int to,
}) {
  return database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          scopeKey: 'root',
          historyCursor: '$from',
          futureCursor: '$to',
          lastCommonRead: '$to',
          lastReadMessage: to,
          unreadMessages: 0,
          hasHistory: false,
          futureConverged: false,
          blocksJson: '[["$from","$to"]]',
          lastSyncedAtMillis: const Value(1724300000000),
        ),
      );
}
