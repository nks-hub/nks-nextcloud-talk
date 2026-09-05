part of 'nextcloud_api.dart';

const _activeRoomSessionMaximumBytes = 1024 * 1024;

mixin _NextcloudApiActiveRoom on _HttpNextcloudApiBase {
  Future<void> shutdownAccountSession({
    required String accountId,
    required String loginName,
    required String appPassword,
  }) {
    final parsed = _suspendAccountSession(accountId);
    return _serializeAccountSession(parsed, () async {
      final lease = _activeRoomSessions[parsed];
      if (lease != null) {
        // A shutdown is not a holder letting go of its share; it ends the
        // session for everyone, so the count is dropped before the release.
        _activeRoomSessionHolders.remove(parsed);
        await _releaseRoomSession(
          lease: lease,
          loginName: loginName,
          appPassword: appPassword,
        );
      }
      _forgetRoomSession(parsed);
      _accountCookies.clear(parsed);
    });
  }

  Future<ActiveRoomSessionActivation> activateRoomSession({
    required ActiveRoomSessionRequest activeRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _serializeAccountSession(activeRequest.accountId, () async {
    if (_roomSessionBlocked(activeRequest.accountId)) {
      throw const NextcloudApiException(NextcloudApiError.cancelled);
    }
    final previous = _activeRoomSessions[activeRequest.accountId];
    final held = _activeRoomSessionRooms[activeRequest.accountId];
    if (previous != null &&
        held != null &&
        previous.roomToken.value == activeRequest.roomToken.value &&
        previous.server.uri == activeRequest.server.uri) {
      // Already holding exactly what was asked for. Join it instead of
      // replacing it: the replacement would invalidate the session id every
      // current holder is already using.
      _activeRoomSessionHolders[activeRequest.accountId] =
          (_activeRoomSessionHolders[activeRequest.accountId] ?? 1) + 1;
      return ActiveRoomSessionActivation(response: held, lease: previous);
    }
    if (previous != null) {
      await _releaseRoomSession(
        lease: previous,
        loginName: loginName,
        appPassword: appPassword,
      );
    }
    final lease = _newRoomSessionLease(activeRequest);
    final request = _request('POST', activeRequest.uri, abortTrigger)
      ..headers.addAll({
        ...activeRequest.headers,
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    try {
      final payload = await _sendBody(
        request,
        allowedStatusCodes: const {200, 400, 401, 403, 404, 409, 429, 503},
        maximumBytes: _activeRoomSessionMaximumBytes,
        sessionAccountId: activeRequest.accountId,
        sessionServer: activeRequest.server,
        cleanupCookieLease: lease,
      );
      final response = decodeActiveRoomSessionResponse(
        statusCode: payload.statusCode,
        body: payload.body,
      );
      if (_roomSessionBlocked(activeRequest.accountId)) {
        await _releaseRoomSession(
          lease: lease,
          loginName: loginName,
          appPassword: appPassword,
        );
        throw const NextcloudApiException(NextcloudApiError.cancelled);
      }
      if (response is ActiveRoomSessionSuccess) {
        if (_ownsRoomSession(lease)) {
          _activeRoomSessionRooms[lease.accountId] = response;
          _activeRoomSessionHolders[lease.accountId] = 1;
        }
        return ActiveRoomSessionActivation(response: response, lease: lease);
      }
      if (_ownsRoomSession(lease)) {
        _forgetRoomSession(lease.accountId);
        _accountCookies.clear(lease.accountId);
      }
      return ActiveRoomSessionActivation(response: response);
    } on Object {
      await _releaseRoomSession(
        lease: lease,
        loginName: loginName,
        appPassword: appPassword,
      );
      rethrow;
    }
  });

  Future<void> deactivateRoomSession({
    required ActiveRoomSessionLease lease,
    required String loginName,
    required String appPassword,
  }) => _serializeAccountSession(lease.accountId, () async {
    await _deactivateRoomSessionOwned(
      lease: lease,
      loginName: loginName,
      appPassword: appPassword,
    );
  });

  /// One holder letting go. The session outlives every release but the last.
  Future<void> _deactivateRoomSessionOwned({
    required ActiveRoomSessionLease lease,
    required String loginName,
    required String appPassword,
  }) async {
    if (!_ownsRoomSession(lease)) return;
    final holders = _activeRoomSessionHolders[lease.accountId] ?? 1;
    if (holders > 1) {
      _activeRoomSessionHolders[lease.accountId] = holders - 1;
      return;
    }
    await _releaseRoomSession(
      lease: lease,
      loginName: loginName,
      appPassword: appPassword,
    );
  }

  void _forgetRoomSession(AccountId accountId) {
    _activeRoomSessions.remove(accountId);
    _activeRoomSessionRooms.remove(accountId);
    _activeRoomSessionHolders.remove(accountId);
  }

  /// Ends the session outright, whoever else still holds it.
  Future<void> _releaseRoomSession({
    required ActiveRoomSessionLease lease,
    required String loginName,
    required String appPassword,
  }) async {
    if (!_ownsRoomSession(lease)) return;
    try {
      final request = ActiveRoomSessionRequest(
        accountId: lease.accountId,
        server: lease.server,
        roomToken: lease.roomToken,
      );
      final transport = _request('DELETE', request.uri, null)
        ..headers.addAll({
          ...request.headers,
          'Authorization': _basicAuthorization(loginName, appPassword),
        });
      await _sendBody(
        transport,
        allowedStatusCodes: const {200, 401, 404},
        maximumBytes: _activeRoomSessionMaximumBytes,
        timeout: const Duration(seconds: 20),
        sessionAccountId: lease.accountId,
        sessionServer: lease.server,
        allowAfterClose: true,
      );
    } finally {
      if (_ownsRoomSession(lease)) {
        _forgetRoomSession(lease.accountId);
        _accountCookies.clear(lease.accountId);
      }
    }
  }
}
