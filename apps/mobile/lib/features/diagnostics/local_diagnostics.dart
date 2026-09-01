import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../push/android_web_push_bridge.dart';

export '../../core/app_version.dart' show appBuildNumber, appVersionName;

/// Talk features the client branches on, shown so a support case can tell a
/// missing capability apart from a bug. Every name is a real Talk feature the
/// protocol package already keys off.
const diagnosticsKeyTalkFeatures = <String>[
  'conversation-v4',
  'chat-v2',
  'chat-reference-id',
  'chat-read-marker',
  'threads',
  'signaling-v3',
];

const _pendingTextSendStates = <TextSendOutboxState>{
  TextSendOutboxState.queued,
  TextSendOutboxState.sending,
  TextSendOutboxState.retryable,
  TextSendOutboxState.awaitingConfirmation,
};

const _pendingAttachmentPhases = <AttachmentJobPhase>{
  AttachmentJobPhase.localPrepared,
  AttachmentJobPhase.probing,
  AttachmentJobPhase.draftResolved,
  AttachmentJobPhase.uploading,
  AttachmentJobPhase.uploaded,
  AttachmentJobPhase.finalizing,
  AttachmentJobPhase.awaitingConfirmation,
  AttachmentJobPhase.retryable,
  AttachmentJobPhase.cancelling,
};

const _failedAttachmentPhases = <AttachmentJobPhase>{
  AttachmentJobPhase.failed,
  AttachmentJobPhase.cleanupFailed,
};

/// Mirrors what `requestAttachmentCancel` refuses. A job that already
/// dispatched its finalization is excluded separately, because the server may
/// hold the message even though the phase still looks cancellable.
const _uncancellableAttachmentPhases = <AttachmentJobPhase>{
  AttachmentJobPhase.finalizing,
  AttachmentJobPhase.awaitingConfirmation,
  AttachmentJobPhase.completed,
  AttachmentJobPhase.cancelled,
};

/// Why a push registration state could not be reported.
enum PushDiagnosticsGap { platformUnsupported, readFailed }

enum MigrationDiagnosticsState { upToDate, upgradeRequired, newerThanApp }

@immutable
final class DatabaseDiagnostics {
  const DatabaseDiagnostics({
    required this.expectedSchemaVersion,
    required this.storedSchemaVersion,
    required this.foreignKeyViolationCount,
  });

  final int expectedSchemaVersion;
  final int storedSchemaVersion;
  final int foreignKeyViolationCount;

  MigrationDiagnosticsState get migrationState {
    if (storedSchemaVersion < expectedSchemaVersion) {
      return MigrationDiagnosticsState.upgradeRequired;
    }
    if (storedSchemaVersion > expectedSchemaVersion) {
      return MigrationDiagnosticsState.newerThanApp;
    }
    return MigrationDiagnosticsState.upToDate;
  }
}

/// Counters of one durable outbox, without any of the payload it carries.
@immutable
final class OutboxDiagnostics {
  const OutboxDiagnostics({
    required this.total,
    required this.pending,
    required this.failed,
    required this.lastErrorClass,
    required this.lastErrorAt,
  });

  final int total;
  final int pending;
  final int failed;

  /// Error vocabulary of the newest failed entry, for example `network` or
  /// `dav-transient`. Never a server message and never message content.
  final String? lastErrorClass;
  final DateTime? lastErrorAt;
}

/// Push registration of one account, or the reason it is not reportable.
@immutable
final class PushDiagnostics {
  const PushDiagnostics.registered({
    required this.phase,
    required this.generation,
    required this.nextGeneration,
    required this.pendingEventCount,
  }) : gap = null,
       failureCode = null;

  const PushDiagnostics.unavailable(this.gap, {this.failureCode})
    : phase = null,
      generation = null,
      nextGeneration = null,
      pendingEventCount = null;

