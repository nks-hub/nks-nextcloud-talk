import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:nextcloudtalk/features/settings/account_removal_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

const _serverA = 'https://cloud-a.example.invalid';
const _serverB = 'https://cloud-b.example.invalid';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late ChatMediaCache mediaCache;
  late ChatMediaDiskCache mediaDiskCache;
  late DurableAttachmentSourceStore sources;
  late FileEmojiUsageStore emojiUsage;
  late Directory root;
  late Directory previewRoot;
  late Directory voiceRoot;
  late Directory sourceRoot;
  late Directory emojiRoot;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault();
    // Never the real home directory: everything this test writes lives under
    // one temporary root that tearDown removes again.
    root = await Directory.systemTemp.createTemp('nctalk-account-removal-');
    previewRoot = Directory('${root.path}${Platform.pathSeparator}previews');
    voiceRoot = Directory('${root.path}${Platform.pathSeparator}voice');
    sourceRoot = Directory('${root.path}${Platform.pathSeparator}sources');
    emojiRoot = Directory('${root.path}${Platform.pathSeparator}emoji');
    mediaCache = ChatMediaCache();
    mediaDiskCache = ChatMediaDiskCache(rootDirectory: () async => previewRoot);
    sources = DurableAttachmentSourceStore(root: sourceRoot);
    emojiUsage = FileEmojiUsageStore(directory: emojiRoot);
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  AccountRemovalService buildService(
    HttpNextcloudApi api, {
    AccountRemovalStarted? onRemovalStarted,
  }) {
    return AccountRemovalService(
      accounts: accounts,
      credentials: vault,
      api: api,
      mediaCache: mediaCache,
      mediaDiskCache: mediaDiskCache,
      emojiUsage: emojiUsage,
      voiceDirectory: () async => voiceRoot,
      attachmentSources: () async => sources,
      onRemovalStarted: onRemovalStarted,
    );
  }

  test('suspends account push before remote revocation starts', () async {
    final steps = <String>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        steps.add('${request.method} ${request.url.path}');
        return http.Response(_okOcs(), 200);
      }),
    );
    addTearDown(api.close);
    await _seedAccount(database, accounts, vault, 'account-a', _serverA);

    await buildService(
      api,
      onRemovalStarted: (accountId) async {
        steps.add('suspend $accountId');
      },
    ).removeAccount('account-a');

    expect(steps, <String>[
      'suspend account-a',
      'DELETE /ocs/v2.php/apps/notifications/api/v2/webpush',
      'DELETE /ocs/v2.php/core/apppassword',
    ]);
  });

  test('leaves nothing of a removed account in the database or the vault, '
      'and touches nothing of the account that stays', () async {
    final requestedPaths = <String>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requestedPaths.add('${request.method} ${request.url.path}');
        return http.Response(_okOcs(), 200);
      }),
    );

    await _seedAccount(database, accounts, vault, 'account-a', _serverA);
    await _seedAccount(database, accounts, vault, 'account-b', _serverB);
    await _seedFiles(
      mediaCache: mediaCache,
      mediaDiskCache: mediaDiskCache,
      voiceRoot: voiceRoot,
      accountId: 'account-a',
    );
    await _seedFiles(
      mediaCache: mediaCache,
      mediaDiskCache: mediaDiskCache,
      voiceRoot: voiceRoot,
      accountId: 'account-b',
    );
    final sourceA = await _seedSource(database, sources, 'account-a');
    final sourceB = await _seedSource(database, sources, 'account-b');
    await emojiUsage.recordSelection(AccountId.parse('account-a'), '😀');
    await emojiUsage.toggleFavorite(AccountId.parse('account-a'), '❤️');
    await emojiUsage.recordSelection(AccountId.parse('account-b'), '👋');
    await emojiUsage.toggleFavorite(AccountId.parse('account-b'), '✅');

    final before = await _accountScopedRowCounts(database, 'account-a');
    // Guards the guard: if this ever finds nothing, the assertion below would
    // pass vacuously.
    expect(before.length, greaterThanOrEqualTo(10));
    expect(
      before.values.every((count) => count > 0),
      isTrue,
      reason: '$before',
    );

    final outcome = await buildService(api).removeAccount('account-a');

    expect(outcome.accountExisted, isTrue);
    expect(outcome.appPasswordRevoked, isTrue);
    expect(requestedPaths, <String>[
      'DELETE /ocs/v2.php/apps/notifications/api/v2/webpush',
      'DELETE /ocs/v2.php/core/apppassword',
    ]);

    // Every table that carries an account_id, plus the accounts row itself.
    final after = await _accountScopedRowCounts(database, 'account-a');
    expect(after.keys, before.keys);
    expect(
      after.values.every((count) => count == 0),
      isTrue,
      reason: 'rows left behind: $after',
    );

    expect(vault.values.containsKey('account-a'), isFalse);
    expect(vault.values['account-b'], isNotNull);

    expect(mediaCache.read(_previewKey('account-a')), isNull);
    expect(mediaCache.read(_previewKey('account-b')), isNotNull);
    expect(
      await mediaDiskCache.read(accountId: 'account-a', uri: _previewUri),
      isNull,
    );
    expect(
      await mediaDiskCache.read(accountId: 'account-b', uri: _previewUri),
      isNotNull,
    );
    expect(await _voiceFile(voiceRoot, 'account-a').exists(), isFalse);
    expect(await _voiceFile(voiceRoot, 'account-b').exists(), isTrue);
    expect(
      await emojiUsage.read(AccountId.parse('account-a')),
      same(EmojiUsage.empty),
    );
    final survivorEmoji = await emojiUsage.read(AccountId.parse('account-b'));
    expect(survivorEmoji.recent, <String>['👋']);
    expect(survivorEmoji.favorites, <String>['✅']);

    await expectLater(sources.open(sourceA), throwsA(isA<Object>()));
    await (await sources.open(sourceB)).close();

    // The surviving account kept all of its own rows.
    final survivor = await _accountScopedRowCounts(database, 'account-b');
    expect(
      survivor.values.every((count) => count > 0),
      isTrue,
      reason: 'account-b lost rows: $survivor',
    );
  });

  test('completes the local wipe when the server cannot be reached', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        throw const SocketException('offline');
      }),
    );
    await _seedAccount(database, accounts, vault, 'account-a', _serverA);

    final outcome = await buildService(api).removeAccount('account-a');

    expect(outcome.accountExisted, isTrue);
    // A failed revocation is never reported as a completed one.
    expect(outcome.appPasswordRevoked, isFalse);
    final after = await _accountScopedRowCounts(database, 'account-a');
    expect(after.values.every((count) => count == 0), isTrue, reason: '$after');
    expect(vault.values.containsKey('account-a'), isFalse);
  });

  test(
    'a server that rejects the revocation still loses the local copy',
    () async {
      final api = HttpNextcloudApi(
        client: MockClient((request) async => http.Response('{}', 401)),
      );
      await _seedAccount(database, accounts, vault, 'account-a', _serverA);

      final outcome = await buildService(api).removeAccount('account-a');

      expect(outcome.appPasswordRevoked, isFalse);
      expect(await accounts.getAccount('account-a'), isNull);
      expect(vault.values.containsKey('account-a'), isFalse);
    },
  );

  test('removing the active account promotes the oldest survivor', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response(_okOcs(), 200)),
    );
    await _seedAccount(database, accounts, vault, 'account-a', _serverA);
    await _seedAccount(database, accounts, vault, 'account-b', _serverB);
    // The most recent upsert is the selected one.
    expect((await accounts.getAccount('account-b'))!.selected, isTrue);

    await buildService(api).removeAccount('account-b');

    final remaining = await database.select(database.accounts).get();
    expect(remaining.map((account) => account.id), <String>['account-a']);
    expect(remaining.single.selected, isTrue);
  });

  test('removing a non-active account never switches the active one', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response(_okOcs(), 200)),
    );
    await _seedAccount(database, accounts, vault, 'account-a', _serverA);
    await _seedAccount(database, accounts, vault, 'account-b', _serverB);

    await buildService(api).removeAccount('account-a');

    final remaining = await database.select(database.accounts).get();
    expect(remaining.single.id, 'account-b');
    expect(remaining.single.selected, isTrue);
  });

  test('removing the last account leaves nothing selected, which is what '
      'returns the shell to onboarding', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response(_okOcs(), 200)),
    );
    await _seedAccount(database, accounts, vault, 'account-a', _serverA);

    await buildService(api).removeAccount('account-a');

    expect(await database.select(database.accounts).get(), isEmpty);
    expect(await accounts.watchSelectedAccount().first, isNull);
  });

  test('a second removal of the same account is a no-op', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async => http.Response(_okOcs(), 200)),
    );
    await _seedAccount(database, accounts, vault, 'account-a', _serverA);
    final service = buildService(api);

    expect((await service.removeAccount('account-a')).accountExisted, isTrue);
    expect((await service.removeAccount('account-a')).accountExisted, isFalse);
  });
}

