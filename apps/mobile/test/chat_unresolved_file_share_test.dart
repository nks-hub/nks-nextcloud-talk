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
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// A file share the server could not yet resolve for this reader arrives as
/// its "shared a file which is no longer available" stand-in. The cursors
/// never read that id again, so the room re-reads it once when it shows it.
void main() {
  late AppDatabase database;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;

  setUp(() async {
    database = openTestDatabase();
    vault = MemoryCredentialVault();
    account = await AccountRepository(database).upsertAccount(
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
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
  });

  tearDown(() => database.close());

  testWidgets('re-reads an unresolved file share and shows the file', (
    tester,
  ) async {
    await _insertMessage(database, account.id, _unresolvedShare);
    await _insertScope(database, account.id);
    final reads = <Uri>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final capabilities = _capabilitiesResponse(request);
        if (capabilities != null) {
          return capabilities;
        }
        final query = request.url.queryParameters;
        if (query['lookIntoFuture'] == '0' &&
            query['lastKnownMessageId'] == '$_shareId' &&
            query['includeLastKnown'] == '1') {
          reads.add(request.url);
          return http.Response(
            jsonEncode(_ocs([_resolvedShare])),
            200,
            headers: const {'X-Chat-Last-Given': '$_shareId'},
          );
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(_app(database, vault, api, account, conversation));
    try {
      const openAction = Key('chat-attachment-open-action-$_shareId-0');
      await pumpUntilCondition(
        tester,
        () => find.byKey(openAction).evaluate().isNotEmpty,
        reason: 'the stale share was never replaced by the resolved copy',
        timeout: const Duration(seconds: 10),
      );

      final row = await (database.select(
        database.cachedChatMessages,
      )..where((row) => row.messageId.equals(_shareId))).getSingle();
      final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
      expect(stored.messageParameters['file']?.name, 'report.pdf');
      expect(find.textContaining('no longer available'), findsNothing);
      expect(reads, hasLength(1), reason: 'one re-read per shown message');
    } finally {
      await _unmount(tester);
    }
  });

  testWidgets('leaves resolved shares alone', (tester) async {
    await _insertMessage(database, account.id, _resolvedShare);
    await _insertScope(database, account.id);
    final reads = <Uri>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final capabilities = _capabilitiesResponse(request);
        if (capabilities != null) {
          return capabilities;
        }
        if (request.url.queryParameters['includeLastKnown'] == '1') {
          reads.add(request.url);
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(_app(database, vault, api, account, conversation));
    try {
      await pumpUntilCondition(
        tester,
        () => find
            .byKey(const Key('chat-attachment-open-action-$_shareId-0'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(reads, isEmpty);
    } finally {
      await _unmount(tester);
    }
  });
}

const _shareId = 659;

/// What Talk renders for a `file_shared` message whose share it cannot
/// resolve for the reader: a comment that keeps `{actor}` and drops `{file}`.
final _unresolvedShare = _messageJson(
  message: '*{actor} shared a file which is no longer available*',
  parameters: {'actor': _actor},
);

final _resolvedShare = _messageJson(
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

const _actor = <String, Object?>{
  'type': 'user',
  'id': 'someone-else',
  'name': 'Other person',
};

Map<String, Object?> _messageJson({
  required String message,
  required Map<String, Object?> parameters,
}) => <String, Object?>{
  'id': _shareId,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'someone-else',
  'actorDisplayName': 'Other person',
  'timestamp': 1724300000,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-$_shareId',
  'message': message,
  'messageParameters': parameters,
  'markdown': true,
  'reactions': <String, Object?>{},
};

Map<String, Object?> _ocs(List<Object?> data) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{'status': 'ok', 'statuscode': 200},
    'data': data,
  },
};

/// Unmounts the pane even when an expectation failed, so its draft flush
/// and query streams finish before the next test closes the database.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
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

http.Response? _capabilitiesResponse(http.Request request) {
  if (request.url.path.endsWith('/cloud/capabilities')) {
    return http.Response(
      jsonEncode(
        capabilitiesJson(
          talkFeatures: const <String>[
            'conversation-v4',
            'chat-v2',
            'chat-reference-id',
          ],
        ),
      ),
      200,
    );
  }
  if (request.url.path.contains('/avatar/')) {
    return http.Response('', 404);
  }
  return null;
}

Map<String, Object?> _conversationRoomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Future<void> _insertMessage(
  AppDatabase database,
  String accountId,
  Map<String, Object?> wire,
) {
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: 'rooma123',
          messageId: _shareId,
          actorType: 'users',
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: 1724300000,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-$_shareId',
          displayText: 'Other person shared a file',
          deleted: false,
          rawJson: jsonEncode(wire),
        ),
      );
}

Future<void> _insertScope(AppDatabase database, String accountId) {
  return database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: accountId,
          roomToken: 'rooma123',
          scopeKey: 'root',
          historyCursor: '$_shareId',
          futureCursor: '$_shareId',
          lastCommonRead: '$_shareId',
          lastReadMessage: _shareId,
          unreadMessages: 0,
          hasHistory: false,
          futureConverged: false,
          blocksJson: '[["$_shareId","$_shareId"]]',
          lastSyncedAtMillis: const Value(1724300000000),
        ),
      );
}
