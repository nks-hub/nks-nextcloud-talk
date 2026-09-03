// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../core/performance_telemetry.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
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

  /// Whether the same call is worth making again shortly.
  ///
  /// These are conditions of the moment - no route to the server, the server
  /// pushing back - not something the caller did wrong. A wake-up sync hits
  /// them routinely, because the radio is still settling when the push
  /// arrives, so they must not be treated as failures worth crashing over.
  bool get isTransient => switch (code) {
    ConversationSyncError.network ||
    ConversationSyncError.rateLimited ||
    ConversationSyncError.serviceUnavailable => true,
    _ => false,
  };

  @override
  String toString() => 'ConversationSyncException(${code.name})';
}

/// Told once, when a sync first finds the account's credential rejected.
///
/// A rejected credential is also how a server-ordered wipe reaches a device,
/// so somebody has to ask which of the two it is; the sync itself only reports
/// that the moment happened.
typedef AuthenticationLostCallback = Future<void> Function(String accountId);

final class ConversationSyncService {
  ConversationSyncService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    AuthenticationLostCallback? onAuthenticationLost,
    Uuid? uuid,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
    FederationInviteCounter? federationInvites,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _onAuthenticationLost = onAuthenticationLost,
       _uuid = uuid ?? const Uuid(),
       _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now,
       _federationInvites = federationInvites ?? FederationInviteCounter();

  /// How long the loop may stay incremental before it asks for the whole
  /// list again. The delta only carries rooms that changed; a room deleted
  /// on the server, or one the account was removed from, is simply absent
  /// from it and would sit in the list until the next start or manual
  /// refresh. A full fetch every few minutes is what lets it go.
  static const Duration fullRefreshInterval = Duration(minutes: 5);

  final Future<void> Function(Duration) _delay;
  final DateTime Function() _clock;
  final Map<String, DateTime> _lastFullFetch = <String, DateTime>{};
  final FederationInviteCounter _federationInvites;
  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final AuthenticationLostCallback? _onAuthenticationLost;
  final Uuid _uuid;
  final Map<String, _ConversationSyncFlight> _inFlight = {};

  Future<void> sync(
    String accountId, {
    Future<void>? abortTrigger,
    bool forceFull = false,
  }) async {
    final started = DateTime.now();
    // The outcome is decided on every exit, including the failures raised
    // deeper in the flight rather than by the transport here. Recording only
    // in the catch below would have measured the successful syncs and the
    // transport errors while silently dropping every classified failure.
    var outcome = TracedOutcome.completed;
    try {
      await _syncFlights(
        accountId,
        abortTrigger: abortTrigger,
        forceFull: forceFull,
      );
    } on NextcloudApiException catch (error) {
      if (error.code == NextcloudApiError.cancelled) {
        // An abandoned sync is not a slow one; reported apart so a user who
        // closes the app mid-sync does not look like a failing server.
        outcome = TracedOutcome.cancelled;
        return;
      }
      outcome = TracedOutcome.failed;
      await _fail(accountId, _classifyApiException(error));
    } on Object {
      outcome = TracedOutcome.failed;
      rethrow;
    } finally {
      performanceTelemetry.record(
        operation: TracedOperation.conversationSync,
        started: started,
        outcome: outcome,
      );
    }
  }

