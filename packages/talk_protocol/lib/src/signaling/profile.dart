import '../bootstrap/capabilities.dart';
import '../json_value.dart';
import '../protocol_exception.dart';

enum SignalingTransportKind { internal, externalHpb }

enum SignalingTopology { internalPeerToPeer, externalPeerToPeer, externalMcu }

final class SignalingCapabilityProfile {
  SignalingCapabilityProfile._({
    required this.enabled,
    required this.chatRelay,
  });

  factory SignalingCapabilityProfile.fromSnapshot(CapabilitySnapshot snapshot) {
    if (snapshot.context != CapabilityContext.authenticated) {
      protocolFailure(
        TalkProtocolErrorCode.invalidSignalingProfile,
        r'$.capabilities.context',
      );
    }
    return SignalingCapabilityProfile.fromTalkFeatures(
      snapshot.talkFeatures.toList(growable: false),
    );
  }

  factory SignalingCapabilityProfile.fromTalkFeatures(Object? rawFeatures) {
    final features = requireUniqueStringSet(
      rawFeatures,
      path: r'$.talkFeatures',
      code: TalkProtocolErrorCode.invalidSignalingProfile,
    );
    for (final feature in features) {
      if (feature.isEmpty ||
          feature.length > 128 ||
          feature.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
        protocolFailure(
          TalkProtocolErrorCode.invalidSignalingProfile,
          r'$.talkFeatures',
        );
      }
    }
    final enabled = features.contains('signaling-v3');
    return SignalingCapabilityProfile._(
      enabled: enabled,
      chatRelay: enabled && features.contains('chat-keep-notifications'),
    );
  }

  final bool enabled;

  /// The Talk capability `chat-keep-notifications`, recorded here so a changed
  /// capability set invalidates a recovered signaling session.
  ///
  /// NOT the gate for the HPB chat relay, despite the name — that one asks the
  /// signaling server what it answered in hello
  /// (`serverFeatures.supports('chat-relay')`), because the relay is a feature
  /// of the standalone signaling server, not of Talk. The same capability is
  /// called `backgroundCatchUp` on the chat profile, which is what it actually
  /// means; the name here is kept only because it is also the stored column
  /// `profileChatRelay` in the call session table.
  final bool chatRelay;

  @override
  String toString() =>
      'SignalingCapabilityProfile(enabled: $enabled, chatRelay: $chatRelay)';
}
