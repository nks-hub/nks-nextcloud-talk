import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/call_session_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late CallLifecycleSessionRepository sessions;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    sessions = CallLifecycleSessionRepository(database);
    await _insertAccount(accounts, 'account-a');
    await _insertAccount(accounts, 'account-b');
  });

  tearDown(() => database.close());

  test('persists confirmed flags and a pending mutation atomically', () async {
    final joined = _joining(
      _authority(),
    ).confirm(updatedAt: DateTime.utc(2026, 8, 26, 1));
    final updating = joined.beginUpdate(
      flags: CallInCallFlags.parse(3, requireJoined: true),
      updatedAt: DateTime.utc(2026, 8, 26, 2),
    );

    await sessions.persist(updating);
    final restored = await sessions.load(authority: _authority());

    expect(restored?.phase, CallLifecyclePhase.updating);
    expect(restored?.confirmedFlags?.value, 7);
    expect(restored?.requestedFlags?.value, 3);
    expect(restored?.mutationSequence, 2);
  });

  test('restart turns a durable in-flight mutation uncertain', () async {
    await sessions.persist(_joining(_authority()));

    final restored = await sessions.load(
      authority: _authority(),
      afterRestart: true,
      now: DateTime.utc(2026, 8, 27),
    );
    final stored = await database.select(database.callLifecycleSessions).get();

    expect(restored?.phase, CallLifecyclePhase.uncertainJoin);
    expect(stored.single.phase, CallLifecyclePhase.uncertainJoin.name);
  });

  test('authority drift purges stale state fail closed', () async {
    final mutations = <String>[
      "server_url = 'https://other.example.invalid'",
      "nextcloud_session_id = 'other-session'",
      'credential_generation = 2',
      'capability_generation = 2',
      "capability_revision = 'other-revision'",
    ];
    for (final mutation in mutations) {
      await sessions.persist(_joining(_authority()));
      await database.customStatement(
        'UPDATE call_lifecycle_sessions SET $mutation',
      );

      expect(
        await sessions.load(authority: _authority()),
        isNull,
        reason: mutation,
      );
      expect(
        await database.select(database.callLifecycleSessions).get(),
        isEmpty,
      );
    }
  });

  test('malformed phase and flag shape are deleted', () async {
    await sessions.persist(_joining(_authority()));
    await database.customStatement(
      "UPDATE call_lifecycle_sessions SET phase = 'joined'",
    );

    expect(await sessions.load(authority: _authority()), isNull);
    expect(
      await database.select(database.callLifecycleSessions).get(),
      isEmpty,
    );
  });

  test('two accounts and rooms never overwrite each other', () async {
    final authorityA = _authority();
    final authorityB = _authority(
      accountId: 'account-b',
      roomToken: 'roomb123',
      server: 'https://account-b.example.invalid',
      sessionId: 'session-b',
    );
    await sessions.persist(_joining(authorityA));
    await sessions.persist(_joining(authorityB));

    expect(await sessions.load(authority: authorityA), isNotNull);
    expect(await sessions.load(authority: authorityB), isNotNull);
    expect(
      await database.select(database.callLifecycleSessions).get(),
      hasLength(2),
    );
  });

  test(
    'durable table cannot contain credentials, peers or media state',
    () async {
      await sessions.persist(_joining(_authority()));
      final columns = await database
          .customSelect('PRAGMA table_info(call_lifecycle_sessions)')
          .get();
      final names = columns.map((row) => row.read<String>('name')).toSet();

      expect(
        names.intersection(const <String>{
          'app_password',
          'authorization',
          'ticket',
          'hpb_token',
          'peers',
          'participants',
          'media',
        }),
        isEmpty,
      );
    },
  );

  test('account purge removes lifecycle state with foreign keys off', () async {
    await sessions.persist(_joining(_authority()));
    await database.customStatement('PRAGMA foreign_keys = OFF');

    await accounts.purgeAccount('account-a');

    expect(
      await database.select(database.callLifecycleSessions).get(),
      isEmpty,
    );
  });
}

Future<void> _insertAccount(AccountRepository accounts, String accountId) =>
    accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://$accountId.example.invalid',
      loginName: '$accountId-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 8, 26),
    );

CallLifecycleState _joining(CallLifecycleAuthority authority) =>
    CallLifecycleState.beginJoin(
      authority: authority,
      flags: CallInCallFlags.audioVideo(),
      updatedAt: DateTime.utc(2026, 8, 26),
    );

CallLifecycleAuthority _authority({
  String accountId = 'account-a',
  String roomToken = 'rooma123',
  String server = 'https://account-a.example.invalid',
  String sessionId = 'session-a',
}) => CallLifecycleAuthority(
  accountId: AccountId.parse(accountId),
  server: ServerBase.parse(server),
  roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
  nextcloudSessionId: ConversationSessionId.parse(sessionId),
  credentialGeneration: 1,
  capabilityGeneration: 1,
  capabilityRevision: 'call-v4:1:1:1:2',
);
