import '../bootstrap/capabilities.dart';
import '../json_value.dart';
import '../protocol_exception.dart';

/// The authenticated capability slice that makes Talk's v4 call REST API safe
/// to use.
///
/// Evidence: spreed `f2958bb25be6604240c58a3faf9a2033a30d20e5` and
/// `f9b9e9474e3621b47f74bf8890c4642cb49eed97`.
final class CallCapabilityProfile {
  CallCapabilityProfile._({
    required this.enabled,
    required this.silent,
    required this.recordingConsent,
    required this.recordingConsentMode,
  }) : revision =
           'call-v4:${enabled ? 1 : 0}:${silent ? 1 : 0}:'
           '${recordingConsent ? 1 : 0}:$recordingConsentMode';

  factory CallCapabilityProfile.fromSnapshot(CapabilitySnapshot snapshot) {
    if (snapshot.context != CapabilityContext.authenticated) {
      _profileFailure(r'$.capabilities.context');
    }

    var callEnabled = false;
    var recordingConsentMode = 0;
    final rawSpreed = snapshot.capabilities['spreed'];
    if (rawSpreed != null) {
      final spreed = requireObject(
        rawSpreed,
        path: r'$.capabilities.spreed',
        code: TalkProtocolErrorCode.invalidCallProfile,
      );
      final rawConfig = spreed['config'];
      if (rawConfig != null) {
        final config = requireObject(
          rawConfig,
          path: r'$.capabilities.spreed.config',
          code: TalkProtocolErrorCode.invalidCallProfile,
        );
        final rawCall = config['call'];
        if (rawCall != null) {
          final call = requireObject(
            rawCall,
            path: r'$.capabilities.spreed.config.call',
            code: TalkProtocolErrorCode.invalidCallProfile,
          );
          if (call.containsKey('enabled')) {
            callEnabled = requireBool(
              call['enabled'],
              path: r'$.capabilities.spreed.config.call.enabled',
              code: TalkProtocolErrorCode.invalidCallProfile,
            );
          }
          if (call.containsKey('recording-consent')) {
            recordingConsentMode = requireInt(
              call['recording-consent'],
              path: r'$.capabilities.spreed.config.call.recording-consent',
              code: TalkProtocolErrorCode.invalidCallProfile,
              minimum: 0,
              maximum: 2,
            );
          }
        }
      }
    }

    final features = snapshot.talkFeatures;
    final silent = features.contains('silent-call');
    final recordingConsent = features.contains('recording-consent');
    final enabled =
        callEnabled &&
        features.contains('conversation-v4') &&
        features.contains('conversation-permissions') &&
        features.contains('in-call-flags') &&
        silent &&
        recordingConsent;
    return CallCapabilityProfile._(
      enabled: enabled,
      silent: silent,
      recordingConsent: recordingConsent,
      recordingConsentMode: recordingConsentMode,
    );
  }

  final bool enabled;
  final bool silent;
  final bool recordingConsent;

  /// 0: not required, 1: required, 2: configured per conversation.
  final int recordingConsentMode;

  /// Stable non-secret revision persisted with a lifecycle authority.
  final String revision;

  @override
  String toString() =>
      'CallCapabilityProfile(enabled: $enabled, silent: $silent, '
      'recordingConsent: $recordingConsent, '
      'recordingConsentMode: $recordingConsentMode)';
}

Never _profileFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidCallProfile, path);
