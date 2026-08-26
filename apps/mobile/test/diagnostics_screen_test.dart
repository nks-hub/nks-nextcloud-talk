import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/diagnostics/diagnostics_screen.dart';
import 'package:nextcloudtalk/features/diagnostics/local_diagnostics.dart';
import 'package:nextcloudtalk/features/push/android_web_push_bridge.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';

import 'test_support.dart';

/// Identity and content that must never reach a shareable diagnostics screen.
const _loginName = 'alice';
const _serverUrl = 'https://cloud-a.example.invalid';
const _roomToken = 'room-token-alpha';
const _messageText = 'Synthetic message body';
const _threadTitle = 'Synthetic thread title';
const _attachmentName = 'synthetic-attachment.bin';

/// testWidgets runs a fake clock, so real Drift I/O never finishes on a plain
/// pump. Route it through runAsync, which briefly leaves the fake zone.
Future<void> _flushRealAsync(WidgetTester tester) {
  return tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
}

Future<void> _settleRealAsync(WidgetTester tester, {int rounds = 12}) async {
  for (var round = 0; round < rounds; round++) {
    await _flushRealAsync(tester);
    await tester.pump();
  }
}

final class _FakePushPlatform implements AndroidWebPushPlatform {
  _FakePushPlatform(this.state);

  final AndroidWebPushRegistrationState state;
  final requestedAccountIds = <String>[];

  @override
  Future<AndroidWebPushRegistrationState> getRegistrationState({
    required String accountId,
  }) async {
    requestedAccountIds.add(accountId);
    return state;
  }

  Never _unused() => throw UnsupportedError('Not used by diagnostics');

  @override
  Stream<int> get eventsAvailable => _unused();

  @override
  Stream<AndroidNotificationOpen> get notificationOpened => _unused();

  @override
  Future<AndroidWebPushAvailability> getAvailability() => _unused();

  @override
  Future<AndroidNotificationPermission> getNotificationPermission() =>
      _unused();

  @override
  Future<AndroidNotificationPermission> requestNotificationPermission() =>
      _unused();

  @override
  Future<AndroidNotificationOpen?> getLaunchNotification() => _unused();

  @override
  Future<AndroidWebPushRegistrationResult> register({
    required String accountId,
    required int generation,
    required String vapidPublicKey,
  }) => _unused();

  @override
  Future<AndroidWebPushCommitResult> commitEndpoint({
    required String accountId,
    required int generation,
    required String eventId,
  }) => _unused();

  @override
  Future<List<int>> prepareServerRevocation({required String accountId}) =>
      _unused();

  @override
  Future<int> retireAfterServerRevocation({
    required String accountId,
    required int generation,
  }) => _unused();

  @override
  Future<int> pendingEventCount({required String accountId}) => _unused();

  @override
  Future<List<AndroidWebPushEvent>> drainEvents({
    required String accountId,
    int limit = 0,
  }) => _unused();

  @override
  Future<int> acknowledge({
    required String accountId,
    required Iterable<String> eventIds,
  }) => _unused();

  @override
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit = 0,
  }) => _unused();

  @override
  Future<bool> resolveNotificationAction({
    required String accountId,
    required String actionId,
    required AndroidNotificationActionOutcome outcome,
  }) => _unused();

  @override
  Future<void> dispose() => _unused();
}

Future<void> _seedConversation(
  AppDatabase database, {
  required String accountId,
  required String token,
}) {
  return database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
          token: token,
          displayName: 'Synthetic room',
          description: '',
          lastActivity: 1,
          unreadMessages: 0,
          favorite: false,
          rawJson: '{}',
        ),
      );
}

Future<void> _seedMessage(
  AppDatabase database, {
  required String accountId,
  required int messageId,
}) {
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: _roomToken,
          messageId: messageId,
          actorType: 'users',
          actorId: _loginName,
          actorDisplayName: _loginName,
          timestamp: 1,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-$messageId',
          displayText: _messageText,
          deleted: false,
          rawJson: '{}',
        ),
      );
}

Future<void> _seedThread(AppDatabase database, {required String accountId}) {
  return database
      .into(database.cachedThreads)
      .insert(
        CachedThreadsCompanion.insert(
          accountId: accountId,
          roomToken: _roomToken,
          threadId: 42,
          title: _threadTitle,
          lastMessageId: 7,
          lastActivity: 1,
          numReplies: 2,
          notificationLevel: 0,
          rawJson: '{}',
        ),
      );
}

