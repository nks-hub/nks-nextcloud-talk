part of 'permissions.dart';

final class RoomPermissionPolicy {
  const RoomPermissionPolicy._({
    required this.canEditDefaults,
    required this.canEditAttendees,
    required this.canEditMentions,
    required this.canEditChat,
    required this.canEditReactions,
    required this.callsEnabled,
    required this.maximumDefault,
    required this.maximumCustom,
    required this.serverDefault,
    required this.forcedPermissions,
    required this.forcedMentions,
  });

  factory RoomPermissionPolicy.fromCapabilities(
    CapabilitySnapshot capabilities, {
    RoomPresetCatalog? presets,
  }) {
    const code = TalkProtocolErrorCode.invalidPermissionPolicy;
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.hasTalk) {
      protocolFailure(code, r'$.capabilities');
    }
    if (capabilities.supportsTalk('conversation-presets') && presets == null) {
      protocolFailure(code, r'$.capabilities.conversation-presets');
    }
    if (!capabilities.supportsTalk('conversation-presets') && presets != null) {
      protocolFailure(code, r'$.presets');
    }
    final spreed = requireObject(
      capabilities.capabilities['spreed'],
      path: r'$.spreed',
      code: code,
    );
    final config = spreed['config'] == null
        ? <String, Object?>{}
        : requireObject(spreed['config'], path: r'$.spreed.config', code: code);
    final permissions = config['permissions'] == null
        ? <String, Object?>{}
        : requireObject(
            config['permissions'],
            path: r'$.spreed.config.permissions',
            code: code,
          );
    final react = capabilities.supportsTalk('react-permission');
    final knownMaximum = react ? 511 : 255;
    int read(String name, int fallback) => permissions.containsKey(name)
        ? requireInt(
            permissions[name],
            path: r'$.spreed.config.permissions',
            code: code,
            minimum: 0,
            maximum: knownMaximum,
          )
        : fallback;
    final maximumDefault = read('max-default', knownMaximum & ~1);
    final maximumCustom = read('max-custom', knownMaximum);
    final serverDefault = read(
      'default',
      maximumDefault & ~ConversationPermission.bypassLobby.bit,
    );
    if (maximumDefault & 1 != 0 ||
        maximumCustom & 1 == 0 ||
        maximumDefault & ~maximumCustom != 0 ||
        serverDefault & ~maximumCustom != 0) {
      protocolFailure(code, r'$.spreed.config.permissions');
    }
    final call = config['call'] == null
        ? <String, Object?>{}
        : requireObject(
            config['call'],
            path: r'$.spreed.config.call',
            code: code,
          );
    final callsEnabled = call.containsKey('enabled')
        ? requireBool(
            call['enabled'],
            path: r'$.spreed.config.call.enabled',
            code: code,
          )
        : true;
    final forced = presets?.forcedPreset.parameters;
    final forcedPermissions = forced?['permissions'];
    if (forcedPermissions != null && forcedPermissions & ~maximumCustom != 0) {
      protocolFailure(code, r'$.presets.forced.permissions');
    }
    return RoomPermissionPolicy._(
      canEditDefaults: capabilities.supportsTalk('conversation-permissions'),
      canEditAttendees: capabilities.supportsTalk('publishing-permissions'),
      canEditMentions: capabilities.supportsTalk('mention-permissions'),
      canEditChat: capabilities.supportsTalk('chat-permission'),
      canEditReactions:
          react && maximumCustom & ConversationPermission.react.bit != 0,
      callsEnabled: callsEnabled,
      maximumDefault: maximumDefault,
      maximumCustom: maximumCustom,
      serverDefault: serverDefault,
      forcedPermissions: forcedPermissions,
      forcedMentions: forced?['mentionPermissions'],
    );
  }

  final bool canEditDefaults;
  final bool canEditAttendees;
  final bool canEditMentions;
  final bool canEditChat;
  final bool canEditReactions;
  final bool callsEnabled;
  final int maximumDefault;
  final int maximumCustom;
  final int serverDefault;
  final int? forcedPermissions;
  final int? forcedMentions;

  bool supports(PermissionEditKind kind) => switch (kind) {
    PermissionEditKind.roomDefault => canEditDefaults,
    PermissionEditKind.attendee => canEditAttendees,
    PermissionEditKind.mentions => canEditMentions,
  };

  void validate(
    PermissionEditKind kind,
    int value, {
    PermissionPatchMethod method = PermissionPatchMethod.set,
  }) {
    const code = TalkProtocolErrorCode.invalidPermissionRequest;
    if (!supports(kind)) protocolFailure(code, r'$.capabilities');
    if (kind == PermissionEditKind.mentions) {
      if (!const {0, 1}.contains(value) ||
          (forcedMentions != null && forcedMentions != value)) {
        protocolFailure(code, r'$.body.mentionPermissions');
      }
      return;
    }
    if (value < 0 || value & ~maximumCustom != 0) {
      protocolFailure(code, r'$.body.permissions');
    }
    final forced = forcedPermissions;
    if (forced == null) return;
    if (kind == PermissionEditKind.attendee && value == 0) return;
    if (value != forced ||
        (kind == PermissionEditKind.attendee &&
            method != PermissionPatchMethod.set)) {
      protocolFailure(code, r'$.body.permissions');
    }
  }

  @override
  String toString() => 'RoomPermissionPolicy()';
}
