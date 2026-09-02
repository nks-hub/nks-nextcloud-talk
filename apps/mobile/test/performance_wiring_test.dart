import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/core/performance_telemetry.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/features/conversations/conversation_sync_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// The measurement is only worth anything if it is attached to the work.
///
/// The layer and its privacy rules already have their own suite; this one
/// answers the question that suite cannot — does anything actually call it.
/// A build where the wiring is dropped would keep every one of those tests
/// green while reporting nothing at all.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late MemoryCredentialVault credentials;
  late List<TracedSpan> reported;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    credentials = MemoryCredentialVault()
      ..values['account-a'] = 'fixture-app-password-never-use';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    reported = <TracedSpan>[];
    addTearDown(installPerformanceTelemetry(reported.add));
  });

  tearDown(() => database.close());

  test(
    'a conversation sync is measured, and its failure is an outcome',
    () async {
      var calls = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          return http.Response('', 503);
        }),
      );
      addTearDown(api.close);
      final service = ConversationSyncService(
        accounts: accounts,
        credentials: credentials,
        api: api,
      );

      await expectLater(
        service.sync('account-a'),
        throwsA(isA<ConversationSyncException>()),
      );

      expect(calls, greaterThan(0));
      final span = reported.singleWhere(
        (span) => span.operation == TracedOperation.conversationSync,
      );
      expect(span.outcome, TracedOutcome.failed);
      expect(span.tags.values, isNot(contains(contains('cloud.example'))));
    },
  );

  test('opening a room is measured once, not once per joined caller', () async {
    await _insertRoom(database);
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
                ],
              ),
            ),
            200,
          );
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    final first = service.syncRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    // Joins the flight already in progress instead of starting its own.
    final joined = service.syncRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await Future.wait<void>([first, joined]);

    expect(
      reported.where((span) => span.operation == TracedOperation.roomOpen),
      hasLength(1),
      reason: 'a joined caller must not report a second span',
    );
  });
}

Future<void> _insertRoom(AppDatabase database) async {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final roomJson = Map<String, Object?>.from(
    rooms.first! as Map<String, Object?>,
  );
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: 'account-a',
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
}