Future<void> _seedTextSend(
  AppDatabase database, {
  required String accountId,
  required String operationId,
  required String outboxState,
  String? errorClass,
  required int updatedAtMillis,
}) {
  return database
      .into(database.textSendOperations)
      .insert(
        TextSendOperationsCompanion.insert(
          accountId: accountId,
          operationId: operationId,
          roomToken: _roomToken,
          referenceId: 'reference-$operationId',
          message: _messageText,
          replayContractRevision: 'chat-send-1',
          enqueueSequence: updatedAtMillis,
          outboxState: outboxState,
          attemptCount: 1,
          messageIdsJson: '[]',
          duplicateRiskAcknowledged: false,
          errorClass: Value(errorClass),
          createdAtMillis: updatedAtMillis,
          updatedAtMillis: updatedAtMillis,
        ),
      );
}

/// An attachment job hangs off the account's attachment runtime row, so that
/// row has to exist before any job can be inserted.
Future<void> _seedAttachmentRuntime(
  AppDatabase database, {
  required String accountId,
  required String serverUrl,
}) {
  return database
      .into(database.attachmentRuntimeAccounts)
      .insert(
        AttachmentRuntimeAccountsCompanion.insert(
          accountId: accountId,
          serverUrl: serverUrl,
          lane: 'ready',
          credentialGeneration: 1,
          capabilityGeneration: 1,
          updatedAtMillis: 1,
        ),
      );
}

Future<void> _seedAttachmentJob(
  AppDatabase database, {
  required String accountId,
  required String jobId,
  required String phase,
  String? errorClass,
  required int updatedAtMillis,
}) {
  return database
      .into(database.attachmentJobs)
      .insert(
        AttachmentJobsCompanion.insert(
          accountId: accountId,
          jobId: jobId,
          serverUrl: _serverUrl,
          capabilityGeneration: 1,
          replayContractRevision: 'attachment-1',
          davUserId: _loginName,
          roomToken: _roomToken,
          referenceId: 'reference-$jobId',
          sourceHandle: 'handle-$jobId',
          sourceOwnership: 'appOwnedCopy',
          sourceByteLength: 4,
          sourceSha256: 'a' * 64,
          sourceMimeType: 'application/octet-stream',
          sourceDisplayName: _attachmentName,
          messageKind: 'file',
          silent: false,
          enqueueSequence: updatedAtMillis,
          normalUploadMaximumBytes: 4,
          chunkSizeBytes: 4,
          phase: phase,
          chunkCollectionReady: false,
          chunkManifestLoaded: false,
          verifiedChunksJson: '[]',
          attemptCount: 1,
          finalizationDispatched: false,
          cleanupChunkSession: false,
          cleanupDraftFile: false,
          messageIdsJson: '[]',
          errorClass: Value(errorClass),
          profileFederated: false,
          profileEnabled: true,
          profileCaption: true,
          profileVoice: true,
          profileReply: true,
          profileThreads: true,
          profileSilent: true,
          roomCanWrite: true,
          createdAtMillis: updatedAtMillis,
          updatedAtMillis: updatedAtMillis,
        ),
      );
}