final Uri _previewUri = Uri.parse('$_serverA/core/preview?fileId=7');

String _previewKey(String accountId) =>
    ChatMediaCache.keyOf(accountId: accountId, uri: _previewUri);

File _voiceFile(Directory voiceRoot, String accountId) {
  return File(
    '${voiceRoot.path}${Platform.pathSeparator}'
    '${chatVoiceCacheKey(accountId: accountId, messageId: 42)}',
  );
}

String _okOcs() => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{},
  },
});

/// Counts, for every table that scopes rows by account, how many belong to
/// [accountId].
///
/// Reads the table list out of the schema rather than naming tables here, so a
/// table added later without a matching delete fails this test instead of
/// silently leaking one account's data past its removal.
Future<Map<String, int>> _accountScopedRowCounts(
  AppDatabase database,
  String accountId,
) async {
  final tables = await database
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  final counts = <String, int>{};
  for (final table in tables) {
    final name = table.read<String>('name');
    final columns = await database
        .customSelect('PRAGMA table_info($name)')
        .get();
    final scopedByAccountId = columns.any(
      (column) => column.read<String>('name') == 'account_id',
    );
    final predicate = scopedByAccountId
        ? 'account_id = ?'
        : name == 'accounts'
        ? 'id = ?'
        : null;
    if (predicate == null) {
      continue;
    }
    final row = await database
        .customSelect(
          'SELECT COUNT(*) AS total FROM $name WHERE $predicate',
          variables: [Variable<String>(accountId)],
        )
        .getSingle();
    counts[name] = row.read<int>('total');
  }
  return counts;
}

