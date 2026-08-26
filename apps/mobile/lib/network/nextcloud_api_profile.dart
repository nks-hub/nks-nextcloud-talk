part of 'nextcloud_api.dart';

const _ownProfileMaximumBytes = 256 * 1024;
const _ownUserStatusMaximumBytes = 64 * 1024;

enum OwnUserStatusType { online, away, dnd, busy, offline, invisible }

final class OwnProfileResponse {
  const OwnProfileResponse({
    required this.userId,
    required this.displayName,
    required this.email,
  });

  final String userId;
  final String displayName;
  final String? email;
}

final class OwnUserStatusResponse {
  const OwnUserStatusResponse({
    required this.userId,
    required this.message,
    required this.messageId,
    required this.messageIsPredefined,
    required this.icon,
    required this.clearAt,
    required this.status,
    required this.statusIsUserDefined,
  });

  final String userId;
  final String? message;
  final String? messageId;
  final bool messageIsPredefined;
  final String? icon;
  final int? clearAt;
  final OwnUserStatusType status;
  final bool statusIsUserDefined;
}

mixin _NextcloudApiProfile on _HttpNextcloudApiBase {
  Future<OwnProfileResponse> getOwnProfile({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      'GET',
      _ownProfileUri(server),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200},
      maximumBytes: _ownProfileMaximumBytes,
    );
    return _parseOwnProfile(payload.json);
  }

  Future<OwnUserStatusResponse> getOwnUserStatus({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) {
    return _readOwnUserStatus(
      'GET',
      _ownUserStatusUri(server),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
  }

  Future<OwnUserStatusResponse> setOwnUserStatusType({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required OwnUserStatusType status,
    Future<void>? abortTrigger,
  }) {
    return _readOwnUserStatus(
      'PUT',
      _ownUserStatusUri(server, 'status'),
      loginName: loginName,
      appPassword: appPassword,
      bodyFields: {'statusType': status.name},
      abortTrigger: abortTrigger,
    );
  }

  Future<OwnUserStatusResponse> setOwnCustomStatusMessage({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required String message,
    String? statusIcon,
    int? clearAt,
    Future<void>? abortTrigger,
  }) {
    final fields = <String, String>{'message': message};
    if (statusIcon != null) {
      fields['statusIcon'] = statusIcon;
    }
    if (clearAt != null) {
      fields['clearAt'] = clearAt.toString();
    }
    return _readOwnUserStatus(
      'PUT',
      _ownUserStatusUri(server, 'message/custom'),
      loginName: loginName,
      appPassword: appPassword,
      bodyFields: fields,
      abortTrigger: abortTrigger,
    );
  }

  Future<void> clearOwnUserStatusMessage({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      'DELETE',
      _ownUserStatusUri(server, 'message'),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200},
      maximumBytes: _ownUserStatusMaximumBytes,
    );
    final data = _profileOcsData(
      payload.json,
      error: NextcloudApiError.invalidJson,
    );
    if (data is! List<Object?> || data.isNotEmpty) {
      throw const NextcloudApiException(NextcloudApiError.invalidJson);
    }
  }

  Future<OwnUserStatusResponse> _readOwnUserStatus(
    String method,
    Uri uri, {
    required String loginName,
    required String appPassword,
    Map<String, String>? bodyFields,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      method,
      uri,
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    if (bodyFields != null) {
      request.bodyFields = bodyFields;
    }
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200},
      maximumBytes: _ownUserStatusMaximumBytes,
    );
    return _parseOwnUserStatus(payload.json);
  }
}

Uri _ownProfileUri(ServerBase server) {
  return server.uri.replace(
    path: '${server.basePath}/ocs/v2.php/cloud/user',
    queryParameters: const {'format': 'json'},
  );
}

Uri _ownUserStatusUri(ServerBase server, [String? suffix]) {
  final tail = suffix == null ? '' : '/$suffix';
  return server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/user_status/api/v1/user_status$tail',
    queryParameters: const {'format': 'json'},
  );
}

