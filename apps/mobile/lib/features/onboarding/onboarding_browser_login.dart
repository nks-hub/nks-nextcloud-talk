part of 'onboarding_coordinator.dart';

extension _OnboardingBrowserLogin on OnboardingCoordinator {
  Future<StoredAccount> _completeBrowserLogin(
    PendingLogin pending,
    CancellationSignal cancellation, {
    String? expectedAccountId,
    VoidCallback? onLoginPageOpened,
  }) async {
    AppPasswordRevocationReservation? reservation;
    var launchMayHaveOpened = false;
    var pollOwnsClaim = false;
    try {
      cancellation.throwIfCancelled();
      reservation = await _reserveGeneratedCredential(browser: pending);
      cancellation.throwIfCancelled();
      launchMayHaveOpened = true;
      final opened = await _launcher.open(pending.initialization.loginUri);
      if (!opened) {
        launchMayHaveOpened = false;
        throw const OnboardingFailure(OnboardingFailureCode.browserUnavailable);
      }
      cancellation.throwIfCancelled();
      onLoginPageOpened?.call();
      return await _pollForAccount(
        pending,
        cancellation,
        reservation: reservation,
        onDetached: () => pollOwnsClaim = true,
        expectedAccountId: expectedAccountId,
      );
    } on Object catch (error, stackTrace) {
      if (!launchMayHaveOpened && reservation != null) {
        await _releaseEmptyReservation(_pendingRevocations!, reservation);
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      await _closeLoginPage();
      if (reservation != null && !pollOwnsClaim) {
        await _pendingRevocations!.abandonHeldCredential(reservation);
      }
    }
  }

  Future<void> _closeLoginPage() async {
    try {
      await _launcher.close();
    } on Object {
      // The sheet may already be gone; that must not mask the login outcome.
    }
  }

  Future<StoredAccount> _pollForAccount(
    PendingLogin pending,
    CancellationSignal cancellation, {
    required AppPasswordRevocationReservation reservation,
    required VoidCallback onDetached,
    String? expectedAccountId,
  }) async {
    final deadline = DateTime.now().toUtc().add(loginTimeout);
    while (DateTime.now().toUtc().isBefore(deadline)) {
      cancellation.throwIfCancelled();
      if (_inBackground()) {
        await Future.any<void>([
          Future<void>.delayed(pollInterval),
          cancellation.whenCancelled,
        ]);
        continue;
      }
      final _ReservedOneShot<LoginPollResult> poll;
      try {
        poll = await _awaitReservedOneShot(
          operation: () => _api.pollLogin(pending),
          cancellation: cancellation,
          server: pending.server,
          reservation: reservation,
          releaseWhenEmpty: false,
          onBrowserDetached: onDetached,
          browserWait: deadline.difference(DateTime.now().toUtc()),
          credentialFrom: (result) {
            if (result case LoginPollSucceeded(:final credentials)) {
              return (
                loginName: credentials.loginName,
                appPassword: credentials.appPassword,
              );
            }
            return null;
          },
          provesNoCredential: (_) => false,
        );
      } on NextcloudApiException catch (error) {
        cancellation.throwIfCancelled();
        // iOS suspends the app's sockets while the browser is in front, so the
        // first polls after returning can fail on a connection that is fine.
        if (error.code != NextcloudApiError.network &&
            error.code != NextcloudApiError.timeout) {
          rethrow;
        }
        cancellation.throwIfCancelled();
        await Future.any<void>([
          Future<void>.delayed(pollInterval),
          cancellation.whenCancelled,
        ]);
        continue;
      }
      final result = poll.value;
      if (result case LoginPollSucceeded(:final credentials)) {
        return _commitAccount(
          server: pending.server,
          serverStatus: pending.serverStatus,
          loginCredentials: credentials,
          credentialSource: _CredentialSource.browser,
          cancellation: cancellation,
          expectedAccountId: expectedAccountId,
          cleanupReservation: poll.reservation,
        );
      }
      cancellation.throwIfCancelled();
      await Future.any<void>([
        Future<void>.delayed(pollInterval),
        cancellation.whenCancelled,
      ]);
    }
    cancellation.throwIfCancelled();
    throw const OnboardingFailure(OnboardingFailureCode.loginTimedOut);
  }

  Future<void> _settleCancelledBrowserPoll<T>(
    AppPasswordRevocationQueue queue,
    AppPasswordRevocationReservation reservation,
    Future<_OneShotOutcome<T>> outcome,
  ) async {
    try {
      if (await outcome case _OneShotValue<T>(:final value)) {
        if (value case LoginPollSucceeded(:final credentials)) {
          await queue.retireBrowserCredential(
            reservation,
            credentials,
            accounts: _accounts,
            credentials: _credentials,
          );
        }
      }
    } on Object {
      // Store the result before attempting account/vault reconciliation.
      // The held entry can be reconciled on the next wake.
    } finally {
      await queue.abandonHeldCredential(reservation);
    }
  }
}