Future<void> _seedAccount(
  AppDatabase database,
  AccountRepository accounts,
  MemoryCredentialVault vault,
  String accountId,
  String serverUrl,
) async {
  await accounts.upsertAccount(
    accountId: accountId,
    serverUrl: serverUrl,
    loginName: 'user-$accountId',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, accountId == 'account-a' ? 1 : 2),
  );
  vault.values[accountId] = 'fixture-app-password-never-use';

  const roomToken = 'rooma123';
  await database
      .into(database.callSessions)
      .insert(
        CallSessionsCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          serverUrl: serverUrl,
          credentialGeneration: 1,
          capabilityGeneration: 1,
          settingsRevision: 'fixture-revision',
          profileEnabled: true,
          profileChatRelay: false,
          nextcloudSessionId: 'fixture-session',
          connectionEpoch: 1,
          roomEpoch: 1,
          renegotiationRequired: false,
          updatedAtMillis: 1770000000,
        ),
      );
  await database
      .into(database.callLifecycleSessions)
      .insert(
        CallLifecycleSessionsCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          serverUrl: serverUrl,
          nextcloudSessionId: 'fixture-session',
          credentialGeneration: 1,
          capabilityGeneration: 1,
          capabilityRevision: 'call-v4:1:1:1:2',
          phase: 'joined',
          confirmedFlags: const Value(7),
          mutationSequence: 1,
          updatedAtMillis: 1770000000,
        ),
      );
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
          token: roomToken,
          displayName: 'Room',
          description: '',
          lastActivity: 20,
          unreadMessages: 1,
          favorite: false,
          rawJson: '{}',
        ),
      );
  await database
      .into(database.conversationAvatars)
      .insert(
        ConversationAvatarsCompanion.insert(
          accountId: accountId,
          cacheKey: 'avatar-key',
          body: Uint8List.fromList(<int>[1, 2, 3]),
          contentType: 'image/png',
          expiresAtMillis: 1770000000,
          updatedAtMillis: 1770000000,
        ),
      );
  await database
      .into(database.chatCapabilities)
      .insert(
        ChatCapabilitiesCompanion.insert(
          accountId: accountId,
          fingerprint: 'fingerprint',
          updatedAtMillis: 1770000000,
        ),
      );
  await database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          scopeKey: 'root',
          historyCursor: '0',
          futureCursor: '0',
          lastCommonRead: '0',
          lastReadMessage: 0,
          unreadMessages: 0,
          hasHistory: true,
          futureConverged: false,
          blocksJson: '[]',
        ),
      );
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: 101,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 1770000101,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '11111111-1111-4111-8111-111111111111',
          displayText: 'Confidential',
          deleted: false,
          rawJson: '{}',
        ),
      );
  await database
      .into(database.textSendOperations)
      .insert(
        TextSendOperationsCompanion.insert(
          accountId: accountId,
          operationId: 'operation-1',
          roomToken: roomToken,
          referenceId: '22222222-2222-4222-8222-222222222222',
          message: 'Queued but never sent',
          replayContractRevision: 'r1',
          enqueueSequence: 1,
          outboxState: 'queued',
          attemptCount: 0,
          messageIdsJson: '[]',
          duplicateRiskAcknowledged: false,
          createdAtMillis: 1770000000,
          updatedAtMillis: 1770000000,
        ),
      );
  await database
      .into(database.chatDrafts)
      .insert(
        ChatDraftsCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          scopeKey: 'root',
          draftText: 'Half-written and private',
          updatedAtMillis: 1770000000,
        ),
      );
}

