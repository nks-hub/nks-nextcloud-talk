part of 'nextcloud_api.dart';

const _statusMaximumBytes = 64 * 1024;
const _loginMaximumBytes = 128 * 1024;
const _capabilitiesMaximumBytes = 2 * 1024 * 1024;
const _conversationMaximumBytes = 16 * 1024 * 1024;
const _recipientSearchMaximumBytes = 1 * 1024 * 1024;
const _messageSearchMaximumBytes = 1 * 1024 * 1024;
const _messageSearchAllowedStatusCodes = {200, 401, 404, 429, 503};
const _createConversationMaximumBytes = 1 * 1024 * 1024;
const _avatarMaximumBytes = 2 * 1024 * 1024;
const _webPushMaximumBytes = 64 * 1024;
const _appPasswordMaximumBytes = 64 * 1024;
const _participantsMaximumBytes = 2 * 1024 * 1024;
const _mentionsMaximumBytes = 1 * 1024 * 1024;
const _mentionsAllowedStatusCodes = {200, 401, 404, 429, 503};
final Set<int> _richChatAllowedStatusCodes = Set.unmodifiable({
  200,
  201,
  202,
  ...Iterable<int>.generate(200, (index) => 400 + index),
});

const _chatGetAllowedStatusCodes = {200, 304, 401, 404, 429, 503};
const _signalingSettingsAllowedStatusCodes = {200, 401, 404, 500, 503};
const _participantsAllowedStatusCodes = {200, 401, 403, 404, 429, 503};
const _participantModerationAllowedStatusCodes = {
  200,
  400,
  401,
  403,
  404,
  429,
  503,
};
const _roomSettingsMaximumBytes = 2 * 1024 * 1024;
const _roomDetailUpdateAllowedStatusCodes = {200, 401, 403, 404, 429, 503};
const _roomSettingsMutationAllowedStatusCodes = {200, 401, 404, 429, 503};

/// Shared by leaving and deleting a conversation: both answer `400` for a
/// refusal the caller has to explain and `403` when the participant lacks
/// the required role.
const _roomRemovalAllowedStatusCodes = {200, 400, 401, 403, 404, 429, 503};

/// Shared by every moderator-only administration endpoint (public,
/// password, lobby, read-only, avatar) and by the ban API: all of them
/// answer `400` for a refusal the caller has to explain, `403` for a
/// non-moderator and `404` for an unknown room.
const _roomAdministrationAllowedStatusCodes = {
  200,
  400,
  401,
  403,
  404,
  429,
  503,
};
const _chatReadAllowedStatusCodes = {200, 401, 404, 429, 503};
final Set<int> _chatSendAllowedStatusCodes = Set.unmodifiable({
  200,
  201,
  ...Iterable<int>.generate(200, (index) => 400 + index),
});

