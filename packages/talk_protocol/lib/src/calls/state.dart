import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';
import 'response.dart';

enum CallLifecyclePhase {
  joining,
  joined,
  updating,
  leaving,
  uncertainJoin,
  uncertainUpdate,
  uncertainLeave,
}

final class CallLifecycleState {
  CallLifecycleState({
    required this.authority,
    required this.phase,
    required this.confirmedFlags,
    required this.requestedFlags,
    required this.endForEveryone,
    required this.mutationSequence,
    required DateTime updatedAt,
  }) : updatedAt = updatedAt.toUtc() {
    if (mutationSequence < 1 || !_isValidShape()) {
      protocolFailure(TalkProtocolErrorCode.invalidCallState, r'$.state');
    }
  }

  factory CallLifecycleState.beginJoin({
    required CallLifecycleAuthority authority,
    required CallInCallFlags flags,
    required DateTime updatedAt,
  }) => CallLifecycleState(
    authority: authority,
    phase: CallLifecyclePhase.joining,
    confirmedFlags: null,
    requestedFlags: flags,
    endForEveryone: null,
    mutationSequence: 1,
    updatedAt: updatedAt,
  );

  final CallLifecycleAuthority authority;
  final CallLifecyclePhase phase;
  final CallInCallFlags? confirmedFlags;
  final CallInCallFlags? requestedFlags;
  final bool? endForEveryone;
  final int mutationSequence;
  final DateTime updatedAt;

  CallLifecycleState confirm({required DateTime updatedAt}) {
    final flags = switch (phase) {
      CallLifecyclePhase.joining ||
      CallLifecyclePhase.uncertainJoin => requestedFlags,
      CallLifecyclePhase.updating => requestedFlags,
      _ => null,
    };
    if (flags == null) {
      protocolFailure(TalkProtocolErrorCode.invalidCallState, r'$.phase');
    }
    return CallLifecycleState(
      authority: authority,
      phase: CallLifecyclePhase.joined,
      confirmedFlags: flags,
      requestedFlags: null,
      endForEveryone: null,
      mutationSequence: mutationSequence,
      updatedAt: updatedAt,
    );
  }

  CallLifecycleState beginUpdate({
    required CallInCallFlags flags,
    required DateTime updatedAt,
  }) {
    if (phase != CallLifecyclePhase.joined) {
      protocolFailure(TalkProtocolErrorCode.invalidCallState, r'$.phase');
    }
    return CallLifecycleState(
      authority: authority,
      phase: CallLifecyclePhase.updating,
      confirmedFlags: confirmedFlags,
      requestedFlags: flags,
      endForEveryone: null,
      mutationSequence: mutationSequence + 1,
      updatedAt: updatedAt,
    );
  }

  CallLifecycleState beginLeave({
    required bool endForEveryone,
    required DateTime updatedAt,
  }) {
    if (phase != CallLifecyclePhase.joined &&
        phase != CallLifecyclePhase.uncertainUpdate) {
      protocolFailure(TalkProtocolErrorCode.invalidCallState, r'$.phase');
    }
    return CallLifecycleState(
      authority: authority,
      phase: CallLifecyclePhase.leaving,
      confirmedFlags: confirmedFlags,
      requestedFlags: null,
      endForEveryone: endForEveryone,
      mutationSequence: mutationSequence + 1,
      updatedAt: updatedAt,
    );
  }

  CallLifecycleState markUncertain({required DateTime updatedAt}) {
    final nextPhase = switch (phase) {
      CallLifecyclePhase.joining => CallLifecyclePhase.uncertainJoin,
      CallLifecyclePhase.updating => CallLifecyclePhase.uncertainUpdate,
      CallLifecyclePhase.leaving => CallLifecyclePhase.uncertainLeave,
      CallLifecyclePhase.uncertainJoin ||
      CallLifecyclePhase.uncertainUpdate ||
      CallLifecyclePhase.uncertainLeave => phase,
      CallLifecyclePhase.joined => protocolFailure(
        TalkProtocolErrorCode.invalidCallState,
        r'$.phase',
      ),
    };
    return _copy(phase: nextPhase, updatedAt: updatedAt);
  }

