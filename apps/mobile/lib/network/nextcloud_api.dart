import 'dart:async';
import 'dart:convert';
import 'dart:io' show Cookie, HttpException, Platform;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

import '../core/app_version.dart';

part 'nextcloud_api_account.dart';
part 'nextcloud_api_call.dart';
part 'nextcloud_api_chat.dart';
part 'nextcloud_api_cookies.dart';
part 'nextcloud_api_profile.dart';
part 'nextcloud_api_polls.dart';
part 'nextcloud_api_push.dart';
part 'nextcloud_api_rooms.dart';
part 'nextcloud_api_translation.dart';
part 'nextcloud_api_transport.dart';

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB]'
  r'[0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
final RegExp _webPushP256dhPattern = RegExp(r'^[A-Za-z0-9_-]{87}$');
final RegExp _webPushAuthPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');

enum NextcloudApiError {
  cancelled,
  network,
  timeout,
  responseTooLarge,
  invalidJson,
  invalidAvatarUri,
  invalidAvatarResponse,
  invalidWebPushResponse,
  unexpectedStatus,
}

enum AvatarResponseStatus { image, notModified, notFound }

enum WebPushRegistrationStatus { active, activationRequired }

final class ActiveRoomSessionLease {
  const ActiveRoomSessionLease._({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.generation,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int generation;
}

final class ActiveRoomSessionActivation {
  const ActiveRoomSessionActivation({required this.response, this.lease});

  final ActiveRoomSessionResponse response;
  final ActiveRoomSessionLease? lease;
}

final class CurrentOutOfOffice {
  const CurrentOutOfOffice._({
    required this.id,
    required this.userId,
    required this.start,
    required this.end,
    required this.shortMessage,
    required this.message,
    required this.replacementUserId,
    required this.replacementUserDisplayName,
  });

  factory CurrentOutOfOffice.fromOcsJson(
    Object? json, {
    required String expectedUserId,
  }) {
    final data = _ocsDataObject(json);
    final userId = _boundedString(data['userId'], 4096);
    final startSeconds = _nonNegativeInt(data['startDate']);
    final endSeconds = _nonNegativeInt(data['endDate']);
    if (userId != expectedUserId || startSeconds > endSeconds) {
      throw const NextcloudApiException(NextcloudApiError.invalidJson);
    }
    try {
      return CurrentOutOfOffice._(
        id: _boundedString(data['id'], 4096),
        userId: userId,
        start: DateTime.fromMillisecondsSinceEpoch(
          startSeconds * Duration.millisecondsPerSecond,
          isUtc: true,
        ),
        end: DateTime.fromMillisecondsSinceEpoch(
          endSeconds * Duration.millisecondsPerSecond,
          isUtc: true,
        ),
        shortMessage: _boundedString(
          data['shortMessage'],
          4096,
          allowEmpty: true,
        ),
        message: _boundedString(data['message'], 4096, allowEmpty: true),
        replacementUserId: _optionalBoundedString(
          data['replacementUserId'],
          4096,
        ),
        replacementUserDisplayName: _optionalBoundedString(
          data['replacementUserDisplayName'],
          4096,
        ),
      );
    } on RangeError {
      throw const NextcloudApiException(NextcloudApiError.invalidJson);
    }
  }

  final String id;
  final String userId;
  final DateTime start;
  final DateTime end;
  final String shortMessage;
  final String message;
  final String? replacementUserId;
  final String? replacementUserDisplayName;

  @override
  String toString() => 'CurrentOutOfOffice(<redacted>)';
}

final class UpcomingTalkEvent {
  const UpcomingTalkEvent._({
    required this.uri,
    required this.calendarUri,
    required this.start,
    required this.summary,
    required this.location,
  });

  static UpcomingTalkEvent? fromOcsJson(
    Object? json, {
    required String expectedLocation,
  }) {
    final data = _ocsDataObject(json);
    final events = data['events'];
    if (events is! List<Object?> || events.length > 100) {
      throw const NextcloudApiException(NextcloudApiError.invalidJson);
    }
    for (final rawEvent in events) {
      final event = _object(rawEvent);
      final location = _optionalBoundedString(
        event['location'],
        4096,
        allowEmpty: true,
      );
      if (location == null || location != expectedLocation) {
        throw const NextcloudApiException(NextcloudApiError.invalidJson);
      }
      final startSeconds = _optionalNonNegativeInt(event['start']);
      final summary = _optionalBoundedString(
        event['summary'],
        4096,
        allowEmpty: true,
      );
      if (startSeconds == null && (summary == null || summary.trim().isEmpty)) {
        continue;
      }
      try {
        return UpcomingTalkEvent._(
          uri: _boundedString(event['uri'], 4096),
          calendarUri: _boundedString(event['calendarUri'], 4096),
          start: startSeconds == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  startSeconds * Duration.millisecondsPerSecond,
                  isUtc: true,
                ),
          summary: summary?.trim(),
          location: location,
        );
      } on RangeError {
        throw const NextcloudApiException(NextcloudApiError.invalidJson);
      }
    }
    return null;
  }

  final String uri;
  final String calendarUri;
  final DateTime? start;
  final String? summary;
  final String location;

  String get identity =>
      '$calendarUri\u0000$uri\u0000${start?.millisecondsSinceEpoch ?? -1}'
      '\u0000${summary ?? ''}';

  @override
  String toString() => 'UpcomingTalkEvent(<redacted>)';
}

Map<String, Object?> _ocsDataObject(Object? json) {
  final root = _object(json);
  final ocs = _object(root['ocs']);
  final meta = _object(ocs['meta']);
  if (meta['status'] != 'ok' || meta['statuscode'] != 200) {
    throw const NextcloudApiException(NextcloudApiError.invalidJson);
  }
  return _object(ocs['data']);
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const NextcloudApiException(NextcloudApiError.invalidJson);
  }
  return value;
}

