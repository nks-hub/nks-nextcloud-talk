import '../bootstrap/capabilities.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';

final class AttachmentCapabilityProfile {
  AttachmentCapabilityProfile._({
    required this.federated,
    required this.enabled,
    required this.caption,
    required this.voice,
    required this.reply,
    required this.threads,
    required this.silent,
  });

  factory AttachmentCapabilityProfile.fromSnapshot(
    CapabilitySnapshot snapshot, {
    required bool federated,
  }) {
    if (snapshot.context != CapabilityContext.authenticated) {
      _profileFailure(r'$.capabilities.context');
    }

    var attachmentsAllowed = false;
    var conversationSubfolders = false;
    final rawSpreed = snapshot.capabilities['spreed'];
    if (rawSpreed != null) {
      final spreed = requireObject(
        rawSpreed,
        path: r'$.capabilities.spreed',
        code: TalkProtocolErrorCode.invalidAttachmentProfile,
      );
      final rawConfig = spreed['config'];
      if (rawConfig != null) {
        final config = requireObject(
          rawConfig,
          path: r'$.capabilities.spreed.config',
          code: TalkProtocolErrorCode.invalidAttachmentProfile,
        );
        final rawAttachments = config['attachments'];
        if (rawAttachments != null) {
          final attachments = requireObject(
            rawAttachments,
            path: r'$.capabilities.spreed.config.attachments',
            code: TalkProtocolErrorCode.invalidAttachmentProfile,
          );
          if (attachments['allowed'] != null) {
            attachmentsAllowed = requireBool(
              attachments['allowed'],
              path: r'$.capabilities.spreed.config.attachments.allowed',
              code: TalkProtocolErrorCode.invalidAttachmentProfile,
            );
          }
          if (attachments['conversation-subfolders'] != null) {
            conversationSubfolders = requireBool(
              attachments['conversation-subfolders'],
              path:
                  r'$.capabilities.spreed.config.attachments.conversation-subfolders',
              code: TalkProtocolErrorCode.invalidAttachmentProfile,
            );
          }
        }
      }
    }

    final features = snapshot.talkFeatures;
    final enabled =
        attachmentsAllowed &&
        conversationSubfolders &&
        features.contains('chat-reference-id') &&
        !federated;
    return AttachmentCapabilityProfile._(
      federated: federated,
      enabled: enabled,
      caption: enabled && features.contains('media-caption'),
      voice: enabled && features.contains('voice-message-sharing'),
      reply: enabled && features.contains('chat-replies'),
      threads: enabled && features.contains('threads'),
      silent: enabled && features.contains('silent-send'),
    );
  }

  final bool federated;
  final bool enabled;
  final bool caption;
  final bool voice;
  final bool reply;
  final bool threads;
  final bool silent;

  bool supports(AttachmentMetadata metadata) =>
      enabled &&
      (metadata.caption == null || caption) &&
      (metadata.kind != AttachmentMessageKind.voice || voice) &&
      (metadata.replyTo == null || reply) &&
      (metadata.threadId == null || threads) &&
      (!metadata.silent || silent);

  @override
  String toString() =>
      'AttachmentCapabilityProfile(federated: $federated, enabled: $enabled, '
      'caption: $caption, voice: $voice, reply: $reply, threads: $threads, '
      'silent: $silent)';
}

Never _profileFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentProfile, path);
