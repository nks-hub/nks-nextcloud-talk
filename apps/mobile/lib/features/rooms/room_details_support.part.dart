part of 'room_details_screen.dart';

String _roomTypeLabel(AppLocalizations strings, int roomType) {
  return switch (roomType) {
    _roomTypeOneToOne => strings.roomDetailsTypeOneToOne,
    _roomTypeGroup => strings.roomDetailsTypeGroup,
    _roomTypePublic => strings.roomDetailsTypePublic,
    _roomTypeChangelog => strings.roomDetailsTypeChangelog,
    _roomTypeFormerOneToOne => strings.roomDetailsTypeFormerOneToOne,
    _roomTypeNoteToSelf => strings.roomDetailsTypeNoteToSelf,
    _ => strings.roomDetailsTypeUnknown,
  };
}

/// Labels the wire-level notification value shown as read-only room
/// metadata, including the `default` value the picker never offers.
String _notificationLabel(AppLocalizations strings, int notificationLevel) {
  return switch (notificationLevel) {
    _notificationDefault => strings.roomDetailsNotificationDefault,
    _notificationAlways => strings.roomDetailsNotificationAlways,
    _notificationMention => strings.roomDetailsNotificationMention,
    _notificationNever => strings.roomDetailsNotificationNever,
    _ => strings.roomDetailsNotificationUnknown,
  };
}

String _notificationLevelLabel(
  AppLocalizations strings,
  RoomNotificationLevel level,
) {
  return switch (level) {
    RoomNotificationLevel.always => strings.roomDetailsNotificationAlways,
    RoomNotificationLevel.mentions => strings.roomDetailsNotificationMention,
    RoomNotificationLevel.never => strings.roomDetailsNotificationNever,
  };
}

String _roleLabel(AppLocalizations strings, ParticipantRole? role) {
  return switch (role) {
    ParticipantRole.owner => strings.roomDetailsRoleOwner,
    ParticipantRole.moderator => strings.roomDetailsRoleModerator,
    ParticipantRole.user => strings.roomDetailsRoleUser,
    ParticipantRole.guest => strings.roomDetailsRoleGuest,
    ParticipantRole.userSelfJoined => strings.roomDetailsRoleUser,
    ParticipantRole.guestModerator => strings.roomDetailsRoleGuestModerator,
    null => strings.roomDetailsRoleUnknown,
  };
}

String _moderationActionLabel(
  AppLocalizations strings,
  ParticipantAction action,
) {
  return switch (action) {
    ParticipantAction.promote => strings.roomDetailsPromoteModerator,
    ParticipantAction.demote => strings.roomDetailsDemoteModerator,
    ParticipantAction.remove => strings.roomDetailsRemoveParticipant,
    ParticipantAction.ban => strings.roomDetailsBanParticipant,
  };
}

/// Same as [_actionErrorMessage], except that a refusal here means the server
/// would not accept the password rather than that leaving is blocked. It only
/// runs when the server sent no explanation of its own; when it did, that
/// text is shown verbatim instead.
String _passwordErrorMessage(AppLocalizations strings, RoomSettingsError code) {
  return code == RoomSettingsError.rejected
      ? strings.roomDetailsPasswordRejected
      : _actionErrorMessage(strings, code);
}

/// Same as [_actionErrorMessage], except that a refusal here means Talk would
/// not take this picture — not square, too big, wrong type. It only runs when
/// the server sent no explanation of its own.
String _avatarErrorMessage(AppLocalizations strings, RoomSettingsError code) {
  return code == RoomSettingsError.rejected
      ? strings.roomDetailsAvatarRejected
      : _actionErrorMessage(strings, code);
}

