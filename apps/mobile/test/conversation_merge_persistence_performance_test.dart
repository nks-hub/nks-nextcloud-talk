import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository repository;
  late _ConversationWriteCounter writes;

  setUp(() async {
    writes = _ConversationWriteCounter();
    database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(writes),
    );
    repository = AccountRepository(database);
    await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  test('a full conversation merge persists room rows as one batch', () async {
    const roomCount = 40;
    final fixture =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )!
            as Map<String, Object?>;
    final ocs = fixture['ocs']! as Map<String, Object?>;
    final template = (ocs['data']! as List<Object?>).first;
    final rooms = <Object?>[
      for (var index = 0; index < roomCount; index++)
        _roomFromTemplate(template, index),
    ];
    final staleResponse = _response(
      ocs: ocs,
      requestId: 'stale-room-merge',
      rooms: <Object?>[
        for (var index = 0; index < 10; index++)
          _roomFromTemplate(template, 1000 + index),
      ],
    );
    for (final room in staleResponse.rooms) {
      await repository.applyAuthoritativeConversation('account-a', room);
    }
    final response = _response(
      ocs: ocs,
      requestId: 'batch-room-merge',
      rooms: rooms,
    );
    final accountState = ConversationAccountState(
      server: response.request.server,
      rooms: staleResponse.rooms,
    );
    final plan = const ConversationMergePlanner().plan(
      snapshot: ConversationSnapshot(
        accounts: <AccountId, ConversationAccountState>{
          response.request.accountId: accountState,
        },
      ),
      response: response,
    );
    writes.enabled = true;

    await repository.applyConversationMerge(plan);

    expect(writes.conversationBatchExecutions, 1);
    expect(writes.directConversationInserts, 0);
    expect(writes.directConversationDeletes, 1);
    expect(
      await repository.watchConversations('account-a').first,
      hasLength(roomCount),
    );
  });
}

ConversationListSuccess _response({
  required Map<String, Object?> ocs,
  required String requestId,
  required List<Object?> rooms,
}) {
  return decodeConversationListResponse(
        request: ConversationListRequest(
          accountId: AccountId.parse('account-a'),
          requestId: ConversationRequestId.parse(requestId),
          server: ServerBase.parse('https://cloud.example.invalid'),
          mode: ConversationFetchMode.full,
          includeLastMessage: true,
          includeStatus: true,
        ),
        statusCode: 200,
        json: <String, Object?>{
          'ocs': <String, Object?>{...ocs, 'data': rooms},
        },
        headers: const <String, String>{
          'X-Nextcloud-Talk-Hash': 'batch-hash',
          'X-Nextcloud-Talk-Modified-Before': '1724300001',
          'X-Nextcloud-Talk-Federation-Invites': '0',
        },
      )
      as ConversationListSuccess;
}

Map<String, Object?> _roomFromTemplate(Object? template, int index) {
  final room = jsonDecode(jsonEncode(template)) as Map<String, Object?>;
  final token = 'room${index.toString().padLeft(4, '0')}';
  room['token'] = token;
  room['displayName'] = 'Project $index';
  room['lastActivity'] = 1724300000 + index;
  (room['lastMessage']! as Map<String, Object?>)['token'] = token;
  return room;
}

final class _ConversationWriteCounter extends QueryInterceptor {
  bool enabled = false;
  int conversationBatchExecutions = 0;
  int directConversationInserts = 0;
  int directConversationDeletes = 0;

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    if (enabled &&
        statements.statements.any(
          (statement) =>
              statement.toLowerCase().contains('into "cached_conversations"'),
        )) {
      conversationBatchExecutions++;
    }
    return super.runBatched(executor, statements);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled &&
        statement.toLowerCase().contains('into "cached_conversations"')) {
      directConversationInserts++;
    }
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled &&
        statement.toLowerCase().contains('from "cached_conversations"')) {
      directConversationDeletes++;
    }
    return super.runDelete(executor, statement, args);
  }
}