  Future<void> _syncFlights(
    String accountId, {
    required Future<void>? abortTrigger,
    required bool forceFull,
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
        } on NextcloudApiException {
          // A transport failure from the weaker flight has the same ownership.
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
    if (account.lastSyncError ==
            ConversationSyncError.reauthenticationRequired.name &&
        !await _reauthenticationCleared(account)) {
      throw const ConversationSyncException(
        ConversationSyncError.reauthenticationRequired,
      );
    }
    String? appPassword;
    // Secure storage answers null for "not stored" but also, briefly, right
    // after a cold start while the keystore is not ready. One such null used
    // to be recorded as a missing credential and the shell stopped syncing
    // until the user logged in again (Android 14 build 49, account intact on
    // the server). A handful of re-reads separates the two.
    for (var attempt = 0; attempt < _credentialReadAttempts; attempt++) {
      try {
        appPassword = await _credentials.readAppPassword(accountId);
      } on CredentialVaultTemporarilyUnavailable {
        throw const ConversationSyncException(ConversationSyncError.network);
      }
      if (appPassword != null) {
        break;
      }
      // Only an account that has synced before earns the re-reads: a null
      // for one that never had a credential is the plain answer.
      if (account.lastSyncedAtMillis == null) {
        break;
      }
      if (attempt + 1 < _credentialReadAttempts) {
        await _delay(_credentialReadRetryDelay);
      }
    }
    if (appPassword == null) {
      await _fail(accountId, ConversationSyncError.credentialMissing);
    }
    _flightPasswords[accountId] = appPassword;

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
      await _accounts.updateCapabilities(
        accountId,
        capabilities.talkFeatures,
        serverThemeColor: capabilities.serverThemeColor,
      );

      var currentAccount = account;
      for (var attempt = 0; attempt < 2; attempt++) {
        final state = await _accounts.loadConversationState(currentAccount);
        final typedAccountId = AccountId.parse(accountId);
        final lastFull = _lastFullFetch[accountId];
        final now = _clock();
        final mode =
            forceFull ||
                state.cursor == null ||
                lastFull == null ||
                now.difference(lastFull) >= fullRefreshInterval
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
          _recordFederationInvites(accountId, response.federationInvites);
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
            if (mode == ConversationFetchMode.full) {
              _lastFullFetch[accountId] = now;
            }
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

  static const _credentialReadAttempts = 3;
  static const _reauthenticationConfirmDelay = Duration(seconds: 2);
  static const _credentialReadRetryDelay = Duration(milliseconds: 400);

  /// Credential each in-flight sync authenticated with. A 401 that comes back
  /// for a password the user has since replaced belongs to the old login, not
  /// to the new one, and must not push the account back into re-login.
  final Map<String, String> _flightPasswords = <String, String>{};

  void _recordFederationInvites(String accountId, ConversationCursor? raw) {
    _federationInvites.record(
      accountId,
      raw == null ? 0 : (int.tryParse(raw.value) ?? 0),
    );
  }

  Future<Never> _fail(String accountId, ConversationSyncError error) async {
    if (error == ConversationSyncError.reauthenticationRequired &&
        (await _isStaleCredentialFailure(accountId) ||
            await _isTransient401(accountId))) {
      throw const ConversationSyncException(ConversationSyncError.network);
    }
    await _accounts.recordSyncError(accountId, error.name);
    if (error == ConversationSyncError.reauthenticationRequired) {
      // Best effort and never allowed to change the failure the caller sees:
      // whatever the check decides, this sync still failed to authenticate.
      try {
        await _onAuthenticationLost?.call(accountId);
      } on Object {
        // Deliberately swallowed; the sync error below is the answer.
      }
    }
    throw ConversationSyncException(error);
  }

  /// An account parked in re-login by a 401 the server later took back
  /// (see [_isTransient401]) gets one authenticated probe per sync attempt.
  /// If the stored token works again the row is released and this sync goes
  /// on as usual, so nobody has to log in again for a server hiccup.
  Future<bool> _reauthenticationCleared(StoredAccount account) async {
    final String? appPassword;
    try {
      appPassword = await _credentials.readAppPassword(account.id);
    } on Object {
      return false;
    }
    if (appPassword == null) {
      return false;
    }
    try {
      await _api.getAuthenticatedCapabilitiesWithSource(
        server: ServerBase.parse(account.serverUrl),
        loginName: account.loginName,
        appPassword: appPassword,
        forceRefresh: true,
      );
    } on Object {
      return false;
    }
    await _accounts.clearSyncError(account.id);
    return true;
  }

  /// The reference server answered 401 for a token it accepted seconds later
  /// (2. 9. 2026, 23:54–23:59, three clients at once, token never revoked).
  /// One 401 therefore is not proof the login is gone: it is confirmed with a
  /// fresh authenticated read after a pause, and only a second 401 signs the
  /// account out. Anything else — including a network error — is retried.
  Future<bool> _isTransient401(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    final appPassword = _flightPasswords[accountId];
    if (account == null || appPassword == null) {
      return false;
    }
    await _delay(_reauthenticationConfirmDelay);
    try {
      await _api.getAuthenticatedCapabilitiesWithSource(
        server: ServerBase.parse(account.serverUrl),
        loginName: account.loginName,
        appPassword: appPassword,
        forceRefresh: true,
      );
      return true;
    } on NextcloudApiException catch (error) {
      return error.statusCode != 401;
    } on Object {
      return true;
    }
  }

  Future<bool> _isStaleCredentialFailure(String accountId) async {
    final used = _flightPasswords[accountId];
    if (used == null) {
      return false;
    }
    try {
      final current = await _credentials.readAppPassword(accountId);
      return current != null && current != used;
    } on Object {
      return false;
    }
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

/// Pending federated invitation count per account, as the room list's
/// `X-Nextcloud-Talk-Federation-Invites` header last reported it.
///
/// Lives outside the sync service so the invitation strip can watch the
/// count without pulling the database and credentials behind the service in;
/// an account whose count is zero costs nothing more than a map lookup.
final class FederationInviteCounter {
  final Map<String, int> _counts = <String, int>{};
  final StreamController<String> _changed =
      StreamController<String>.broadcast();

  /// Account ids whose count just changed.
  Stream<String> get changed => _changed.stream;

  int pending(String accountId) => _counts[accountId] ?? 0;

  void record(String accountId, int count) {
    if (_counts[accountId] == count) {
      return;
    }
    _counts[accountId] = count;
    if (!_changed.isClosed) {
      _changed.add(accountId);
    }
  }
}
