part of 'call_lifecycle_service.dart';

extension _CallLifecycleMutations on CallLifecycleService {
  Future<CallLifecycleState> _updateFlagsActive(
    _CallContext context,
    CallInCallFlags flags,
  ) async {
    var stable = await _sessions.load(authority: context.authority);
    if (stable == null) {
      throw const CallLifecycleException(CallLifecycleError.notJoined);
    }
    if (stable.phase != CallLifecyclePhase.joined) {
      stable = await _recoverPrepared(context, stable);
    }
    if (stable == null) {
      throw const CallLifecycleException(CallLifecycleError.notJoined);
    }
    if (stable.phase != CallLifecyclePhase.joined) {
      throw const CallLifecycleException(CallLifecycleError.uncertain);
    }

    var state = stable.beginUpdate(flags: flags, updatedAt: _utcNow());
    await _sessions.persist(state);
    final request = UpdateCallFlagsRequest(
      context: CallRequestContext(
        authority: state.authority,
        mutationSequence: state.mutationSequence,
      ),
      flags: flags,
    );
    final response = await _mutate(
      state: state,
      send: () => _api.updateCallFlags(
        updateRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    switch (response.classification) {
      case CallResponseClassification.confirmed:
        state = state.confirm(updatedAt: _utcNow());
        await _sessions.persist(state);
        return state;
      case CallResponseClassification.serverFailure:
        await _markUncertain(state);
      case CallResponseClassification.reauthenticationRequired:
        await _dropForReauthentication(
          context.authority.accountId.value,
          context.authority.roomToken.value,
        );
      case CallResponseClassification.sessionMissing:
        await _sessions.delete(
          accountId: context.authority.accountId.value,
          roomToken: context.authority.roomToken.value,
        );
        throw const CallLifecycleException(CallLifecycleError.notJoined);
      case CallResponseClassification.rejected:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.rejected);
      case CallResponseClassification.forbidden:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.forbidden);
      case CallResponseClassification.conflict:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.conflict);
      case CallResponseClassification.rateLimited:
        await _sessions.persist(stable);
        throw const CallLifecycleException(CallLifecycleError.rateLimited);
    }
  }
}
