part of 'conversation_creation_dialog.dart';

final class _CreationSummary extends StatelessWidget {
  const _CreationSummary({required this.parameters, required this.forced});

  final Map<String, int> parameters;
  final Set<String> forced;

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final labels = <String, String>{
      'roomType': s.newConversationTypeLabel,
      'readOnly': s.roomDetailsReadOnlyLabel,
      'listable': s.newConversationDiscoveryLabel,
      'messageExpiration': s.roomDetailsMessageExpirationLabel,
      'lobbyState': s.roomDetailsLobbyLabel,
      'sipEnabled': s.roomDetailsSipLabel,
      'permissions': s.newConversationPermissionsLabel,
      'recordingConsent': s.newConversationRecordingConsentLabel,
      'mentionPermissions': s.newConversationMentionPermissionsLabel,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.newConversationSettingsSummary,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final key in labels.keys)
            if (parameters.containsKey(key))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${forced.contains(key) ? s.newConversationForcedSetting(labels[key]!) : labels[key]}: ${_value(s, key, parameters[key]!)}',
                ),
              ),
        ],
      ),
    );
  }

  String _value(AppLocalizations s, String key, int value) => switch (key) {
    'roomType' =>
      value == 3 ? s.newConversationTypePublic : s.newConversationTypeGroup,
    'readOnly' =>
      value == 1 ? s.roomDetailsReadOnlyYes : s.roomDetailsReadOnlyNo,
    'listable' => switch (value) {
      0 => s.newConversationDiscoveryParticipants,
      1 => s.newConversationDiscoveryUsers,
      _ => s.newConversationDiscoveryEveryone,
    },
    'messageExpiration' =>
      value == 0
          ? s.roomDetailsMessageExpirationOff
          : s.roomDetailsMessageExpirationCustom(value),
    'lobbyState' => value == 0 ? s.roomDetailsLobbyOff : s.roomDetailsLobbyOn,
    'sipEnabled' => switch (value) {
      0 => s.roomDetailsSipDisabled,
      1 => s.roomDetailsSipWithPin,
      _ => s.roomDetailsSipWithoutPin,
    },
    'recordingConsent' =>
      value == 0
          ? s.newConversationRecordingConsentOptional
          : s.newConversationRecordingConsentRequired,
    'mentionPermissions' =>
      value == 0
          ? s.newConversationDiscoveryEveryone
          : s.newConversationModeratorsOnly,
    'permissions' => _permissions(s, value),
    _ => throw StateError('Unknown creation parameter'),
  };

  String _permissions(AppLocalizations s, int mask) {
    if (mask == 0) return s.newConversationPresetDefault;
    final permissions = <int, String>{
      2: s.newConversationPermissionStartCalls,
      4: s.newConversationPermissionJoinCalls,
      8: s.newConversationPermissionIgnoreLobby,
      16: s.newConversationPermissionAudio,
      32: s.newConversationPermissionVideo,
      64: s.newConversationPermissionScreen,
      128: s.newConversationPermissionChat,
      256: s.newConversationPermissionReact,
    };
    final enabled = permissions.entries
        .where((p) => mask & p.key != 0)
        .map((p) => p.value);
    return enabled.isEmpty
        ? s.newConversationPermissionsNone
        : enabled.join(', ');
  }
}
