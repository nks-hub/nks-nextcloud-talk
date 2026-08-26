import '../bootstrap/capabilities.dart';

/// Capability and local participant admission for Talk conversation tags.
///
/// Talk `f2958bb25be6604240c58a3faf9a2033a30d20e5` exposes
/// `conversation-tags` in authenticated features and local features. Tag
/// definitions are user-scoped; assigning them requires a logged-in
/// participant, not a moderator.
final class ConversationTagsProfile {
  const ConversationTagsProfile._({
    required this.canLoadDefinitions,
    required this.canAssign,
  });

  factory ConversationTagsProfile.fromCapabilities({
    required CapabilitySnapshot capabilities,
    required bool loggedInParticipant,
  }) {
    final supported =
        capabilities.context == CapabilityContext.authenticated &&
        capabilities.supportsTalk('conversation-tags');
    return ConversationTagsProfile._(
      canLoadDefinitions: supported,
      canAssign: supported && loggedInParticipant,
    );
  }

  final bool canLoadDefinitions;
  final bool canAssign;
}
