import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';

/// Pins how much disk one cached chat message costs.
///
/// `cached_chat_messages` is the only chat table that grows without a bound:
/// every received message is cached, and nothing ever evicts one. Whether that
/// needs an eviction policy depends entirely on the per-row cost, so this
/// measures it against a real on-disk database rather than estimating.
///
/// Measured on the reference server's live cache at 1199 B/row (123 rows,
/// `dbstat` including the primary-key index), of which ~714 B is the message
/// JSON itself. A regression here means a new column, not a new policy.
void main() {
  test('disk cost of one cached chat message', () async {
    final directory = await Directory.systemTemp.createTemp('chat-cache-');
    final file = File('${directory.path}${Platform.pathSeparator}cache.sqlite');
    final database = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });

    final account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: 'rooma123',
            displayName: 'Synthetic room',
            description: '',
            lastActivity: 1724300000,
            unreadMessages: 0,
            favorite: false,
            readOnly: const Value(0),
            roomType: const Value(2),
            roomName: const Value('synthetic'),
            objectType: const Value(''),
            avatarVersion: const Value(''),
            isCustomAvatar: const Value(false),
            rawJson: '{}',
          ),
        );
    await database.customStatement('vacuum');
    final empty = file.lengthSync();

    const rows = 20000;
    await database.batch((batch) {
      for (var index = 0; index < rows; index++) {
        final messageId = 100 + index;
        // Sized to the reference server's real messages: 714 B of JSON on
        // average, so the measured per-row cost is comparable.
        final body =
            'Synthetic history message number $index. '
            '${'Talk messages carry rich object strings and markdown. ' * 8}';
        final wire = <String, Object?>{
          'id': messageId,
          'token': 'rooma123',
          'actorType': 'users',
          'actorId': 'author-${index % 4}',
          'actorDisplayName': 'Author ${index % 4}',
          'timestamp': 1724300000 + (index * 60),
          'systemMessage': '',
          'messageType': 'comment',
          'isReplyable': true,
          'referenceId': 'reference-$messageId',
          'message': body,
          'messageParameters': const <String, Object?>{},
          'markdown': false,
          'reactions': const <String, Object?>{},
          'reactionsSelf': const <Object?>[],
          'deleted': null,
          'threadId': null,
          'isThread': false,
          'threadTitle': null,
          'threadReplies': 0,
        };
        batch.insert(
          database.cachedChatMessages,
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: 'rooma123',
            messageId: messageId,
            actorType: 'users',
            actorId: wire['actorId']! as String,
            actorDisplayName: wire['actorDisplayName']! as String,
            timestamp: wire['timestamp']! as int,
            systemMessage: '',
            messageType: 'comment',
            referenceId: wire['referenceId']! as String,
            displayText: body,
            deleted: false,
            rawJson: jsonEncode(wire),
          ),
        );
      }
    });
    await database.customStatement('vacuum');
    final filled = file.lengthSync();
    final perRow = (filled - empty) / rows;
    final jsonBytes =
        await database
            .customSelect('select sum(length(raw_json)) c from cached_chat_messages')
            .map((row) => row.read<int>('c'))
            .getSingle() /
        rows;

    // ignore: avoid_print
    print(
      'CACHE rows=$rows total=${((filled - empty) / (1024 * 1024)).toStringAsFixed(1)}MB '
      'per_row=${perRow.toStringAsFixed(0)}B json_per_row=${jsonBytes.toStringAsFixed(0)}B '
      'overhead=${(perRow - jsonBytes).toStringAsFixed(0)}B',
    );

    // A cached message is mostly its own JSON, so there is no waste to reclaim
    // and eviction would be deleting user history, not slack. If a new column
    // pushes the overhead well past the payload, revisit that conclusion.
    expect(
      perRow,
      lessThan(3 * jsonBytes),
      reason: 'a cached message must stay dominated by its own payload',
    );
  });
}