  final AndroidWebPushRegistrationPhase? phase;
  final int? generation;
  final int? nextGeneration;
  final int? pendingEventCount;
  final PushDiagnosticsGap? gap;

  /// Platform error code or exception type behind a [PushDiagnosticsGap
  /// .readFailed]. Deliberately not the exception message, which is native
  /// text this screen cannot vouch for.
  final String? failureCode;
}

/// One attachment job that has not reached a terminal phase, reduced to what
/// a support call may hear.
///
/// The job id is carried so the screen can act on the row, but nothing about
/// the payload is: no room token, no server, no file name, path, size or hash,
/// and no caption. The attempt count is bucketed because an exact number of a
/// specific upload says more about the account than it helps.
@immutable
final class StalledAttachmentJob {
  const StalledAttachmentJob({
    required this.jobId,
    required this.kind,
    required this.phase,
    required this.age,
    required this.attemptBucket,
    required this.cancellable,
  });

  final String jobId;
  final AttachmentMessageKind kind;
  final AttachmentJobPhase phase;
  final Duration age;

  /// `0`, `1`, `2-4` or `5+`.
  final String attemptBucket;

  /// Whether [AttachmentService.cancel] would accept this job. A dispatched
  /// finalization is never cancellable: the server may already hold the
  /// message, so removing the row locally would claim an outcome we do not
  /// know.
  final bool cancellable;
}

/// Local state of exactly one account, safe to read out over a support call.
///
/// Nothing here identifies the account or its content: no server, no login
/// name, no room tokens, no conversation names, no message text, no
/// credentials and no push subscription endpoint.
@immutable
final class LocalDiagnostics {
  const LocalDiagnostics({
    required this.operatingSystem,
    required this.database,
    required this.conversationCount,
    required this.messageCount,
    required this.threadCount,
    required this.textOutbox,
    required this.attachmentOutbox,
    required this.stalledAttachments,
    required this.push,
    required this.lastSyncedAt,
    required this.lastSyncError,
    required this.talkFeatureCount,
    required this.keyTalkFeatures,
  });

  final String operatingSystem;
  final DatabaseDiagnostics database;
  final int conversationCount;
  final int messageCount;
  final int threadCount;
  final OutboxDiagnostics textOutbox;
  final OutboxDiagnostics attachmentOutbox;

  /// Unfinished attachment jobs, oldest first.
  final List<StalledAttachmentJob> stalledAttachments;
  final PushDiagnostics push;
  final DateTime? lastSyncedAt;

  /// Sync error vocabulary of the account row, for example `unauthorized`.
  final String? lastSyncError;
  final int talkFeatureCount;
  final Map<String, bool> keyTalkFeatures;
}

/// Reads the local state of one account straight from the durable stores.
final class LocalDiagnosticsLoader {
  const LocalDiagnosticsLoader({
    required this.database,
    required this.accounts,
    this.push,
    this.clock = DateTime.now,
  });

  final AppDatabase database;
  final AccountRepository accounts;
  final AndroidWebPushPlatform? push;
  final DateTime Function() clock;

  Future<LocalDiagnostics> load(String accountId) async {
    final account = await accounts.getAccount(accountId);
    if (account == null) {
      throw StateError('Account $accountId is not stored locally');
    }
    final talkFeatures = _talkFeatures(account.talkFeaturesJson);
    final databaseDiagnostics = await _databaseDiagnostics();
    return LocalDiagnostics(
      operatingSystem:
          '${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}',
      database: databaseDiagnostics,
      conversationCount: await _countRows(
        database.cachedConversations,
        database.cachedConversations.accountId.equals(accountId),
      ),
      messageCount: await _countRows(
        database.cachedChatMessages,
        database.cachedChatMessages.accountId.equals(accountId),
      ),
      threadCount: await _countRows(
        database.cachedThreads,
        database.cachedThreads.accountId.equals(accountId),
      ),
      textOutbox: await _textOutbox(accountId),
      attachmentOutbox: await _attachmentOutbox(accountId),
      stalledAttachments: await _stalledAttachments(accountId),
      push: await _pushDiagnostics(accountId),
      lastSyncedAt: _instant(account.lastSyncedAtMillis),
      lastSyncError: account.lastSyncError,
      talkFeatureCount: talkFeatures.length,
      keyTalkFeatures: <String, bool>{
        for (final feature in diagnosticsKeyTalkFeatures)
          feature: talkFeatures.contains(feature),
      },
    );
  }

