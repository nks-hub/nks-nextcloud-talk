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

/// Application version as declared in `apps/mobile/pubspec.yaml`.
///
/// The pubspec is the only source of truth for the shipped version — the
/// Windows installer script reads it straight from there — and Flutter has no
/// runtime lookup for it without an extra platform plugin. The value is
/// therefore mirrored here and `test/diagnostics_screen_test.dart` fails as
/// soon as the two drift apart.
///
/// Known limitation: a build that overrides `--build-name` or `--build-number`
/// on the command line still reports the pubspec value here.
const appVersionName = '0.1.0';

/// Build number part of the pubspec `version:` field. See [appVersionName].
const appBuildNumber = '1';

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

/// Why a push registration state could not be reported.
enum PushDiagnosticsGap { platformUnsupported, readFailed }

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

/// Local state of exactly one account, safe to read out over a support call.
///
/// Nothing here identifies the account or its content: no server, no login
/// name, no room tokens, no conversation names, no message text, no
/// credentials and no push subscription endpoint.
@immutable
final class LocalDiagnostics {
  const LocalDiagnostics({
    required this.operatingSystem,
    required this.schemaVersion,
    required this.conversationCount,
    required this.messageCount,
    required this.threadCount,
    required this.textOutbox,
    required this.attachmentOutbox,
    required this.push,
    required this.lastSyncedAt,
    required this.lastSyncError,
    required this.talkFeatureCount,
    required this.keyTalkFeatures,
  });

  final String operatingSystem;
  final int schemaVersion;
  final int conversationCount;
  final int messageCount;
  final int threadCount;
  final OutboxDiagnostics textOutbox;
  final OutboxDiagnostics attachmentOutbox;
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
  });

  final AppDatabase database;
  final AccountRepository accounts;
  final AndroidWebPushPlatform? push;

  Future<LocalDiagnostics> load(String accountId) async {
    final account = await accounts.getAccount(accountId);
    if (account == null) {
      throw StateError('Account $accountId is not stored locally');
    }
    final talkFeatures = _talkFeatures(account.talkFeaturesJson);
    return LocalDiagnostics(
      operatingSystem: '${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}',
      schemaVersion: database.schemaVersion,
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
      final state = TextSendOutboxState.values.asNameMap()[row.read(
        table.outboxState,
      )];
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
      final phase = AttachmentJobPhase.values.asNameMap()[row.read(
        table.phase,
      )];
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