/// Two accounts on two servers, so every counter has a neighbour it must not
/// pick up. Account A also carries a failed sync and a mixed outbox.
Future<void> _seedFixture(AppDatabase database) async {
  final accounts = AccountRepository(database);
  await accounts.upsertAccount(
    accountId: 'account-a',
    serverUrl: _serverUrl,
    loginName: _loginName,
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, 1),
    talkFeatures: const {'conversation-v4', 'chat-v2', 'threads'},
  );
  await accounts.upsertAccount(
    accountId: 'account-b',
    serverUrl: 'https://cloud-b.example.invalid',
    loginName: 'bob',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, 2),
  );
  await (database.update(
    database.accounts,
  )..where((account) => account.id.equals('account-a'))).write(
    AccountsCompanion(
      lastSyncedAtMillis: Value(
        DateTime.utc(2026, 3, 4, 5, 6, 7).millisecondsSinceEpoch,
      ),
      lastSyncError: const Value('unauthorized'),
    ),
  );

  await _seedConversation(database, accountId: 'account-a', token: _roomToken);
  await _seedConversation(database, accountId: 'account-a', token: 'room-two');
  await _seedConversation(database, accountId: 'account-b', token: 'room-b');
  await _seedMessage(database, accountId: 'account-a', messageId: 1);
  await _seedMessage(database, accountId: 'account-a', messageId: 2);
  await _seedMessage(database, accountId: 'account-a', messageId: 3);
  await _seedMessage(database, accountId: 'account-b', messageId: 1);
  await _seedThread(database, accountId: 'account-a');

  await _seedTextSend(
    database,
    accountId: 'account-a',
    operationId: 'send-queued',
    outboxState: 'queued',
    updatedAtMillis: 1000,
  );
  await _seedTextSend(
    database,
    accountId: 'account-a',
    operationId: 'send-failed-old',
    outboxState: 'failed',
    errorClass: 'network',
    updatedAtMillis: 2000,
  );
  await _seedTextSend(
    database,
    accountId: 'account-a',
    operationId: 'send-failed-new',
    outboxState: 'failed',
    errorClass: 'rate-limited',
    updatedAtMillis: 3000,
  );
  await _seedTextSend(
    database,
    accountId: 'account-b',
    operationId: 'send-other-account',
    outboxState: 'failed',
    errorClass: 'foreign-account',
    updatedAtMillis: 9000,
  );

  await _seedAttachmentRuntime(
    database,
    accountId: 'account-a',
    serverUrl: _serverUrl,
  );
  await _seedAttachmentRuntime(
    database,
    accountId: 'account-b',
    serverUrl: 'https://cloud-b.example.invalid',
  );
  await _seedAttachmentJob(
    database,
    accountId: 'account-a',
    jobId: 'job-uploading',
    phase: 'uploading',
    updatedAtMillis: 1000,
  );
  await _seedAttachmentJob(
    database,
    accountId: 'account-a',
    jobId: 'job-failed',
    phase: 'failed',
    errorClass: 'dav-rejected',
    updatedAtMillis: 2000,
  );
  await _seedAttachmentJob(
    database,
    accountId: 'account-b',
    jobId: 'job-other-account',
    phase: 'failed',
    errorClass: 'foreign-account',
    updatedAtMillis: 9000,
  );
}

Widget _wrapDiagnostics({
  required AppDatabase database,
  required AndroidWebPushPlatform? push,
}) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      accountRepositoryProvider.overrideWithValue(AccountRepository(database)),
      androidWebPushPlatformProvider.overrideWithValue(push),
    ],
    child: localizedTestApp(
      home: const DiagnosticsScreen(accountId: 'account-a'),
    ),
  );
}

/// The screen is one long list and a `ListView` only builds what fits. Give
/// the test a surface tall enough for every entry so assertions do not depend
/// on scroll position.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

String _valueOf(WidgetTester tester, String key) {
  final tile = tester.widget<ListTile>(find.byKey(Key(key)));
  return (tile.subtitle! as Text).data!;
}