  /// Text sends never leave the message column, so only the state columns are
  /// selected: the outbox payload must not reach a diagnostics screen.
  Future<OutboxDiagnostics> _textOutbox(String accountId) async {
    final table = database.textSendOperations;
    final query = database.selectOnly(table)
      ..addColumns([table.outboxState, table.errorClass, table.updatedAtMillis])
      ..where(table.accountId.equals(accountId));
    final rows = await query.get();

    var pending = 0;
    var failed = 0;
    String? lastErrorClass;
    DateTime? lastErrorAt;
    for (final row in rows) {
      final state = TextSendOutboxState.values
          .asNameMap()[row.read(table.outboxState)];
      if (state == null) {
        continue;
      }
      if (_pendingTextSendStates.contains(state)) {
        pending++;
        continue;
      }
      if (state != TextSendOutboxState.failed) {
        continue;
      }
      failed++;
      final at = _instant(row.read(table.updatedAtMillis));
      if (at != null && (lastErrorAt == null || at.isAfter(lastErrorAt))) {
        lastErrorAt = at;
        lastErrorClass = row.read(table.errorClass);
      }
    }
    return OutboxDiagnostics(
      total: rows.length,
      pending: pending,
      failed: failed,
      lastErrorClass: lastErrorClass,
      lastErrorAt: lastErrorAt,
    );
  }

  /// Same restraint as [_textOutbox]: the caption and the source file name of
  /// an attachment job stay out of the query.
  Future<OutboxDiagnostics> _attachmentOutbox(String accountId) async {
    final table = database.attachmentJobs;
    final query = database.selectOnly(table)
      ..addColumns([
        table.phase,
        table.errorClass,
        table.localCleanupError,
        table.updatedAtMillis,
      ])
      ..where(table.accountId.equals(accountId));
    final rows = await query.get();

    var pending = 0;
    var failed = 0;
    String? lastErrorClass;
    DateTime? lastErrorAt;
    for (final row in rows) {
      final phase = AttachmentJobPhase.values
          .asNameMap()[row.read(table.phase)];
      if (phase == null) {
        continue;
      }
      if (_pendingAttachmentPhases.contains(phase)) {
        pending++;
        continue;
      }
      if (!_failedAttachmentPhases.contains(phase)) {
        continue;
      }
      failed++;
      final at = _instant(row.read(table.updatedAtMillis));
      if (at != null && (lastErrorAt == null || at.isAfter(lastErrorAt))) {
        lastErrorAt = at;
        lastErrorClass =
            row.read(table.localCleanupError) ?? row.read(table.errorClass);
      }
    }
    return OutboxDiagnostics(
      total: rows.length,
      pending: pending,
      failed: failed,
      lastErrorClass: lastErrorClass,
      lastErrorAt: lastErrorAt,
    );
  }