/// Reduces a device file name to something a multipart part header accepts.
///
/// The name comes from the user's own gallery, so it is never treated as a
/// path: every separator, quote and control character collapses to an
/// underscore, and an unusable name falls back to a generated one.
String _safeAvatarFileName(String value, String contentType) {
  final extension = contentType == 'image/png' ? 'png' : 'jpg';
  var name = value;
  for (final separator in const <String>['/', r'\']) {
    final last = name.lastIndexOf(separator);
    if (last >= 0) {
      name = name.substring(last + 1);
    }
  }
  name = name.replaceAll(RegExp(r'["\x00-\x1f\x7f]'), '_').trim();
  if (name.isEmpty || name == '.' || name == '..' || name.length > 200) {
    return 'avatar.$extension';
  }
  return name;
}

String _banErrorMessage(
  AppLocalizations strings,
  ParticipantsServiceError code,
) {
  return code == ParticipantsServiceError.rejected
      ? strings.roomDetailsBanRejected
      : _participantActionErrorMessage(strings, code);
}

/// Folds the fields an endpoint changed into the cached room when the server
/// answered without a fresh copy of it. The wire object is the same validated
/// JSON the decoder produced, so re-parsing the patched map cannot widen what
/// the rest of the screen trusts.
ConversationRoom? _patchCachedRoom(
  ConversationRoom? room,
  Map<String, Object?> patch,
) {
  if (room == null) {
    return null;
  }
  try {
    return ConversationRoom.fromJson({...room.wire, ...patch});
  } on Object {
    return room;
  }
}

/// Renders a UNIX timestamp as a local date and time, without pulling in a
/// locale-aware formatter for one label.
// ponytail: ISO-ish local time, not a localized format — swap in `intl`'s
// DateFormat if the label ever needs to read naturally in every locale.
String _formatLobbyTimer(int secondsSinceEpoch) {
  final at = DateTime.fromMillisecondsSinceEpoch(
    secondsSinceEpoch * 1000,
  ).toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${pad(at.month)}-${pad(at.day)} '
      '${pad(at.hour)}:${pad(at.minute)}';
}

Set<String> _decodeTalkFeatures(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is List<Object?> && decoded.every((value) => value is String)) {
      return decoded.cast<String>().toSet();
    }
  } on FormatException {
    // A corrupt local capability cache falls back to capability-free
    // behavior, which hides every gated action rather than guessing.
  }
  return const {};
}

String _participantActionErrorMessage(
  AppLocalizations strings,
  ParticipantsServiceError code,
) {
  return switch (code) {
    ParticipantsServiceError.reauthenticationRequired =>
      strings.roomDetailsActionErrorReauth,
    ParticipantsServiceError.forbidden =>
      strings.roomDetailsActionErrorForbidden,
    ParticipantsServiceError.roomMissing =>
      strings.roomDetailsActionErrorRoomMissing,
    ParticipantsServiceError.rejected =>
      strings.roomDetailsParticipantActionRejected,
    ParticipantsServiceError.accountMissing ||
    ParticipantsServiceError.credentialMissing ||
    ParticipantsServiceError.rateLimited ||
    ParticipantsServiceError.serviceUnavailable ||
    ParticipantsServiceError.invalidResponse ||
    ParticipantsServiceError.network => strings.roomDetailsActionErrorGeneric,
  };
}

/// Same as [_actionErrorMessage], except that a refusal here means the room
/// itself cannot be deleted rather than that leaving is blocked.
String _deleteErrorMessage(AppLocalizations strings, RoomSettingsError code) {
  return code == RoomSettingsError.rejected
      ? strings.roomDetailsDeleteRejected
      : _actionErrorMessage(strings, code);
}

String _actionErrorMessage(AppLocalizations strings, RoomSettingsError code) {
  return switch (code) {
    RoomSettingsError.reauthenticationRequired =>
      strings.roomDetailsActionErrorReauth,
    RoomSettingsError.forbidden => strings.roomDetailsActionErrorForbidden,
    RoomSettingsError.roomMissing => strings.roomDetailsActionErrorRoomMissing,
    RoomSettingsError.rejected => strings.roomDetailsLeaveRejected,
    RoomSettingsError.accountMissing ||
    RoomSettingsError.credentialMissing ||
    RoomSettingsError.rateLimited ||
    RoomSettingsError.serviceUnavailable ||
    RoomSettingsError.invalidResponse ||
    RoomSettingsError.network => strings.roomDetailsActionErrorGeneric,
  };
}

/// The cached room JSON is written from the same validated decoder that
/// produces it, so this only fails on local corruption; the screen simply
/// hides the actions (like rename) that need it when parsing fails.
ConversationRoom? _parseCachedRoom(CachedConversation conversation) {
  try {
    return ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
  } on Object {
    return null;
  }
}