void main() {
  testWidgets('reports the local state of exactly the requested account', (
    tester,
  ) async {
    _useTallSurface(tester);
    final database = openTestDatabase();
    addTearDown(database.close);
    await tester.runAsync(() => _seedFixture(database));
    final push = _FakePushPlatform(
      const AndroidWebPushRegistrationState(
        generation: 7,
        nextGeneration: 8,
        phase: AndroidWebPushRegistrationPhase.active,
        pendingEventCount: 2,
      ),
    );

    await tester.pumpWidget(_wrapDiagnostics(database: database, push: push));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settleRealAsync(tester);

    expect(_valueOf(tester, 'diagnostics-app-version'), appVersionName);
    expect(_valueOf(tester, 'diagnostics-app-build'), appBuildNumber);
    expect(
      _valueOf(tester, 'diagnostics-schema-version'),
      '${database.schemaVersion}',
    );

    // Account B holds one conversation, one message and one failed entry in
    // each outbox; none of them may show up here.
    expect(_valueOf(tester, 'diagnostics-conversation-rows'), '2');
    expect(_valueOf(tester, 'diagnostics-message-rows'), '3');
    expect(_valueOf(tester, 'diagnostics-thread-rows'), '1');
    expect(_valueOf(tester, 'diagnostics-text-outbox-rows'), '3');
    expect(_valueOf(tester, 'diagnostics-attachment-outbox-rows'), '2');

    expect(_valueOf(tester, 'diagnostics-text-outbox-pending'), '1');
    expect(_valueOf(tester, 'diagnostics-text-outbox-failed'), '2');
    // The newest failure wins, and only its error vocabulary is shown.
    expect(
      _valueOf(tester, 'diagnostics-text-outbox-last-error'),
      startsWith('rate-limited · '),
    );
    expect(_valueOf(tester, 'diagnostics-attachment-outbox-pending'), '1');
    expect(_valueOf(tester, 'diagnostics-attachment-outbox-failed'), '1');
    expect(
      _valueOf(tester, 'diagnostics-attachment-outbox-last-error'),
      startsWith('dav-rejected · '),
    );

    expect(
      _valueOf(tester, 'diagnostics-sync-last-success'),
      DateTime.utc(2026, 3, 4, 5, 6, 7).toIso8601String(),
    );
    expect(_valueOf(tester, 'diagnostics-sync-last-error'), 'unauthorized');

    expect(push.requestedAccountIds, ['account-a']);
    expect(_valueOf(tester, 'diagnostics-push-phase'), 'active');
    expect(_valueOf(tester, 'diagnostics-push-generation'), '7');
    expect(_valueOf(tester, 'diagnostics-push-next-generation'), '8');
    expect(_valueOf(tester, 'diagnostics-push-pending-events'), '2');

    expect(_valueOf(tester, 'diagnostics-talk-feature-count'), '3');
    expect(_valueOf(tester, 'diagnostics-talk-feature-threads'), 'Yes');
    expect(_valueOf(tester, 'diagnostics-talk-feature-chat-v2'), 'Yes');
    expect(_valueOf(tester, 'diagnostics-talk-feature-signaling-v3'), 'No');
  });

  testWidgets('never renders account identity, room tokens or message text', (
    tester,
  ) async {
    _useTallSurface(tester);
    final database = openTestDatabase();
    addTearDown(database.close);
    await tester.runAsync(() => _seedFixture(database));

    await tester.pumpWidget(
      _wrapDiagnostics(
        database: database,
        push: _FakePushPlatform(
          const AndroidWebPushRegistrationState(
            generation: 7,
            nextGeneration: 8,
            phase: AndroidWebPushRegistrationPhase.active,
            pendingEventCount: 2,
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settleRealAsync(tester);

    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .join('\n');
    expect(rendered, isNot(contains(_loginName)));
    expect(rendered, isNot(contains(_serverUrl)));
    expect(rendered, isNot(contains(_roomToken)));
    expect(rendered, isNot(contains(_messageText)));
    expect(rendered, isNot(contains(_threadTitle)));
    expect(rendered, isNot(contains(_attachmentName)));
    expect(rendered, isNot(contains('account-a')));
  });

  testWidgets('says push state is unavailable instead of inventing one', (
    tester,
  ) async {
    _useTallSurface(tester);
    final database = openTestDatabase();
    addTearDown(database.close);
    await tester.runAsync(() => _seedFixture(database));

    await tester.pumpWidget(_wrapDiagnostics(database: database, push: null));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settleRealAsync(tester);

    expect(find.byKey(const Key('diagnostics-push-phase')), findsNothing);
    expect(
      _valueOf(tester, 'diagnostics-push-unavailable'),
      'Not available on this platform.',
    );
  });

  testWidgets('reports a failure instead of a blank screen when the account '
      'is gone', (tester) async {
    _useTallSurface(tester);
    final database = openTestDatabase();
    addTearDown(database.close);

    await tester.pumpWidget(_wrapDiagnostics(database: database, push: null));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settleRealAsync(tester);

    expect(find.byKey(const Key('diagnostics-load-failed')), findsOneWidget);
    expect(find.byKey(const Key('diagnostics-list')), findsNothing);
  });

  testWidgets('settings opens diagnostics for the active account', (
    tester,
  ) async {
    _useTallSurface(tester);
    final database = openTestDatabase();
    addTearDown(database.close);
    await tester.runAsync(() => _seedFixture(database));
    final accounts = AccountRepository(database);
    late List<StoredAccount> stored;
    await tester.runAsync(() async {
      stored = await database.select(database.accounts).get();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          accountRepositoryProvider.overrideWithValue(accounts),
          accountsProvider.overrideWith((ref) => Stream.value(stored)),
          androidWebPushPlatformProvider.overrideWithValue(null),
        ],
        child: localizedTestApp(home: const SettingsScreen()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings-open-diagnostics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _settleRealAsync(tester);

    expect(find.byType(DiagnosticsScreen), findsOneWidget);
    // account-b was stored last, so it is the active one and the one the
    // screen has to be scoped to.
    expect(_valueOf(tester, 'diagnostics-conversation-rows'), '1');
    expect(_valueOf(tester, 'diagnostics-message-rows'), '1');
  });

  test('the reported version is the one pubspec.yaml ships', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final declared = pubspec
        .firstWhere((line) => line.startsWith('version:'))
        .substring('version:'.length)
        .trim();
    expect(declared, '$appVersionName+$appBuildNumber');
  });
}