/// Inserts an upload job plus the durable copy of the file it would send, and
/// returns the handle for that copy.
Future<AttachmentSourceHandle> _seedSource(
  AppDatabase database,
  DurableAttachmentSourceStore sources,
  String accountId,
) async {
  final source = await sources.copyFromStream(
    stream: Stream<List<int>>.value(<int>[9, 8, 7, 6]),
    mimeType: 'image/png',
    displayName: 'private.png',
  );
  await database
      .into(database.attachmentRuntimeAccounts)
      .insert(
        AttachmentRuntimeAccountsCompanion.insert(
          accountId: accountId,
          serverUrl: accountId == 'account-a' ? _serverA : _serverB,
          lane: 'ready',
          credentialGeneration: 1,
          capabilityGeneration: 1,
          updatedAtMillis: 1770000000,
        ),
      );
  await database
      .into(database.attachmentJobs)
      .insert(
        AttachmentJobsCompanion.insert(
          accountId: accountId,
          jobId: 'job-1',
          serverUrl: accountId == 'account-a' ? _serverA : _serverB,
          capabilityGeneration: 1,
          replayContractRevision: 'r1',
          davUserId: 'fixture-user',
          roomToken: 'rooma123',
          referenceId: '33333333-3333-4333-8333-333333333333',
          sourceHandle: source.handle.value,
          sourceOwnership: source.ownership.name,
          sourceByteLength: source.byteLength,
          sourceSha256: source.sha256.value,
          sourceMimeType: 'image/png',
          sourceDisplayName: 'private.png',
          messageKind: 'file',
          silent: false,
          enqueueSequence: 1,
          normalUploadMaximumBytes: 1024,
          chunkSizeBytes: 1024,
          phase: 'queued',
          chunkCollectionReady: false,
          chunkManifestLoaded: false,
          verifiedChunksJson: '[]',
          attemptCount: 0,
          finalizationDispatched: false,
          cleanupChunkSession: false,
          cleanupDraftFile: false,
          messageIdsJson: '[]',
          profileFederated: false,
          profileEnabled: true,
          profileCaption: true,
          profileVoice: true,
          profileReply: true,
          profileThreads: true,
          profileSilent: true,
          roomCanWrite: true,
          sourceReleased: const Value(false),
          createdAtMillis: 1770000000,
          updatedAtMillis: 1770000000,
        ),
      );
  return source.handle;
}

Future<void> _seedFiles({
  required ChatMediaCache mediaCache,
  required ChatMediaDiskCache mediaDiskCache,
  required Directory voiceRoot,
  required String accountId,
}) async {
  final image = ChatMediaImage(
    body: Uint8List.fromList(<int>[1, 2, 3, 4]),
    contentType: 'image/png',
  );
  mediaCache.write(_previewKey(accountId), image);
  await mediaDiskCache.write(
    accountId: accountId,
    uri: _previewUri,
    image: image,
  );
  await voiceRoot.create(recursive: true);
  await _voiceFile(
    voiceRoot,
    accountId,
  ).writeAsBytes(<int>[5, 5, 5], flush: true);
}
