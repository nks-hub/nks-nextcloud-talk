import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/call_session_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late CallSessionRepository sessions;

  setUp(() {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    sessions = CallSessionRepository(database);
  });

  tearDown(() => database.close());

  test(
    'restart recovery bumps epochs and clears every transient value',
    () async {
      await _insertAccount(accounts, 'account-a');
      final state =
          _state(
            accountId: 'account-a',
            roomToken: 'rooma123',
            connectionEpoch: 7,
            roomEpoch: 4,
          ).copyWith(
            settings: ExternalSignalingSettings(
              userId: 'secret-user',
              sipDialinInfo: 'secret-dial-in-info',
              stunServers: const <IceServerConfiguration>[],
              turnServers: const <IceServerConfiguration>[],
              federation: null,
              endpoint: HpbEndpoint.parse('https://hpb.example.invalid'),
              v1Authentication: HpbV1Authentication(
                userId: 'secret-user',
                ticket: 'secret-ticket',
              ),
              v2Authentication: HpbV2Authentication(token: 'secret-token'),
            ),
            participants: <SignalingPeerId, SignalingParticipant>{
              SignalingPeerId.parse('secret-peer'): _participant('secret-peer'),
            },
            roomConfirmed: true,
            renegotiationRequired: false,
          );

      await sessions.persist(state, updatedAt: DateTime.utc(2026, 8, 26));
      final snapshot = await sessions.recover(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final recovered = snapshot!.accounts[AccountId.parse('account-a')]!;

      expect(recovered.phase, SignalingAccountPhase.idle);
      expect(recovered.connectionEpoch, 8);
      expect(recovered.roomEpoch, 5);
      expect(recovered.renegotiationRequired, isTrue);
      expect(recovered.settings, isNull);
      expect(recovered.participants, isEmpty);
      expect(recovered.roomConfirmed, isFalse);
      expect(recovered.hpbSessionId, isNull);
      expect(recovered.hpbResumeId, isNull);
      expect(recovered.pendingHpbFrame, isNull);
    },
  );

  test('durable table has no secret columns or transient values', () async {
    await _insertAccount(accounts, 'account-a');
    final state = _state(accountId: 'account-a', roomToken: 'rooma123')
        .copyWith(
          settings: ExternalSignalingSettings(
            userId: 'secret-user',
            sipDialinInfo: 'secret-dial-in-info',
            stunServers: const <IceServerConfiguration>[],
            turnServers: const <IceServerConfiguration>[],
            federation: null,
            endpoint: HpbEndpoint.parse('https://hpb.example.invalid'),
            v1Authentication: HpbV1Authentication(
              userId: 'secret-user',
              ticket: 'secret-ticket',
            ),
            v2Authentication: HpbV2Authentication(token: 'secret-token'),
          ),
          participants: <SignalingPeerId, SignalingParticipant>{
            SignalingPeerId.parse('secret-peer'): _participant('secret-peer'),
          },
        );

    await sessions.persist(state);
    final columns = await database
        .customSelect('PRAGMA table_info(call_sessions)')
        .get();
    final names = columns.map((row) => row.read<String>('name')).toSet();
    final stored = await database
        .customSelect('SELECT * FROM call_sessions')
        .getSingle();
    final encodedValues = stored.data.values.join('|');

    expect(
      names.intersection(const <String>{
        'settings',
        'ticket',
        'token',
        'resume_id',
        'participants',
        'pending_frame',
      }),
      isEmpty,
    );
    expect(encodedValues, isNot(contains('secret-ticket')));
    expect(encodedValues, isNot(contains('secret-token')));
    expect(encodedValues, isNot(contains('secret-dial-in-info')));
    expect(encodedValues, isNot(contains('secret-peer')));
  });

  test(
    'rooms are account-scoped and replacement only affects its account',
    () async {
      await _insertAccount(accounts, 'account-a');
      await _insertAccount(accounts, 'account-b');
      await sessions.persist(
        _state(accountId: 'account-a', roomToken: 'rooma123'),
      );
      await sessions.persist(
        _state(accountId: 'account-b', roomToken: 'roomb123'),
      );
      await sessions.persist(
        _state(accountId: 'account-a', roomToken: 'roomc123'),
      );

      final rows = await database.select(database.callSessions).get();
      expect(
        rows.map((row) => '${row.accountId}:${row.roomToken}').toSet(),
        <String>{'account-a:roomc123', 'account-b:roomb123'},
      );
      expect(
        await sessions.recover(accountId: 'account-a', roomToken: 'rooma123'),
        isNull,
      );
      expect(
        await sessions.recover(accountId: 'account-b', roomToken: 'roomb123'),
        isNotNull,
      );
    },
  );

  test('malformed durable state is deleted fail-closed', () async {
    await _insertAccount(accounts, 'account-a');
    await sessions.persist(
      _state(accountId: 'account-a', roomToken: 'rooma123'),
    );
    await database.customStatement(
      'UPDATE call_sessions SET connection_epoch = -1',
    );

    expect(
      await sessions.recover(accountId: 'account-a', roomToken: 'rooma123'),
      isNull,
    );
    expect(await database.select(database.callSessions).get(), isEmpty);
  });

  test('malformed settings authority is deleted fail-closed', () async {
    await _insertAccount(accounts, 'account-a');
    await sessions.persist(
      _state(accountId: 'account-a', roomToken: 'rooma123'),
    );
    await database.customStatement(
      "UPDATE call_sessions SET settings_revision = 'invalid revision'",
    );

    expect(
      await sessions.recover(accountId: 'account-a', roomToken: 'rooma123'),
      isNull,
    );
    expect(await database.select(database.callSessions).get(), isEmpty);
  });

  test(
    'account purge deletes call state even with foreign keys disabled',
    () async {
      await _insertAccount(accounts, 'account-a');
      await sessions.persist(
        _state(accountId: 'account-a', roomToken: 'rooma123'),
      );
      await database.customStatement('PRAGMA foreign_keys = OFF');

      await accounts.purgeAccount('account-a');

      expect(await database.select(database.callSessions).get(), isEmpty);
      expect(await accounts.getAccount('account-a'), isNull);
    },
  );

  test('schema v10 migrates through v15 and creates call sessions', () async {
    await database.close();
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-call-session-migration-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}calls.sqlite');
    AppDatabase? migrated;
    try {
      migrated = AppDatabase.forTesting(NativeDatabase(file));
      await migrated.customSelect('SELECT 1').get();
      await AccountRepository(migrated).upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://account-a.example.invalid',
        loginName: 'account-a-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 8, 26),
      );
      await migrated.close();
      migrated = null;

      migrated = AppDatabase.forTesting(
        NativeDatabase(
          file,
          setup: (raw) {
            raw
              ..execute('DROP TABLE call_sessions')
              ..userVersion = 10;
          },
        ),
      );
      final columns = await migrated
          .customSelect('PRAGMA table_info(call_sessions)')
          .get();

      expect(migrated.schemaVersion, 16);
      expect(
        columns.map((row) => row.read<String>('name')),
        contains('room_token'),
      );
      expect(
        (await migrated.select(migrated.accounts).getSingle()).id,
        'account-a',
      );
    } finally {
      await migrated?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      database = openTestDatabase();
    }
  });
}

