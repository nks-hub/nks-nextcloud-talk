// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum ConversationSyncError {
  accountMissing,
  credentialMissing,
  talkUnavailable,
  conversationProfileUnsupported,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
  upgradeRequired,
  invalidResponse,
  network,
}

final class ConversationSyncException implements Exception {
  const ConversationSyncException(this.code);

  final ConversationSyncError code;

  @override
  String toString() => 'ConversationSyncException(${code.name})';
}

final class ConversationSyncService {
  ConversationSyncService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid? uuid,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _uuid = uuid ?? const Uuid();

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;
  final Map<String, _ConversationSyncFlight> _inFlight = {};

  Future<void> sync(
    String accountId, {
    Future<void>? abortTrigger,
    bool forceFull = false,
  }) async {
    while (true) {
      final flight =
          _inFlight[accountId] ?? _startFlight(accountId, forceFull: forceFull);
      final satisfiesRequestedMode = !forceFull || flight.forceFull;
      final waiter = flight.tryWait(abortTrigger);
      if (waiter != null) {
        if (satisfiesRequestedMode) {
          await waiter;
          return;
        }

        try {
          if (!await waiter) {
            return;
          }
        } on ConversationSyncException {
          // A weaker flight cannot satisfy or fail the requested full refresh.
        }

        if (identical(_inFlight[accountId], flight)) {
          _inFlight.remove(accountId);
        }
        continue;
      }

      final shouldRetry = await _waitForClosedFlight(flight, abortTrigger);
      if (!shouldRetry) {
        return;
      }
    }
  }

  _ConversationSyncFlight _startFlight(
    String accountId, {
    required bool forceFull,
  }) {
    final flight = _ConversationSyncFlight(forceFull: forceFull);
    _inFlight[accountId] = flight;
    flight.start(
      _sync(
        accountId,
        abortTrigger: flight.transportCancellation,
        forceFull: forceFull,
      ),
    );

    void removeCompletedFlight() {
      if (identical(_inFlight[accountId], flight)) {
        _inFlight.remove(accountId);
      }
    }

    unawaited(
      flight.done.then<void>(
        (_) => removeCompletedFlight(),
        onError: (Object _, StackTrace _) => removeCompletedFlight(),
      ),
    );
    return flight;
  }

  Future<bool> _waitForClosedFlight(
    _ConversationSyncFlight flight,
    Future<void>? abortTrigger,
  ) async {
    final closed = flight.done.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    if (abortTrigger == null) {
      await closed;
      return true;
    }

    var cancelled = false;
    final callerCancellation = abortTrigger.then<void>(
      (_) => cancelled = true,
      onError: (Object _, StackTrace _) => cancelled = true,
    );
    await Future.any<void>([closed, callerCancellation]);
    return !cancelled;
  }