  /// A persisted in-flight mutation is ambiguous after process death even if
  /// no transport exception was recorded before the process stopped.
  CallLifecycleState afterRestart({required DateTime updatedAt}) =>
      switch (phase) {
        CallLifecyclePhase.joining ||
        CallLifecyclePhase.updating ||
        CallLifecyclePhase.leaving => markUncertain(updatedAt: updatedAt),
        _ => this,
      };

  CallLifecycleState _copy({
    required CallLifecyclePhase phase,
    required DateTime updatedAt,
  }) => CallLifecycleState(
    authority: authority,
    phase: phase,
    confirmedFlags: confirmedFlags,
    requestedFlags: requestedFlags,
    endForEveryone: endForEveryone,
    mutationSequence: mutationSequence,
    updatedAt: updatedAt,
  );

  bool _isValidShape() => switch (phase) {
    CallLifecyclePhase.joining || CallLifecyclePhase.uncertainJoin =>
      confirmedFlags == null &&
          requestedFlags != null &&
          endForEveryone == null,
    CallLifecyclePhase.joined =>
      confirmedFlags != null &&
          requestedFlags == null &&
          endForEveryone == null,
    CallLifecyclePhase.updating || CallLifecyclePhase.uncertainUpdate =>
      confirmedFlags != null &&
          requestedFlags != null &&
          endForEveryone == null,
    CallLifecyclePhase.leaving || CallLifecyclePhase.uncertainLeave =>
      confirmedFlags != null &&
          requestedFlags == null &&
          endForEveryone != null,
  };

  @override
  String toString() =>
      'CallLifecycleState(phase: ${phase.name}, '
      'mutationSequence: $mutationSequence, sensitive: <redacted>)';
}

enum CallRecoveryAction {
  joinedConfirmed,
  deleteLocalState,
  retryLeave,
  stillUncertain,
}

final class CallRecoveryDecision {
  const CallRecoveryDecision({required this.action, required this.state});

  final CallRecoveryAction action;
  final CallLifecycleState? state;
}

CallRecoveryDecision reconcileCallLifecycle({
  required CallLifecycleState state,
  required CallRestResponse peersResponse,
  required DateTime observedAt,
}) {
  if (peersResponse.request.authority.matches(state.authority) == false ||
      peersResponse.classification != CallResponseClassification.confirmed ||
      peersResponse.request is! CallPeersRequest) {
    protocolFailure(TalkProtocolErrorCode.invalidCallState, r'$.response');
  }
  final present = peersResponse.ownSessionPresent;
  return switch (state.phase) {
    CallLifecyclePhase.joining || CallLifecyclePhase.uncertainJoin =>
      present
          ? CallRecoveryDecision(
              action: CallRecoveryAction.joinedConfirmed,
              state: state.confirm(updatedAt: observedAt),
            )
          : const CallRecoveryDecision(
              action: CallRecoveryAction.deleteLocalState,
              state: null,
            ),
    CallLifecyclePhase.joined =>
      present
          ? CallRecoveryDecision(
              action: CallRecoveryAction.joinedConfirmed,
              state: state,
            )
          : const CallRecoveryDecision(
              action: CallRecoveryAction.deleteLocalState,
              state: null,
            ),
    CallLifecyclePhase.updating || CallLifecyclePhase.uncertainUpdate =>
      present
          ? CallRecoveryDecision(
              action: CallRecoveryAction.stillUncertain,
              state: state.phase == CallLifecyclePhase.uncertainUpdate
                  ? state
                  : state.markUncertain(updatedAt: observedAt),
            )
          : const CallRecoveryDecision(
              action: CallRecoveryAction.deleteLocalState,
              state: null,
            ),
    CallLifecyclePhase.leaving || CallLifecyclePhase.uncertainLeave =>
      present
          ? CallRecoveryDecision(
              action: CallRecoveryAction.retryLeave,
              state: state.phase == CallLifecyclePhase.uncertainLeave
                  ? state
                  : state.markUncertain(updatedAt: observedAt),
            )
          : const CallRecoveryDecision(
              action: CallRecoveryAction.deleteLocalState,
              state: null,
            ),
  };
}