  /// Unfinished attachment jobs. The projection is deliberately narrow: only
  /// the columns below leave the database, so a screenshot of this list cannot
  /// leak a room, a server or a file.
  Future<List<StalledAttachmentJob>> _stalledAttachments(
    String accountId,
  ) async {
    final table = database.attachmentJobs;
    final query = database.selectOnly(table)
      ..addColumns([
        table.jobId,
        table.messageKind,
        table.phase,
        table.attemptCount,
        table.finalizationDispatched,
        table.createdAtMillis,
      ])
      ..where(table.accountId.equals(accountId))
      ..orderBy([OrderingTerm.asc(table.createdAtMillis)]);
    final rows = await query.get();

    final now = clock().toUtc();
    final jobs = <StalledAttachmentJob>[];
    for (final row in rows) {
      final phase = AttachmentJobPhase.values
          .asNameMap()[row.read(table.phase)];
      if (phase == null || !_pendingAttachmentPhases.contains(phase)) {
        continue;
      }
      final kind = AttachmentMessageKind.values
          .asNameMap()[row.read(table.messageKind)];
      final createdAt = _instant(row.read(table.createdAtMillis));
      final attempts = row.read(table.attemptCount) ?? 0;
      jobs.add(
        StalledAttachmentJob(
          jobId: row.read(table.jobId)!,
          kind: kind ?? AttachmentMessageKind.file,
          phase: phase,
          age: createdAt == null ? Duration.zero : now.difference(createdAt),
          attemptBucket: _attemptBucket(attempts),
          cancellable:
              !(row.read(table.finalizationDispatched) ?? false) &&
              !_uncancellableAttachmentPhases.contains(phase),
        ),
      );
    }
    return List<StalledAttachmentJob>.unmodifiable(jobs);
  }

  static String _attemptBucket(int attempts) {
    if (attempts <= 0) {
      return '0';
    }
    if (attempts == 1) {
      return '1';
    }
    return attempts <= 4 ? '2-4' : '5+';
  }

  Future<PushDiagnostics> _pushDiagnostics(String accountId) async {
    final platform = push;
    if (platform == null) {
      return const PushDiagnostics.unavailable(
        PushDiagnosticsGap.platformUnsupported,
      );
    }
    try {
      final state = await platform.getRegistrationState(accountId: accountId);
      return PushDiagnostics.registered(
        phase: state.phase,
        generation: state.generation,
        nextGeneration: state.nextGeneration,
        pendingEventCount: state.pendingEventCount,
      );
    } on PlatformException catch (error) {
      return PushDiagnostics.unavailable(
        PushDiagnosticsGap.readFailed,
        failureCode: error.code,
      );
    } on Object catch (error) {
      return PushDiagnostics.unavailable(
        PushDiagnosticsGap.readFailed,
        failureCode: error.runtimeType.toString(),
      );
    }
  }

  Future<int> _countRows<T extends Table, R>(
    TableInfo<T, R> table,
    Expression<bool> predicate,
  ) async {
    final total = countAll();
    final query = database.selectOnly(table)
      ..addColumns([total])
      ..where(predicate);
    return (await query.getSingle()).read(total) ?? 0;
  }

  Future<DatabaseDiagnostics> _databaseDiagnostics() async {
    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    final foreignKeyViolations = await database
        .customSelect(
          'SELECT COUNT(*) AS violation_count '
          'FROM pragma_foreign_key_check',
        )
        .getSingle();
    return DatabaseDiagnostics(
      expectedSchemaVersion: database.schemaVersion,
      storedSchemaVersion: version.read<int>('user_version'),
      foreignKeyViolationCount: foreignKeyViolations.read<int>(
        'violation_count',
      ),
    );
  }
}

Set<String> _talkFeatures(String talkFeaturesJson) {
  final decoded = jsonDecode(talkFeaturesJson);
  if (decoded is! List<Object?>) {
    return const <String>{};
  }
  return decoded.whereType<String>().toSet();
}

DateTime? _instant(int? millis) {
  return millis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}

/// Diagnostics of exactly one account. Recomputed on every visit; nothing here
/// is cached, so what the screen shows is the state on disk right now.
final localDiagnosticsProvider = FutureProvider.autoDispose
    .family<LocalDiagnostics, String>((ref, accountId) {
      return LocalDiagnosticsLoader(
        database: ref.watch(appDatabaseProvider),
        accounts: ref.watch(accountRepositoryProvider),
        push: ref.watch(androidWebPushPlatformProvider),
      ).load(accountId);
    });
