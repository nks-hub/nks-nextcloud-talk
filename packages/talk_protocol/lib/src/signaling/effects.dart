import '../conversations/identifiers.dart';
import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'hpb.dart';
import 'identifiers.dart';
import 'models.dart';

enum SignalingDeadlineKind { welcome, reconnect, resumeExpiry, backoff }

enum HpbCloseReason { release, staleConnection, protocolFailure }

final class SignalingEffectContext {
  SignalingEffectContext({
    required this.accountId,
    required this.effectId,
    required this.server,
    required this.roomToken,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.settingsRevision,
    required this.connectionEpoch,
    required this.roomEpoch,
  }) {
    if (credentialGeneration < 1 ||
        capabilityGeneration < 1 ||
        settingsRevision.isEmpty ||
        settingsRevision.length > 128 ||
        connectionEpoch < 0 ||
        roomEpoch < 1) {
      _effectFailure(r'$.effect.context');
    }
  }

  final AccountId accountId;
  final SignalingEffectId effectId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int credentialGeneration;
  final int capabilityGeneration;
  final String settingsRevision;
  final int connectionEpoch;
  final int roomEpoch;

  @override
  String toString() =>
      'SignalingEffectContext(connectionEpoch: $connectionEpoch, '
      'roomEpoch: $roomEpoch, sensitive: <redacted>)';
}

sealed class SignalingEffect {
  const SignalingEffect({required this.context});

  final SignalingEffectContext context;

  @override
  String toString() =>
      'SignalingEffect(${runtimeType.toString()}, sensitive: <redacted>)';
}

final class OpenHpbSocketEffect extends SignalingEffect {
  OpenHpbSocketEffect({required super.context, required this.endpoint}) {
    _requireSocketEpoch(context, r'$.effect.open');
  }

  final HpbEndpoint endpoint;
}

final class SendHpbFrameEffect extends SignalingEffect {
  SendHpbFrameEffect({required super.context, required this.frame}) {
    _requireSocketEpoch(context, r'$.effect.send');
  }

  final HpbClientFrame frame;
}

final class CloseHpbSocketEffect extends SignalingEffect {
  CloseHpbSocketEffect({required super.context, required this.reason}) {
    _requireSocketEpoch(context, r'$.effect.close');
  }

  final HpbCloseReason reason;
}

final class ScheduleSignalingDeadlineEffect extends SignalingEffect {
  ScheduleSignalingDeadlineEffect({
    required super.context,
    required this.kind,
    required this.deadlineMicros,
  }) {
    if (deadlineMicros < 0 || context.connectionEpoch < 1) {
      _effectFailure(r'$.effect.deadlineMicros');
    }
  }

  final SignalingDeadlineKind kind;
  final int deadlineMicros;
}

final class RefreshConversationSessionEffect extends SignalingEffect {
  const RefreshConversationSessionEffect({required super.context});
}

void _requireSocketEpoch(SignalingEffectContext context, String path) {
  if (context.connectionEpoch < 1) {
    _effectFailure(path);
  }
}

Never _effectFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingState, path);
