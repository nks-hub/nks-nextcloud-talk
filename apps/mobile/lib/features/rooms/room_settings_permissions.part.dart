part of 'room_settings_service.dart';

final class RoomPermissionEdit {
  RoomPermissionEdit._({
    required this.accountId,
    required this.kind,
    required this.room,
    required this.policy,
    required List<Participant> participants,
    required this.target,
  }) : participants = List.unmodifiable(participants);

  final String accountId;
  final PermissionEditKind kind;
  final ConversationRoom room;
  final RoomPermissionPolicy policy;
  final List<Participant> participants;
  final Participant? target;

  int get initialValue => switch (kind) {
    PermissionEditKind.roomDefault => room.defaultPermissions,
    PermissionEditKind.attendee => target!.attendeePermissions,
    PermissionEditKind.mentions => room.mentionPermissions,
  };

  bool get makesRegularMember => target?.participantType == 5;

  @override
  String toString() => 'RoomPermissionEdit(kind: ${kind.name})';
}

final class RoomPermissionEditResult {
  RoomPermissionEditResult._(this.room, List<Participant> participants)
    : participants = List.unmodifiable(participants);
  final ConversationRoom room;
  final List<Participant> participants;
}

extension RoomSettingsPermissions on RoomSettingsService {
  Future<RoomPermissionEdit> preparePermissionEdit({
    required String accountId,
    required String roomToken,
    required PermissionEditKind kind,
    int? attendeeId,
    Future<void>? abortTrigger,
    bool Function()? isCurrent,
  }) async {
    if ((kind == PermissionEditKind.attendee) != (attendeeId != null)) {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    var aborted = false;
    abortTrigger?.then((_) => aborted = true);
    void check() {
      if (aborted || !(isCurrent?.call() ?? true)) {
        throw const RoomSettingsException(RoomSettingsError.accountMissing);
      }
    }

    check();
    final context = await _authContext(accountId);
    await _validateAccessIdentity(context);
    check();
    final server = ServerBase.parse(context.account.serverUrl);
    final capabilities = (await _call(
      () => _api.getAuthenticatedCapabilitiesWithSource(
        server: server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        forceRefresh: true,
        abortTrigger: abortTrigger,
      ),
    )).snapshot;
    check();
    final presets = capabilities.supportsTalk('conversation-presets')
        ? await _call(
            () => _api.getRoomPresets(
              request: RoomPresetsRequest(
                accountId: AccountId.parse(accountId),
                server: server,
                capabilities: capabilities,
              ),
              loginName: context.account.loginName,
              appPassword: context.appPassword,
              abortTrigger: abortTrigger,
            ),
          )
        : null;
    check();
    final RoomPermissionPolicy policy;
    try {
      policy = RoomPermissionPolicy.fromCapabilities(
        capabilities,
        presets: presets,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    if (!policy.supports(kind)) {
      throw const RoomSettingsException(RoomSettingsError.forbidden);
    }
    final room = await _readAccessRoom(context, roomToken, abortTrigger);
    check();
    _requirePermissionModerator(room, kind);
    final participants = await _readPermissionParticipants(
      context,
      roomToken,
      abortTrigger,
    );
    check();
    await _validateAccessIdentity(context);
    check();
    final target = attendeeId == null
        ? null
        : _permissionTarget(participants, attendeeId);
    if (target != null) _requireEditableAttendee(target);
    _requireSupportedPermissionValues(kind, policy, room, participants, target);
    final edit = RoomPermissionEdit._(
      accountId: accountId,
      kind: kind,
      room: room,
      policy: policy,
      participants: participants,
      target: target,
    );
    _permissionOrigins[edit] = context;
    return edit;
  }

  Future<RoomPermissionEditResult> applyPermissionEdit({
    required RoomPermissionEdit edit,
    required int value,
    bool confirmResetOverrides = false,
    bool confirmRegularMembership = false,
    Future<void>? abortTrigger,
    bool Function()? isCurrent,
  }) async {
    final context = _permissionOrigins[edit];
    if (context == null || _permissionUsed[edit] == true) {
      throw const RoomSettingsException(RoomSettingsError.preconditionFailed);
    }
    if ((edit.kind == PermissionEditKind.roomDefault &&
            !confirmResetOverrides) ||
        (edit.makesRegularMember && !confirmRegularMembership)) {
      throw const RoomSettingsException(RoomSettingsError.rejected);
    }
    final key = (accountId: edit.accountId, roomToken: edit.room.token.value);
    if (!_accessChangesPending.add(key)) {
      throw const RoomSettingsException(RoomSettingsError.rejected);
    }
    var dispatched = false;
    var rejected = false;
    var aborted = false;
    abortTrigger?.then((_) => aborted = true);
    void check() {
      if (aborted || !(isCurrent?.call() ?? true)) {
        throw RoomSettingsException(
          dispatched
              ? RoomSettingsError.ambiguous
              : RoomSettingsError.accountMissing,
        );
      }
    }

    try {
      check();
      await _validateAccessIdentity(context);
      final fresh = await preparePermissionEdit(
        accountId: edit.accountId,
        roomToken: edit.room.token.value,
        kind: edit.kind,
        attendeeId: edit.target?.attendeeId,
        abortTrigger: abortTrigger,
        isCurrent: isCurrent,
      );
      check();
      if (!_samePermissionEdit(edit, fresh)) {
        throw const RoomSettingsException(RoomSettingsError.preconditionFailed);
      }
      final PermissionUpdateRequest request;
      try {
        final accountId = AccountId.parse(edit.accountId);
        final server = ServerBase.parse(context.account.serverUrl);
        request = switch (edit.kind) {
          PermissionEditKind.roomDefault => SetRoomDefaultPermissionsRequest(
            accountId: accountId,
            server: server,
            roomToken: edit.room.token,
            policy: fresh.policy,
            permissions: value,
          ),
          PermissionEditKind.attendee => SetParticipantPermissionsRequest(
            accountId: accountId,
            server: server,
            roomToken: edit.room.token,
            policy: fresh.policy,
            attendeeId: fresh.target!.attendeeId,
            permissions: value,
          ),
          PermissionEditKind.mentions => SetRoomMentionPermissionsRequest(
            accountId: accountId,
            server: server,
            roomToken: edit.room.token,
            policy: fresh.policy,
            mentionPermissions: value,
          ),
        };
      } on TalkProtocolException {
        throw const RoomSettingsException(RoomSettingsError.rejected);
      }
      await _validateAccessIdentity(context);
      check();
      _permissionUsed[edit] = true;
      dispatched = true;
      final response = await _call(
        () => _api.updateConversationPermissions(
          permissionRequest: request,
          loginName: context.account.loginName,
          appPassword: context.appPassword,
          abortTrigger: abortTrigger,
        ),
      );
      check();
      if (response is PermissionUpdateFailure) {
        rejected =
            response.kind != PermissionUpdateFailureKind.serviceUnavailable;
        throw RoomSettingsException(switch (response.kind) {
          PermissionUpdateFailureKind.rejected =>
            response.reason == 'forced'
                ? RoomSettingsError.preconditionFailed
                : RoomSettingsError.rejected,
          PermissionUpdateFailureKind.reauthenticationRequired =>
            RoomSettingsError.reauthenticationRequired,
          PermissionUpdateFailureKind.forbidden => RoomSettingsError.forbidden,
          PermissionUpdateFailureKind.notFound => RoomSettingsError.roomMissing,
          PermissionUpdateFailureKind.rateLimited =>
            RoomSettingsError.rateLimited,
          PermissionUpdateFailureKind.serviceUnavailable =>
            RoomSettingsError.ambiguous,
        });
      }
      if (response is AttendeePermissionsUpdated &&
          !_sameAttendeeIdentity(fresh.target!, response.participant)) {
        throw const RoomSettingsException(RoomSettingsError.ambiguous);
      }
      await _validateAccessIdentity(context);
      check();
      final room = await _readAccessRoom(
        context,
        edit.room.token.value,
        abortTrigger,
      );
      check();
      final participants = await _readPermissionParticipants(
        context,
        edit.room.token.value,
        abortTrigger,
      );
      await _validateAccessIdentity(context);
      check();
      _verifyPermissionReadback(fresh, value, room, participants);
      return RoomPermissionEditResult._(room, participants);
    } on RoomSettingsException {
      if (dispatched && !rejected) {
        throw const RoomSettingsException(RoomSettingsError.ambiguous);
      }
      rethrow;
    } finally {
      if (rejected) _permissionUsed[edit] = false;
      _accessChangesPending.remove(key);
    }
  }

  Future<List<Participant>> _readPermissionParticipants(
    _AuthContext context,
    String roomToken,
    Future<void>? abortTrigger,
  ) async {
    final response = await _call(
      () => _api.getParticipants(
        participantsRequest: ParticipantsRequest(
          accountId: AccountId.parse(context.account.id),
          server: ServerBase.parse(context.account.serverUrl),
          roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
          includeStatus: false,
        ),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      ),
    );
    return switch (response) {
      ParticipantsSuccess(:final participants) when participants.isNotEmpty =>
        participants,
      ParticipantsSuccess() => throw const RoomSettingsException(
        RoomSettingsError.invalidResponse,
      ),
      ParticipantsReauthenticationRequired() =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      ParticipantsForbidden() => throw const RoomSettingsException(
        RoomSettingsError.forbidden,
      ),
      ParticipantsRoomMissing() => throw const RoomSettingsException(
        RoomSettingsError.roomMissing,
      ),
      ParticipantsHttpFailure(:final kind) => throw RoomSettingsException(
        kind == ParticipantsHttpFailureKind.rateLimited
            ? RoomSettingsError.rateLimited
            : RoomSettingsError.serviceUnavailable,
      ),
    };
  }
}

void _requirePermissionModerator(
  ConversationRoom room,
  PermissionEditKind kind,
) {
  final roles = kind == PermissionEditKind.mentions
      ? const {1, 2}
      : const {1, 2, 6};
  final remote = room.wire['remoteServer'];
  if (!roles.contains(room.participantType) ||
      !const {2, 3}.contains(room.type) ||
      room.attributes & 4 != 0 ||
      (remote is String && remote.isNotEmpty) ||
      (kind != PermissionEditKind.attendee && room.objectType == 'room')) {
    throw const RoomSettingsException(RoomSettingsError.forbidden);
  }
}

Participant _permissionTarget(List<Participant> participants, int id) {
  final found = participants.where((p) => p.attendeeId == id);
  if (found.length != 1) {
    throw const RoomSettingsException(RoomSettingsError.roomMissing);
  }
  return found.single;
}

void _requireEditableAttendee(Participant target) {
  if (!const {3, 4, 5}.contains(target.participantType) ||
      target.actorId.isEmpty ||
      !const {
        'users',
        'guests',
        'emails',
        'phones',
        'federated_users',
      }.contains(target.actorType)) {
    throw const RoomSettingsException(RoomSettingsError.forbidden);
  }
}

void _requireSupportedPermissionValues(
  PermissionEditKind kind,
  RoomPermissionPolicy policy,
  ConversationRoom room,
  List<Participant> participants,
  Participant? target,
) {
  if (kind == PermissionEditKind.mentions) {
    if (!const {0, 1}.contains(room.mentionPermissions)) {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    return;
  }
  bool supported(int value) => value >= 0 && value & ~policy.maximumCustom == 0;
  if (!supported(room.defaultPermissions) ||
      (kind == PermissionEditKind.roomDefault &&
          participants.any((p) => !supported(p.attendeePermissions))) ||
      (target != null &&
          (!supported(target.attendeePermissions) ||
              !supported(target.permissions)))) {
    throw const RoomSettingsException(RoomSettingsError.invalidResponse);
  }
}

bool _sameAttendeeIdentity(Participant a, Participant b) =>
    a.attendeeId == b.attendeeId &&
    a.actorType == b.actorType &&
    a.actorId == b.actorId;

bool _samePermissionEdit(RoomPermissionEdit a, RoomPermissionEdit b) {
  List<Object?> policy(RoomPermissionPolicy p) => [
    p.canEditDefaults,
    p.canEditAttendees,
    p.canEditMentions,
    p.canEditChat,
    p.canEditReactions,
    p.callsEnabled,
    p.maximumDefault,
    p.maximumCustom,
    p.serverDefault,
    p.forcedPermissions,
    p.forcedMentions,
  ];
  final x = policy(a.policy), y = policy(b.policy);
  if (a.initialValue != b.initialValue ||
      a.room.type != b.room.type ||
      a.room.defaultPermissions != b.room.defaultPermissions ||
      !Iterable<int>.generate(x.length).every((i) => x[i] == y[i])) {
    return false;
  }
  final target = a.target;
  return target == null ||
      (b.target != null &&
          _sameAttendeeIdentity(target, b.target!) &&
          target.participantType == b.target!.participantType &&
          target.permissions == b.target!.permissions &&
          target.displayName == b.target!.displayName);
}

void _verifyPermissionReadback(
  RoomPermissionEdit edit,
  int value,
  ConversationRoom room,
  List<Participant> participants,
) {
  var valid = room.type == edit.room.type;
  switch (edit.kind) {
    case PermissionEditKind.roomDefault:
      valid &=
          room.defaultPermissions == normalizePermissionSet(value) &&
          participants.every((p) => p.attendeePermissions == 0);
    case PermissionEditKind.mentions:
      valid &= room.mentionPermissions == value;
    case PermissionEditKind.attendee:
      final target = _permissionTarget(participants, edit.target!.attendeeId);
      valid &=
          _sameAttendeeIdentity(edit.target!, target) &&
          target.attendeePermissions == normalizePermissionSet(value) &&
          target.participantType ==
              (edit.makesRegularMember ? 3 : edit.target!.participantType);
  }
  if (!valid) throw const RoomSettingsException(RoomSettingsError.ambiguous);
}