String _boundedString(Object? value, int maximum, {bool allowEmpty = false}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.runes.length > maximum) {
    throw const NextcloudApiException(NextcloudApiError.invalidJson);
  }
  return value;
}

String? _optionalBoundedString(
  Object? value,
  int maximum, {
  bool allowEmpty = false,
}) {
  if (value == null) {
    return null;
  }
  return _boundedString(value, maximum, allowEmpty: allowEmpty);
}

int _nonNegativeInt(Object? value) {
  if (value is! int || value < 0) {
    throw const NextcloudApiException(NextcloudApiError.invalidJson);
  }
  return value;
}

int? _optionalNonNegativeInt(Object? value) {
  if (value == null) {
    return null;
  }
  return _nonNegativeInt(value);
}

/// Identifies whether an authenticated capability read reached the server.
enum CapabilitySnapshotSource { network, memoryCache }

/// A validated capability snapshot together with its transport provenance.
final class AuthenticatedCapabilityRead {
  const AuthenticatedCapabilityRead({
    required this.snapshot,
    required this.source,
  });

  final CapabilitySnapshot snapshot;
  final CapabilitySnapshotSource source;
}

final class AvatarResponse {
  const AvatarResponse({
    required this.status,
    required this.body,
    required this.contentType,
    required this.isCustomAvatar,
    required this.cacheControl,
    required this.etag,
    required this.lastModified,
  });

  final AvatarResponseStatus status;
  final Uint8List body;
  final String? contentType;
  final bool? isCustomAvatar;
  final String? cacheControl;
  final String? etag;
  final String? lastModified;
}

final class NextcloudApiException implements Exception {
  const NextcloudApiException(this.code, {this.statusCode});

  final NextcloudApiError code;
  final int? statusCode;

  @override
  String toString() =>
      'NextcloudApiException(${code.name}, statusCode: $statusCode)';
}

final class PendingLogin {
  const PendingLogin({
    required this.server,
    required this.serverStatus,
    required this.initialization,
  });

  final ServerBase server;
  final ServerStatus serverStatus;
  final LoginFlowInitialization initialization;

  @override
  String toString() => 'PendingLogin(<redacted>)';
}

/// Nextcloud derives the device name of the generated app password from the
/// User-Agent. Without this the server stores the bare Dart default, so the
/// account owner sees a meaningless entry under security settings and cannot
/// tell which device to revoke.
const String loginFlowUserAgent = 'NKS Talk';

/// User-Agent for the OCS push registration route.
///
/// Nextcloud classifies a push registration solely by this header:
/// `PushController::register` matches it against `IRequest::USER_AGENT_TALK_*`
/// and stores `apptype = talk`, `nextcloud` or `unknown`. `Push` then filters
/// per notification — a Talk notification goes to the `talk` devices and only
/// falls back to the others when the account has none at all. Registering
/// without this header therefore silently costs every Talk notification on any
/// account that also uses the official Talk app.
///
/// Only Android and iOS are classified as `talk` upstream; the desktop pattern
/// exists but `PushController` does not consult it, so desktop registrations
/// stay `unknown` exactly like the official Talk Desktop client.
String get pushRegistrationUserAgent =>
    'Mozilla/5.0 ($_pushUserAgentPlatform) Nextcloud-Talk v$appVersionName';

String get _pushUserAgentPlatform {
  if (Platform.isAndroid) {
    return 'Android';
  }
  if (Platform.isIOS) {
    return 'iOS';
  }
  if (Platform.isMacOS) {
    return 'Macintosh';
  }
  if (Platform.isWindows) {
    return 'Windows';
  }
  return 'Linux';
}

final class HttpNextcloudApi extends _HttpNextcloudApiBase
    with
        _NextcloudApiAccount,
        _NextcloudApiRooms,
        _NextcloudApiChat,
        _NextcloudApiCall,
        _NextcloudApiProfile,
        _NextcloudApiPolls,
        _NextcloudApiPush,
        _NextcloudApiTranslation {
  HttpNextcloudApi({
    super.client,
    super.originPolicy = ServerOriginPolicy.production,
    super.requestTimeout = const Duration(seconds: 20),
    super.capabilityCacheTtl = const Duration(minutes: 5),
    super.clock,
  });
}