abstract class _HttpNextcloudApiBase {
  _HttpNextcloudApiBase({
    http.Client? client,
    this.originPolicy = ServerOriginPolicy.production,
    this.requestTimeout = const Duration(seconds: 20),
    this.capabilityCacheTtl = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final ServerOriginPolicy originPolicy;
  final Duration requestTimeout;
  final Duration capabilityCacheTtl;
  final DateTime Function() _clock;

  /// In-memory only: a capability snapshot is server truth that must never
  /// outlive the process that verified the credentials behind it, and the part
  /// the app needs across restarts is already persisted as Talk features in
  /// `chat_capabilities`.
  ///
  /// Keyed by server plus login name so two accounts — or the same login on two
  /// servers — can never read each other's snapshot. Each entry also carries a
  /// fingerprint of the Authorization header, so a rotated app password misses
  /// the cache instead of reusing the snapshot of the revoked session.
  final Map<String, _CachedCapabilities> _capabilityCache = {};

  /// Any authenticated request answered with 401 means the session behind those
  /// credentials no longer holds the authority the snapshot was read under, so
  /// the snapshot is dropped before the caller can gate a feature on it.
  void _invalidateCapabilitiesForCredentials(String? authorization) {
    if (authorization == null) {
      return;
    }
    final fingerprint = _credentialFingerprint(authorization);
    _capabilityCache.removeWhere(
      (_, entry) => entry.credentialFingerprint == fingerprint,
    );
  }

  Future<_JsonPayload> _sendJson(
    http.Request request, {
    required Set<int> allowedStatusCodes,
    required int maximumBytes,
    Set<int>? parseBodyForStatusCodes,
  }) async {
    final payload = await _sendBody(
      request,
      allowedStatusCodes: allowedStatusCodes,
      maximumBytes: maximumBytes,
      readBodyForStatusCodes: parseBodyForStatusCodes,
    );
    final shouldParse =
        parseBodyForStatusCodes?.contains(payload.statusCode) ?? true;
    if (!shouldParse) {
      return _JsonPayload(
        statusCode: payload.statusCode,
        json: null,
        headers: payload.headers,
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(payload.body));
    } on FormatException {
      throw const NextcloudApiException(NextcloudApiError.invalidJson);
    }
    return _JsonPayload(
      statusCode: payload.statusCode,
      json: json,
      headers: payload.headers,
    );
  }

  http.Request _authenticatedOcsRequest(
    String method,
    Uri uri, {
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) {
    return _request(method, uri, abortTrigger)
      ..headers.addAll({
        'Accept': 'application/json',
        'OCS-APIRequest': 'true',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
  }

  Uri _webPushUri(ServerBase server, [String? suffix]) {
    final basePath = server.basePath;
    final tail = suffix == null ? '' : '/$suffix';
    return server.uri.replace(
      path: '$basePath/ocs/v2.php/apps/notifications/api/v2/webpush$tail',
      queryParameters: const {'format': 'json'},
    );
  }

  Uri _appPasswordUri(ServerBase server) {
    return server.uri.replace(
      path: '${server.basePath}/ocs/v2.php/core/apppassword',
      queryParameters: const {'format': 'json'},
    );
  }

  Object? _webPushOcsData(
    _JsonPayload payload, {
    required Set<int> expectedStatusCodes,
  }) {
    final root = payload.json;
    if (root is! Map<String, Object?>) {
      throw const NextcloudApiException(
        NextcloudApiError.invalidWebPushResponse,
      );
    }
    final ocs = root['ocs'];
    if (ocs is! Map<String, Object?>) {
      throw const NextcloudApiException(
        NextcloudApiError.invalidWebPushResponse,
      );
    }
    final meta = ocs['meta'];
    if (meta is! Map<String, Object?> ||
        meta['status'] != 'ok' ||
        meta['statuscode'] is! int ||
        !expectedStatusCodes.contains(meta['statuscode'])) {
      throw const NextcloudApiException(
        NextcloudApiError.invalidWebPushResponse,
      );
    }
    return ocs['data'];
  }

  /// Sends a request and reads its body. Typed as [http.BaseRequest] rather
  /// than [http.Request] so a multipart upload — the conversation avatar — can
  /// use the same status-code, size and timeout handling as everything else.
  Future<_BodyPayload> _sendBody(
    http.BaseRequest request, {
    required Set<int> allowedStatusCodes,
    required int maximumBytes,
    Set<int>? readBodyForStatusCodes,
    Duration? timeout,
  }) async {
    request
      ..followRedirects = false
      ..maxRedirects = 0;
    final effectiveTimeout = timeout ?? requestTimeout;
    try {
      final response = await _client.send(request).timeout(effectiveTimeout);
      if (response.statusCode == 401) {
        _invalidateCapabilitiesForCredentials(request.headers['Authorization']);
      }
      if (!allowedStatusCodes.contains(response.statusCode)) {
        await response.stream.drain<void>();
        throw NextcloudApiException(
          NextcloudApiError.unexpectedStatus,
          statusCode: response.statusCode,
        );
      }
      final shouldRead =
          readBodyForStatusCodes?.contains(response.statusCode) ?? true;
      if (!shouldRead) {
        await response.stream.drain<void>();
        return _BodyPayload(
          statusCode: response.statusCode,
          body: Uint8List(0),
          headers: response.headers,
        );
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maximumBytes) {
        await response.stream.drain<void>();
        throw const NextcloudApiException(NextcloudApiError.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.stream.timeout(effectiveTimeout)) {
        length += chunk.length;
        if (length > maximumBytes) {
          throw const NextcloudApiException(NextcloudApiError.responseTooLarge);
        }
        bytes.add(chunk);
      }
      return _BodyPayload(
        statusCode: response.statusCode,
        body: bytes.takeBytes(),
        headers: response.headers,
      );
    } on http.RequestAbortedException {
      throw const NextcloudApiException(NextcloudApiError.cancelled);
    } on TimeoutException {
      throw const NextcloudApiException(NextcloudApiError.timeout);
    } on http.ClientException {
      throw const NextcloudApiException(NextcloudApiError.network);
    }
  }

  void close() => _client.close();

  Duration _chatRequestTimeout(int serverTimeoutSeconds) {
    if (serverTimeoutSeconds == 0) {
      return requestTimeout;
    }
    final longPollTimeout = Duration(seconds: serverTimeoutSeconds + 15);
    return requestTimeout > longPollTimeout ? requestTimeout : longPollTimeout;
  }
}

bool? _optionalBooleanHeader(String? value) {
  return switch (value?.trim()) {
    '0' => false,
    '1' => true,
    _ => null,
  };
}

final class _BodyPayload {
  const _BodyPayload({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final Uint8List body;
  final Map<String, String> headers;
}

final class _JsonPayload {
  const _JsonPayload({
    required this.statusCode,
    required this.json,
    required this.headers,
  });

  final int statusCode;
  final Object? json;
  final Map<String, String> headers;
}

String _basicAuthorization(String loginName, String appPassword) {
  final bytes = Uint8List.fromList(utf8.encode('$loginName:$appPassword'));
  return 'Basic ${base64Encode(bytes)}';
}

/// Digest of the Authorization header, so credential rotation can be detected
/// without the cache ever retaining the header, the login name or the password.
String _credentialFingerprint(String authorization) =>
    sha256.convert(utf8.encode(authorization)).toString();

final class _CachedCapabilities {
  const _CachedCapabilities({
    required this.credentialFingerprint,
    required this.snapshot,
    required this.expiresAt,
  });

  final String credentialFingerprint;
  final Future<CapabilitySnapshot> snapshot;
  final DateTime expiresAt;
}

bool _isAllowedAvatarUri(ServerBase server, Uri avatarUri) {
  if (!server.hasSameOrigin(avatarUri) ||
      avatarUri.userInfo.isNotEmpty ||
      avatarUri.fragment.isNotEmpty) {
    return false;
  }
  final base = server.uri.pathSegments;
  final actual = avatarUri.pathSegments;
  final talkPrefix = <String>[
    ...base,
    'ocs',
    'v2.php',
    'apps',
    'spreed',
    'api',
    'v1',
    'room',
  ];
  if (_startsWithSegments(actual, talkPrefix)) {
    final suffix = actual.sublist(talkPrefix.length);
    final validSuffix =
        suffix.length >= 2 &&
        suffix[0].isNotEmpty &&
        suffix[1] == 'avatar' &&
        (suffix.length == 2 || (suffix.length == 3 && suffix[2] == 'dark'));
    return validSuffix &&
        avatarUri.queryParameters.keys.every((key) => key == 'avatarVersion');
  }

  final userPrefix = <String>[...base, 'index.php', 'avatar'];
  if (_startsWithSegments(actual, userPrefix)) {
    final suffix = actual.sublist(userPrefix.length);
    return avatarUri.query.isEmpty &&
        suffix.length >= 2 &&
        suffix[0].isNotEmpty &&
        suffix[1] == '64' &&
        (suffix.length == 2 || (suffix.length == 3 && suffix[2] == 'dark'));
  }
  return false;
}

bool _startsWithSegments(List<String> actual, List<String> prefix) {
  if (actual.length < prefix.length) {
    return false;
  }
  for (var index = 0; index < prefix.length; index++) {
    if (actual[index] != prefix[index]) {
      return false;
    }
  }
  return true;
}

http.Request _request(String method, Uri uri, Future<void>? abortTrigger) {
  return abortTrigger == null
      ? http.Request(method, uri)
      : http.AbortableRequest(method, uri, abortTrigger: abortTrigger);
}

String _richChatHttpMethod(RichChatHttpMethod method) => switch (method) {
  RichChatHttpMethod.get => 'GET',
  RichChatHttpMethod.post => 'POST',
  RichChatHttpMethod.put => 'PUT',
  RichChatHttpMethod.delete => 'DELETE',
};