OwnProfileResponse _parseOwnProfile(Object? json) {
  final data = _profileOcsData(json, error: NextcloudApiError.invalidJson);
  if (data is! Map<String, Object?>) {
    throw const NextcloudApiException(NextcloudApiError.invalidJson);
  }
  final userId = _profileRequiredString(
    data['id'],
    maximumLength: 256,
    error: NextcloudApiError.invalidJson,
  );
  final displayName = _profileOptionalString(
    data['display-name'] ?? data['displayname'],
    maximumLength: 1024,
    error: NextcloudApiError.invalidJson,
  );
  final email = _profileOptionalString(
    data['email'],
    maximumLength: 1024,
    error: NextcloudApiError.invalidJson,
  );
  return OwnProfileResponse(
    userId: userId,
    displayName: displayName?.trim().isNotEmpty == true
        ? displayName!.trim()
        : userId,
    email: email?.trim().isEmpty == true ? null : email?.trim(),
  );
}

OwnUserStatusResponse _parseOwnUserStatus(Object? json) {
  final data = _profileOcsData(json, error: NextcloudApiError.invalidJson);
  if (data is! Map<String, Object?>) {
    throw const NextcloudApiException(NextcloudApiError.invalidJson);
  }
  const error = NextcloudApiError.invalidJson;
  final rawStatus = _profileRequiredString(
    data['status'],
    maximumLength: 16,
    error: error,
  );
  final status = OwnUserStatusType.values
      .where((candidate) => candidate.name == rawStatus)
      .firstOrNull;
  final clearAt = data['clearAt'];
  if (status == null ||
      (clearAt != null && (clearAt is! int || clearAt < 0)) ||
      data['messageIsPredefined'] is! bool ||
      data['statusIsUserDefined'] is! bool) {
    throw const NextcloudApiException(error);
  }
  return OwnUserStatusResponse(
    userId: _profileRequiredString(
      data['userId'],
      maximumLength: 256,
      error: error,
    ),
    message: _profileOptionalString(
      data['message'],
      maximumLength: 80,
      error: error,
    ),
    messageId: _profileOptionalString(
      data['messageId'],
      maximumLength: 256,
      error: error,
    ),
    messageIsPredefined: data['messageIsPredefined']! as bool,
    icon: _profileOptionalString(data['icon'], maximumLength: 64, error: error),
    clearAt: clearAt as int?,
    status: status,
    statusIsUserDefined: data['statusIsUserDefined']! as bool,
  );
}

Object? _profileOcsData(Object? json, {required NextcloudApiError error}) {
  if (json is! Map<String, Object?>) {
    throw NextcloudApiException(error);
  }
  final ocs = json['ocs'];
  final meta = ocs is Map<String, Object?> ? ocs['meta'] : null;
  if (meta is! Map<String, Object?> ||
      meta['status'] != 'ok' ||
      meta['statuscode'] != 200 ||
      meta['message'] is! String) {
    throw NextcloudApiException(error);
  }
  return (ocs as Map<String, Object?>)['data'];
}

String _profileRequiredString(
  Object? value, {
  required int maximumLength,
  required NextcloudApiError error,
}) {
  final parsed = _profileOptionalString(
    value,
    maximumLength: maximumLength,
    error: error,
  );
  if (parsed == null || parsed.isEmpty) {
    throw NextcloudApiException(error);
  }
  return parsed;
}

String? _profileOptionalString(
  Object? value, {
  required int maximumLength,
  required NextcloudApiError error,
}) {
  if (value == null) {
    return null;
  }
  if (value is! String ||
      value.runes.length > maximumLength ||
      value.codeUnits.any((unit) => unit <= 0x08 || unit == 0x7f)) {
    throw NextcloudApiException(error);
  }
  return value;
}
