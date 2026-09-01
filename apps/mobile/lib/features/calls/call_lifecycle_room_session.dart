part of 'call_lifecycle_service.dart';

extension _CallLifecycleRoomSession on CallLifecycleService {
  _CallContext _reuseRoomSession(_CallContext context) {
    final held = _roomSessions[context.authority.accountId.value];
    return held != null && held.matches(context)
        ? context.withSession(held.sessionId)
        : context;
  }

  Future<_CallContext> _activateRoomSession(_CallContext context) async {
    final current = _roomSessions[context.authority.accountId.value];
    if (current != null && current.matches(context)) {
      return context.withSession(current.sessionId);
    }
    final accountId = context.authority.accountId.value;
    try {
      final activation = await _api.activateRoomSession(
        activeRequest: ActiveRoomSessionRequest(
          accountId: context.authority.accountId,
          server: context.authority.server,
          roomToken: context.authority.roomToken,
        ),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
      _roomSessions.remove(accountId);
      final response = activation.response;
      if (response is ActiveRoomSessionReauthenticationRequired) {
        await _dropForReauthentication(
          accountId,
          context.authority.roomToken.value,
        );
      }
      if (response is ActiveRoomSessionForbidden) {
        throw const CallLifecycleException(CallLifecycleError.forbidden);
      }
      if (response is ActiveRoomSessionMissing) {
        throw const CallLifecycleException(CallLifecycleError.roomMissing);
      }
      if (response is ActiveRoomSessionConflict) {
        throw const CallLifecycleException(CallLifecycleError.conflict);
      }
      if (response is ActiveRoomSessionHttpFailure) {
        throw const CallLifecycleException(
          CallLifecycleError.serviceUnavailable,
        );
      }
      final lease = activation.lease;
      if (response is! ActiveRoomSessionSuccess ||
          lease == null ||
          response.room.token != context.authority.roomToken ||
          response.room.sessionId.value == '0') {
        if (lease != null) {
          await _deactivateRoomSession(
            _CallRoomSession.fromContext(
              context,
              lease: lease,
              sessionId: response is ActiveRoomSessionSuccess
                  ? response.room.sessionId
                  : context.authority.nextcloudSessionId,
            ),
          );
        }
        throw const CallLifecycleException(CallLifecycleError.invalidResponse);
      }
      final held = _CallRoomSession.fromContext(
        context,
        lease: lease,
        sessionId: response.room.sessionId,
      );
      if (_disposed) {
        await _deactivateRoomSession(held);
        throw const CallLifecycleException(CallLifecycleError.network);
      }
      _roomSessions[accountId] = held;
      return context.withSession(held.sessionId);
    } on CallLifecycleException {
      rethrow;
    } on NextcloudApiException catch (error) {
      _roomSessions.remove(accountId);
      throw CallLifecycleException(_mapApiError(error));
    } on TalkProtocolException {
      _roomSessions.remove(accountId);
      throw const CallLifecycleException(CallLifecycleError.invalidResponse);
    }
  }

  Future<void> _releaseRoomSession(_CallContext context) async {
    final accountId = context.authority.accountId.value;
    final held = _roomSessions[accountId];
    if (held == null ||
        held.sessionId != context.authority.nextcloudSessionId) {
      return;
    }
    _roomSessions.remove(accountId);
    await _deactivateRoomSession(held);
  }

  Future<void> _releaseAccountRoomSession(String accountId) async {
    final held = _roomSessions.remove(accountId);
    if (held != null) await _deactivateRoomSession(held);
  }

  Future<void> _deactivateRoomSession(_CallRoomSession held) async {
    try {
      await _api.deactivateRoomSession(
        lease: held.lease,
        loginName: held.loginName,
        appPassword: held.appPassword,
      );
    } on Object {
      await _api.clearAccountSession(held.lease.accountId.value);
    }
  }
}

final class _CallRoomSession {
  const _CallRoomSession({
    required this.lease,
    required this.sessionId,
    required this.loginName,
    required this.appPassword,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.capabilityRevision,
  });

  factory _CallRoomSession.fromContext(
    _CallContext context, {
    required ActiveRoomSessionLease lease,
    required ConversationSessionId sessionId,
  }) => _CallRoomSession(
    lease: lease,
    sessionId: sessionId,
    loginName: context.account.loginName,
    appPassword: context.appPassword,
    credentialGeneration: context.authority.credentialGeneration,
    capabilityGeneration: context.authority.capabilityGeneration,
    capabilityRevision: context.authority.capabilityRevision,
  );

  final ActiveRoomSessionLease lease;
  final ConversationSessionId sessionId;
  final String loginName;
  final String appPassword;
  final int credentialGeneration;
  final int capabilityGeneration;
  final String capabilityRevision;

  bool matches(_CallContext context) =>
      lease.accountId == context.authority.accountId &&
      lease.server == context.authority.server &&
      lease.roomToken == context.authority.roomToken &&
      credentialGeneration == context.authority.credentialGeneration &&
      capabilityGeneration == context.authority.capabilityGeneration &&
      capabilityRevision == context.authority.capabilityRevision;
}

extension on _CallContext {
  _CallContext withSession(ConversationSessionId sessionId) => _CallContext(
    account: account,
    appPassword: appPassword,
    profile: profile,
    policy: policy,
    authority: CallLifecycleAuthority(
      accountId: authority.accountId,
      server: authority.server,
      roomToken: authority.roomToken,
      nextcloudSessionId: sessionId,
      credentialGeneration: authority.credentialGeneration,
      capabilityGeneration: authority.capabilityGeneration,
      capabilityRevision: authority.capabilityRevision,
    ),
  );
}