Future<void> _insertAccount(
  AccountRepository accounts,
  String accountId,
) async {
  await accounts.upsertAccount(
    accountId: accountId,
    serverUrl: 'https://$accountId.example.invalid',
    loginName: '$accountId-user',
    serverProductName: 'Nextcloud',
    talkFeatures: const <String>{'signaling-v3'},
    createdAt: DateTime.utc(2026, 8, 26),
  );
}

SignalingAccountState _state({
  required String accountId,
  required String roomToken,
  int connectionEpoch = 2,
  int roomEpoch = 3,
}) {
  final authority = SignalingAuthority(
    accountId: AccountId.parse(accountId),
    server: ServerBase.parse('https://$accountId.example.invalid'),
    credentialGeneration: 2,
    capabilityGeneration: 3,
    settingsRevision: 'revision-$accountId',
    profile: SignalingCapabilityProfile.fromTalkFeatures(const <String>[
      'signaling-v3',
    ]),
    roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
    nextcloudSessionId: ConversationSessionId.parse('session-$accountId'),
  );
  return SignalingAccountState.initial(
    authority: authority,
  ).copyWith(connectionEpoch: connectionEpoch, roomEpoch: roomEpoch);
}

SignalingParticipant _participant(String peerId) => SignalingParticipant(
  peerId: SignalingPeerId.parse(peerId),
  nextcloudSessionId: ConversationSessionId.parse('session-$peerId'),
  userId: 'user-$peerId',
  inCall: 1,
  permissions: 7,
  actorType: 'users',
  actorId: 'actor-$peerId',
  federated: false,
  features: const <String>['audio-video-permissions'],
);
