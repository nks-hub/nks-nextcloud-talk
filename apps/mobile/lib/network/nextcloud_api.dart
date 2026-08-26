import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

part 'nextcloud_api_account.dart';
part 'nextcloud_api_chat.dart';
part 'nextcloud_api_profile.dart';
part 'nextcloud_api_rooms.dart';
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
const String loginFlowUserAgent = 'NCloudTalk';

final class HttpNextcloudApi extends _HttpNextcloudApiBase
    with
        _NextcloudApiAccount,
        _NextcloudApiRooms,
        _NextcloudApiChat,
        _NextcloudApiProfile {
  HttpNextcloudApi({
    super.client,
    super.originPolicy = ServerOriginPolicy.production,
    super.requestTimeout = const Duration(seconds: 20),
    super.capabilityCacheTtl = const Duration(minutes: 5),
    super.clock,
  });
}