  Future<void> _sync(
    String accountId, {
    Future<void>? abortTrigger,
    required bool forceFull,
  }) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const ConversationSyncException(
        ConversationSyncError.accountMissing,
      );
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      await _fail(accountId, ConversationSyncError.credentialMissing);
    }

    try {
      final server = ServerBase.parse(account.serverUrl);
      final capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
        abortTrigger: abortTrigger,
      );
      if (!capabilities.hasTalk) {
        await _fail(accountId, ConversationSyncError.talkUnavailable);
      }
      if (!capabilities.supportsTalk('conversation-v4')) {
        await _fail(
          accountId,
          ConversationSyncError.conversationProfileUnsupported,
        );
      }
      await _accounts.updateTalkFeatures(accountId, capabilities.talkFeatures);

      var currentAccount = account;
      for (var attempt = 0; attempt < 2; attempt++) {
        final state = await _accounts.loadConversationState(currentAccount);
        final typedAccountId = AccountId.parse(accountId);
        final mode = forceFull || state.cursor == null
            ? ConversationFetchMode.full
            : ConversationFetchMode.incremental;
        final request = ConversationListRequest(
          accountId: typedAccountId,
          requestId: ConversationRequestId.parse(_uuid.v4()),
          server: server,
          mode: mode,
          includeLastMessage: true,
          includeStatus: true,
          cursor: mode == ConversationFetchMode.incremental
              ? state.cursor
              : null,
        );
        final response = await _api.getConversations(
          conversationRequest: request,
          loginName: account.loginName,
          appPassword: appPassword,
          abortTrigger: abortTrigger,
        );
        if (response case ConversationListSuccess()) {
          final snapshot = ConversationSnapshot(
            accounts: {typedAccountId: state},
          );
          final plan = const ConversationMergePlanner().plan(
            snapshot: snapshot,
            response: response,
            observedAt: DateTime.now().toUtc(),
          );
          await _accounts.applyConversationMerge(plan);
          if (plan.outcome == ConversationMergeOutcome.applied) {
            return;
          }
          currentAccount = (await _accounts.getAccount(accountId))!;
          continue;
        }
        await _fail(accountId, _classifyResponse(response));
      }
      await _fail(accountId, ConversationSyncError.invalidResponse);
    } on ConversationSyncException {
      rethrow;
    } on NextcloudApiException catch (error) {
      if (error.code == NextcloudApiError.cancelled) {
        return;
      }
      await _fail(accountId, _classifyApiException(error));
    } on TalkProtocolException catch (error) {
      if (kDebugMode) {
        debugPrint(
          'Conversation sync rejected: ${error.code.name} at ${error.path}',
        );
      }
      await _fail(accountId, ConversationSyncError.invalidResponse);
    }
  }

  ConversationSyncError _classifyResponse(ConversationListResponse response) {
    return switch (response) {
      ConversationReauthenticationRequired() =>
        ConversationSyncError.reauthenticationRequired,
      ConversationOcsFailure() => ConversationSyncError.invalidResponse,
      ConversationHttpFailure(:final kind) => switch (kind) {
        ConversationHttpFailureKind.upgradeRequired =>
          ConversationSyncError.upgradeRequired,
        ConversationHttpFailureKind.rateLimited =>
          ConversationSyncError.rateLimited,
        ConversationHttpFailureKind.serviceUnavailable =>
          ConversationSyncError.serviceUnavailable,
      },
      ConversationListSuccess() => ConversationSyncError.invalidResponse,
    };
  }

  ConversationSyncError _classifyApiException(NextcloudApiException error) {
    return switch (error.statusCode) {
      401 => ConversationSyncError.reauthenticationRequired,
      426 => ConversationSyncError.upgradeRequired,
      429 => ConversationSyncError.rateLimited,
      500 || 502 || 503 || 504 => ConversationSyncError.serviceUnavailable,
      _ => ConversationSyncError.network,
    };
  }

  Future<Never> _fail(String accountId, ConversationSyncError error) async {
    await _accounts.recordSyncError(accountId, error.name);
    throw ConversationSyncException(error);
  }
}

/// Owns one account-scoped transport while callers keep independent lifetimes.
/// The transport is aborted only after the final attached waiter cancels.
final class _ConversationSyncFlight {
  _ConversationSyncFlight({required this.forceFull});

  final bool forceFull;
  final Completer<void> _transportCancellation = Completer<void>();
  late final Future<void> done;
  var _acceptingWaiters = true;
  var _waiterCount = 0;

  Future<void> get transportCancellation => _transportCancellation.future;

  void start(Future<void> task) {
    done = task;
  }

  Future<bool>? tryWait(Future<void>? waiterCancellation) {
    if (!_acceptingWaiters) {
      return null;
    }
    _waiterCount++;
    return _wait(waiterCancellation);
  }

  Future<bool> _wait(Future<void>? waiterCancellation) async {
    var cancelled = false;
    try {
      if (waiterCancellation == null) {
        await done;
        return true;
      }

      final cancellation = waiterCancellation.then<void>(
        (_) => cancelled = true,
        onError: (Object _, StackTrace _) => cancelled = true,
      );
      await Future.any<void>([done, cancellation]);
      return !cancelled;
    } finally {
      _waiterCount--;
      if (cancelled && _waiterCount == 0 && _acceptingWaiters) {
        _acceptingWaiters = false;
        if (!_transportCancellation.isCompleted) {
          _transportCancellation.complete();
        }
      }
    }
  }
}
