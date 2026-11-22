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

  Future<void> _retireFailedBrowserCredential(
    AppPasswordRevocationReservation reservation,
    LoginFlowCredentials credential,
  ) async {
    final queue = _pendingRevocations!;
    try {
      if (await queue.browserCredentialIsOwned(
        credential,
        accounts: _accounts,
        credentials: _credentials,
      )) {
        await queue.releaseHeldCredential(reservation);
      } else {
        await queue.queueCredential(
          reservation: reservation,
          server: credential.server,
          loginName: credential.loginName,
          appPassword: credential.appPassword,
        );
      }
    } on Object {
      // The held entry can be reconciled after a storage or ownership failure.
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
      final LoginPollResult result;
      try {
        result = await _pollAndHoldBrowserCredential(
          pending,
          cancellation,
          reservation,
          deadline.difference(DateTime.now().toUtc()),
          onDetached,
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
      if (result case LoginPollSucceeded(:final credentials)) {
        return _commitAccount(
          server: pending.server,
          serverStatus: pending.serverStatus,
          loginCredentials: credentials,
          credentialSource: _CredentialSource.browser,
          cancellation: cancellation,
          expectedAccountId: expectedAccountId,
          cleanupReservation: reservation,
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

  Future<LoginPollResult> _pollAndHoldBrowserCredential(
    PendingLogin pending,
    CancellationSignal cancellation,
    AppPasswordRevocationReservation reservation,
    Duration remaining,
    VoidCallback onDetached,
  ) async {
    cancellation.throwIfCancelled();
    if (remaining <= Duration.zero) {
      throw const OnboardingFailure(OnboardingFailureCode.loginTimedOut);
    }
    final queue = _pendingRevocations!;
    final poll = _api.pollLogin(pending);
    Future<bool>? persistence;
    var detached = false;
    final ready = poll.then((result) async {
      if (result case LoginPollSucceeded(:final credentials) when !detached) {
        final hold = persistence = queue.holdBrowserCredential(
          reservation,
          credentials,
        );
        if (!await hold) {
          throw const OnboardingFailure(OnboardingFailureCode.localPersistence);
        }
      }
      return result;
    });

    final expiration = Completer<LoginPollResult>();
    final timer = Timer(remaining, () {
      expiration.completeError(
        const OnboardingFailure(OnboardingFailureCode.loginTimedOut),
      );
    });
    try {
      return await Future.any([
        ready,
        cancellation.whenCancelled.then<LoginPollResult>(
          (_) => throw const OnboardingCancelled(),
        ),
        expiration.future,
      ]);
    } on Object catch (error) {
      if (error is OnboardingCancelled ||
          (error is OnboardingFailure &&
              error.code == OnboardingFailureCode.loginTimedOut)) {
        detached = true;
        onDetached();
        unawaited(
          _settleCancelledBrowserPoll(queue, reservation, poll, persistence),
        );
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  Future<void> _settleCancelledBrowserPoll(
    AppPasswordRevocationQueue queue,
    AppPasswordRevocationReservation reservation,
    Future<LoginPollResult> poll,
    Future<bool>? persistence,
  ) async {
    try {
      if (await poll case LoginPollSucceeded(:final credentials)) {
        await queue.retireBrowserCredential(
          reservation,
          credentials,
          accounts: _accounts,
          credentials: _credentials,
          persistence: persistence,
        );
      }
    } on Object {
      // A held entry can be reconciled on the next wake.
    } finally {
      await queue.abandonHeldCredential(reservation);
    }
  }
}
