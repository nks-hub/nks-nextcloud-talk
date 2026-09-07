part of 'permissions.dart';

sealed class PermissionUpdateRequest {
  PermissionUpdateRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.policy,
    required this.kind,
    required this.userAgent,
  }) {
    if (!policy.supports(kind)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPermissionRequest,
        r'$.capabilities',
      );
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPermissionRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final RoomPermissionPolicy policy;
  final PermissionEditKind kind;
  final String userAgent;
  String get httpMethod => 'PUT';
  Map<String, String> get formBody;
  String get _suffix;
  Map<String, String> get headers =>
      Map.unmodifiable({'OCS-APIRequest': 'true', 'User-Agent': userAgent});
  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v4/room/${roomToken.value}/$_suffix',
    queryParameters: const {'format': 'json'},
  );

  @override
  String toString() => '$runtimeType()';
}

/// Updating defaults resets attendee-specific overrides on the server.
final class SetRoomDefaultPermissionsRequest extends PermissionUpdateRequest {
  SetRoomDefaultPermissionsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required RoomPermissionPolicy policy,
    required this.permissions,
    super.userAgent = _permissionUserAgent,
  }) : super(policy: policy, kind: PermissionEditKind.roomDefault) {
    policy.validate(kind, permissions);
  }

  final int permissions;
  @override
  String get _suffix => 'permissions/default';
  @override
  Map<String, String> get formBody =>
      Map.unmodifiable({'permissions': permissions.toString()});
}

final class SetParticipantPermissionsRequest extends PermissionUpdateRequest {
  SetParticipantPermissionsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required RoomPermissionPolicy policy,
    required this.attendeeId,
    required this.permissions,
    this.method = PermissionPatchMethod.set,
    super.userAgent = _permissionUserAgent,
  }) : super(policy: policy, kind: PermissionEditKind.attendee) {
    if (attendeeId < 0 || attendeeId > 9007199254740991) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPermissionRequest,
        r'$.body.attendeeId',
      );
    }
    policy.validate(kind, permissions, method: method);
  }

  final int attendeeId;
  final int permissions;
  final PermissionPatchMethod method;
  @override
  String get _suffix => 'attendees/permissions';
  @override
  Map<String, String> get formBody => Map.unmodifiable({
    'attendeeId': attendeeId.toString(),
    'permissions': permissions.toString(),
    'method': method.name,
  });
}

final class SetRoomMentionPermissionsRequest extends PermissionUpdateRequest {
  SetRoomMentionPermissionsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required RoomPermissionPolicy policy,
    required this.mentionPermissions,
    super.userAgent = _permissionUserAgent,
  }) : super(policy: policy, kind: PermissionEditKind.mentions) {
    policy.validate(kind, mentionPermissions);
  }

  final int mentionPermissions;
  @override
  String get _suffix => 'mention-permissions';
  @override
  Map<String, String> get formBody =>
      Map.unmodifiable({'mentionPermissions': mentionPermissions.toString()});
}
