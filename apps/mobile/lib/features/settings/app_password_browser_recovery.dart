part of 'app_password_revocation_queue.dart';

extension BrowserLoginRecovery on AppPasswordRevocationQueue {
  /// A missing or expired flow cannot give the client a recoverable response.
  /// Removing that placeholder records no claim about the server password.
  Future<bool> recoverBrowserLogins({bool Function()? canPoll}) async {
    var recovered = false;
    for (final entry in (await _load()).whereType<_ReservationEntry>()) {
      final browser = entry.browser;
      final expired = _browserExpired(entry);
      if (browser != null && !expired && !(canPoll?.call() ?? false)) {
        continue;
      }
      final claim = await _tryClaim(entry.id);
      if (claim == null) continue;
      try {
        if (!(await _load()).any(entry.hasSameStateAs)) continue;
        if (browser == null || _browserExpired(entry)) {
          await releaseReservation(claim);
        } else if (canPoll?.call() ?? false) {
          final result = await _pollAbandonedLogin(browser);
          if (result case final password?) {
            await retireBrowserCredential(claim, password);
            recovered = true;
          }
        }
      } finally {
        await abandonHeldCredential(claim);
      }
    }
    return recovered;
  }

  bool _browserExpired(_ReservationEntry entry) =>
      !_now().isBefore(entry.since.add(const Duration(minutes: 20)));

  Future<LoginFlowCredentials?> _pollAbandonedLogin(
    _BrowserPoll browser,
  ) async {
    try {
      final c = browser.coordinates;
      final server = ServerBase.parse(c.server, policy: _api.originPolicy);
      final poll = LoginFlowPoll.parse(
        endpoint: c.endpoint,
        token: c.token,
        server: server,
        policy: _api.originPolicy,
      );
      final result = await _api.pollLoginCoordinates(server, poll);
      return switch (result) {
        LoginPollSucceeded(:final credentials) => credentials,
        _ => null,
      };
    } on NextcloudApiException {
      return null;
    } on TalkProtocolException {
      return null;
    }
  }

  /// Record the one-time result before releasing its exclusive claim. A held
  /// entry is recoverable if the subsequent account/vault lookup fails.
  Future<bool> holdBrowserCredential(
    AppPasswordRevocationReservation claim,
    LoginFlowCredentials credential, {
    Future<bool> Function()? revokeIfUnowned,
  }) async {
    var delay = const Duration(milliseconds: 50);
    var canTryRevocation = revokeIfUnowned != null;
    while (true) {
      try {
        var held = false;
        await _store.updatePendingRevocations((raw) {
          held = false;
          final entries = _decode(raw);
          final index = entries.indexWhere(
            (entry) => entry.reservationId == claim.id,
          );
          if (index < 0) return raw;
          final current = entries[index];
          if (current is! _ReservationEntry) {
            held =
                current is _HeldEntry &&
                current.hasSecret(
                  credential.server,
                  credential.loginName,
                  credential.appPassword,
                );
            return raw;
          }
          if (entries.any(
            (entry) => entry.hasSecret(
              credential.server,
              credential.loginName,
              credential.appPassword,
            ),
          )) {
            entries.removeAt(index);
          } else {
            entries[index] = _HeldEntry(
              id: claim.id,
              server: credential.server.value,
              loginName: credential.loginName,
              appPassword: credential.appPassword,
              since: current.since,
              phase: AppPasswordCredentialPhase.received,
              accountId: null,
            );
            held = true;
          }
          return _encode(entries);
        });
        return held;
      } on Object {
        if (canTryRevocation) {
          canTryRevocation = false;
          if (await revokeIfUnowned!()) {
            await _discardRevokedBrowserReservation(claim);
            return false;
          }
        }
        // The response cannot be fetched again. Keep its claim during retries.
        await Future<void>.delayed(delay);
        if (delay < const Duration(milliseconds: 800)) delay *= 2;
      }
    }
  }

  Future<void> retireBrowserCredential(
    AppPasswordRevocationReservation claim,
    LoginFlowCredentials credential, {
    AccountRepository? accounts,
    CredentialVault? credentials,
    Future<bool>? persistence,
  }) async {
    final accountRepository = accounts ?? _accounts;
    final vault = credentials ?? _credentials;
    final held =
        await (persistence ??
            holdBrowserCredential(
              claim,
              credential,
              revokeIfUnowned: accountRepository == null || vault == null
                  ? null
                  : () async {
                      try {
                        if (await browserCredentialIsOwned(
                          credential,
                          accounts: accountRepository,
                          credentials: vault,
                        )) {
                          return false;
                        }
                        await _api.revokeAppPassword(
                          server: credential.server,
                          loginName: credential.loginName,
                          appPassword: credential.appPassword,
                        );
                        return true;
                      } on NextcloudApiException catch (error) {
                        return error.statusCode == 401;
                      } on Object {
                        return false;
                      }
                    },
            ));
    if (!held || accountRepository == null || vault == null) return;
    for (final entry in (await _load()).whereType<_HeldEntry>()) {
      if (entry.id == claim.id) {
        await _recoverHeldCredential(entry, accountRepository, vault);
        return;
      }
    }
  }

  Future<bool> browserCredentialIsOwned(
    LoginFlowCredentials credential, {
    required AccountRepository accounts,
    required CredentialVault credentials,
  }) async {
    final account = await accounts.findByIdentity(
      serverUrl: credential.server.value,
      loginName: credential.loginName,
    );
    return account != null &&
        await credentials.readCurrentAppPassword(account.id) ==
            credential.appPassword;
  }

  Future<void> _discardRevokedBrowserReservation(
    AppPasswordRevocationReservation claim,
  ) async {
    var delay = const Duration(milliseconds: 50);
    while (true) {
      try {
        await releaseReservation(claim);
        return;
      } on Object {
        await Future<void>.delayed(delay);
        if (delay < const Duration(milliseconds: 800)) delay *= 2;
      }
    }
  }
}

final class _BrowserPoll {
  const _BrowserPoll(this.coordinates);

  factory _BrowserPoll.fromPending(PendingLogin pending) => _BrowserPoll((
    server: pending.server.value,
    endpoint: pending.initialization.pollEndpoint.toString(),
    token: pending.initialization.pollToken.value,
  ));

  final ({String server, String endpoint, String token}) coordinates;

  static _BrowserPoll? fromJson(Object? value) {
    if (value case {
      'server': final String server,
      'endpoint': final String endpoint,
      'token': final String token,
    }) {
      return _BrowserPoll((server: server, endpoint: endpoint, token: token));
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'server': coordinates.server,
    'endpoint': coordinates.endpoint,
    'token': coordinates.token,
  };
}
