import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

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

final class HttpNextcloudApi {
  HttpNextcloudApi({
    http.Client? client,
    this.originPolicy = ServerOriginPolicy.production,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  static const _statusMaximumBytes = 64 * 1024;
  static const _loginMaximumBytes = 128 * 1024;
  static const _capabilitiesMaximumBytes = 2 * 1024 * 1024;
  static const _conversationMaximumBytes = 16 * 1024 * 1024;
  static const _recipientSearchMaximumBytes = 1 * 1024 * 1024;
  static const _createConversationMaximumBytes = 1 * 1024 * 1024;
  static const _avatarMaximumBytes = 2 * 1024 * 1024;
  static const _webPushMaximumBytes = 64 * 1024;
  static const _participantsMaximumBytes = 2 * 1024 * 1024;
  static const _mentionsMaximumBytes = 1 * 1024 * 1024;
  static const _mentionsAllowedStatusCodes = {200, 401, 404, 429, 503};
  static final Set<int> _richChatAllowedStatusCodes = Set.unmodifiable({
    200,
    201,
    202,
    ...Iterable<int>.generate(200, (index) => 400 + index),
  });

  static const _chatGetAllowedStatusCodes = {200, 304, 401, 404, 429, 503};
  static const _signalingSettingsAllowedStatusCodes = {200, 401, 404, 500, 503};
  static const _participantsAllowedStatusCodes = {
    200,
    401,
    403,
    404,
    429,
    503,
  };
  static const _roomSettingsMaximumBytes = 2 * 1024 * 1024;
  static const _roomDetailUpdateAllowedStatusCodes = {
    200,
    401,
    403,
    404,
    429,
    503,
  };
  static const _roomSettingsMutationAllowedStatusCodes = {
    200,
    401,
    404,
    429,
    503,
  };
  static const _leaveRoomAllowedStatusCodes = {
    200,
    400,
    401,
    403,
    404,
    429,
    503,
  };
  static const _chatReadAllowedStatusCodes = {200, 401, 404, 429, 503};
  static final Set<int> _chatSendAllowedStatusCodes = Set.unmodifiable({
    200,
    201,
    ...Iterable<int>.generate(200, (index) => 400 + index),
  });

  final http.Client _client;
  final ServerOriginPolicy originPolicy;
  final Duration requestTimeout;

  Future<ServerStatus> getServerStatus(ServerBase server) async {
    final payload = await _sendJson(
      http.Request('GET', server.statusUri),
      allowedStatusCodes: const {200},
      maximumBytes: _statusMaximumBytes,
    );
    return ServerStatus.fromJson(payload.json);
  }

  Future<LoginFlowInitialization> initializeLogin(ServerBase server) async {
    final request = http.Request('POST', server.loginFlowV2Uri)
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
      ..body = '';
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200},
      maximumBytes: _loginMaximumBytes,
    );
    return LoginFlowInitialization.fromJson(
      payload.json,
      verifiedServer: server,
      policy: originPolicy,
    );
  }

  Future<LoginPollResult> pollLogin(PendingLogin pending) async {
    final request = http.Request('POST', pending.initialization.pollEndpoint)
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
      ..body = pending.initialization.pollFormBody;
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 404},
      maximumBytes: _loginMaximumBytes,
      parseBodyForStatusCodes: const {200},
    );
    return parseLoginPollResponse(
      statusCode: payload.statusCode,
      json: payload.json,
      verifiedServer: pending.server,
      policy: originPolicy,
    );
  }

  Future<CapabilitySnapshot> getAuthenticatedCapabilities({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', server.capabilitiesUri, abortTrigger)
      ..headers.addAll({
        'Accept': 'application/json',
        'OCS-APIRequest': 'true',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200},
      maximumBytes: _capabilitiesMaximumBytes,
    );
    return CapabilitySnapshot.fromJson(
      payload.json,
      context: CapabilityContext.authenticated,
    );
  }

  Future<String> getWebPushVapid({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      'GET',
      _webPushUri(server, 'vapid'),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200},
      maximumBytes: _webPushMaximumBytes,
    );
    final data = _webPushOcsData(payload, expectedStatusCodes: const {200});
    if (data is! Map<String, Object?>) {
      throw const NextcloudApiException(
        NextcloudApiError.invalidWebPushResponse,
      );
    }
    final vapid = data['vapid'];
    if (vapid is! String || !RegExp(r'^[A-Za-z0-9_-]{87}$').hasMatch(vapid)) {
      throw const NextcloudApiException(
        NextcloudApiError.invalidWebPushResponse,
      );
    }
    return vapid;
  }

  Future<WebPushRegistrationStatus> registerWebPush({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required String endpoint,
    required String uaPublicKey,
    required String authSecret,
    Future<void>? abortTrigger,
  }) async {
    final endpointUri = Uri.tryParse(endpoint);
    if (endpoint.length > 765 ||
        endpointUri == null ||
        endpointUri.scheme != 'https' ||
        endpointUri.host.isEmpty ||
        endpointUri.userInfo.isNotEmpty ||
        endpointUri.fragment.isNotEmpty ||
        !_webPushP256dhPattern.hasMatch(uaPublicKey) ||
        !_webPushAuthPattern.hasMatch(authSecret)) {
      throw const NextcloudApiException(
        NextcloudApiError.invalidWebPushResponse,
      );
    }
    final request =
        _authenticatedOcsRequest(
            'POST',
            _webPushUri(server),
            loginName: loginName,
            appPassword: appPassword,
            abortTrigger: abortTrigger,
          )
          ..bodyFields = <String, String>{
            'endpoint': endpoint,
            'uaPublicKey': uaPublicKey,
            'auth': authSecret,
            'appTypes': 'all',
          };
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 201},
      maximumBytes: _webPushMaximumBytes,
    );
    _webPushOcsData(payload, expectedStatusCodes: const {200, 201});
    return payload.statusCode == 201
        ? WebPushRegistrationStatus.activationRequired
        : WebPushRegistrationStatus.active;
  }

  Future<void> activateWebPush({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required String activationToken,
    Future<void>? abortTrigger,
  }) async {
    if (!_uuidV4Pattern.hasMatch(activationToken)) {
      throw const NextcloudApiException(
        NextcloudApiError.invalidWebPushResponse,
      );
    }
    final request = _authenticatedOcsRequest(
      'POST',
      _webPushUri(server, 'activate'),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    )..bodyFields = <String, String>{'activationToken': activationToken};
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 202},
      maximumBytes: _webPushMaximumBytes,
    );
    _webPushOcsData(payload, expectedStatusCodes: const {200, 202});
  }

  Future<void> unregisterWebPush({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      'DELETE',
      _webPushUri(server),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 202},
      maximumBytes: _webPushMaximumBytes,
    );
    _webPushOcsData(payload, expectedStatusCodes: const {200, 202});
  }

  Future<ConversationListResponse> getConversations({
    required ConversationListRequest conversationRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', conversationRequest.uri, abortTrigger)
      ..headers.addAll({
        ...conversationRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 401, 426, 429, 503},
      maximumBytes: _conversationMaximumBytes,
      parseBodyForStatusCodes: const {200, 401},
    );
    return decodeConversationListResponse(
      request: conversationRequest,
      statusCode: payload.statusCode,
      json: payload.json,
      headers: payload.headers,
    );
  }

  /// Looks up people and groups that can be invited into a new conversation.
  Future<RecipientSearchResponse> searchRecipients({
    required RecipientSearchRequest searchRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', searchRequest.uri, abortTrigger)
      ..headers.addAll({
        ...searchRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 401},
      maximumBytes: _recipientSearchMaximumBytes,
    );
    return decodeRecipientSearchResponse(
      request: searchRequest,
      statusCode: payload.statusCode,
      json: payload.json,
    );
  }

  /// Creates a new one-to-one or group conversation for a picked recipient.
  Future<CreateConversationResponse> createConversation({
    required CreateConversationRequest createRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', createRequest.uri, abortTrigger)
      ..headers.addAll({
        ...createRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = createRequest.formBody;
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 401, 429, 503},
      maximumBytes: _createConversationMaximumBytes,
      parseBodyForStatusCodes: const {200, 401},
    );
    return decodeCreateConversationResponse(
      request: createRequest,
      statusCode: payload.statusCode,
      json: payload.json,
    );
  }

  /// Resolves how a room's call would be signalled. It is the first step of
  /// any call and is deliberately separate from media handling.
  Future<SignalingSettingsResponse> getSignalingSettings({
    required SignalingSettingsRequest settingsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', settingsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...settingsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _signalingSettingsAllowedStatusCodes,
      maximumBytes: chatMaximumResponseBytes,
      timeout: const Duration(seconds: 20),
    );
    return decodeSignalingSettingsResponse(
      request: settingsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Read-only room participant list, including role and (when the server
  /// returns it) each attendee's user status.
  Future<ParticipantsResponse> getParticipants({
    required ParticipantsRequest participantsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', participantsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...participantsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _participantsAllowedStatusCodes,
      maximumBytes: _participantsMaximumBytes,
    );
    return decodeParticipantsResponse(
      request: participantsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Renames a conversation. Moderator-only on the server.
  Future<UpdateRoomNameResponse> updateRoomName({
    required UpdateRoomNameRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('PUT', updateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...updateRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = updateRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomDetailUpdateAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeUpdateRoomNameResponse(
      request: updateRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Changes a conversation's description. Moderator-only on the server.
  Future<UpdateRoomDescriptionResponse> updateRoomDescription({
    required UpdateRoomDescriptionRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('PUT', updateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...updateRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = updateRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomDetailUpdateAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeUpdateRoomDescriptionResponse(
      request: updateRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Sets the caller's own per-conversation notification level.
  Future<UpdateNotificationLevelResponse> updateNotificationLevel({
    required UpdateNotificationLevelRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', updateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...updateRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = updateRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSettingsMutationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeUpdateNotificationLevelResponse(
      request: updateRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Marks or unmarks a conversation as one of the caller's favorites.
  Future<SetFavoriteResponse> setFavorite({
    required SetFavoriteRequest favoriteRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request(favoriteRequest.httpMethod, favoriteRequest.uri, abortTrigger)
      ..headers.addAll({
        ...favoriteRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSettingsMutationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeSetFavoriteResponse(
      request: favoriteRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Archives or unarchives a conversation for the caller.
  Future<SetArchivedResponse> setArchived({
    required SetArchivedRequest archivedRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request(archivedRequest.httpMethod, archivedRequest.uri, abortTrigger)
      ..headers.addAll({
        ...archivedRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSettingsMutationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeSetArchivedResponse(
      request: archivedRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Removes the caller from a conversation. Irreversible from the client's
  /// point of view.
  Future<LeaveRoomResponse> leaveRoom({
    required LeaveRoomRequest leaveRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('DELETE', leaveRequest.uri, abortTrigger)
      ..headers.addAll({
        ...leaveRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _leaveRoomAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeLeaveRoomResponse(
      request: leaveRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  Future<ChatGetResponse> getChat({
    required ChatFetchRequest chatRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', chatRequest.uri, abortTrigger)
      ..headers.addAll({
        ...chatRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _chatGetAllowedStatusCodes,
      maximumBytes: chatMaximumResponseBytes,
      timeout: _chatRequestTimeout(chatRequest.timeoutSeconds),
    );
    return decodeChatGetResponse(
      request: chatRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: ChatResponseHeaders.fromMap(payload.headers),
    );
  }

  Future<RichChatResponse> getMentionSuggestions({
    required RichChatRequest request,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final httpRequest = _request('GET', request.uri, abortTrigger)
      ..headers.addAll({
        ...request.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      httpRequest,
      allowedStatusCodes: _mentionsAllowedStatusCodes,
      maximumBytes: _mentionsMaximumBytes,
    );
    return decodeRichChatResponse(
      request: request,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  Future<ChatSendResponse> sendChat({
    required ChatSendRequest chatRequest,
    required String loginName,
    required String appPassword,
  }) async {
    final formBody = chatRequest.formBody;
    if (formBody is! Map<String, Object>) {
      throw const NextcloudApiException(NextcloudApiError.invalidJson);
    }
    final request = http.Request('POST', chatRequest.uri)
      ..headers.addAll({
        ...chatRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = formBody.map(
        (key, value) => MapEntry(key, value.toString()),
      );
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _chatSendAllowedStatusCodes,
      maximumBytes: chatMaximumResponseBytes,
    );
    return decodeChatSendResponse(
      request: chatRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: ChatResponseHeaders.fromMap(payload.headers),
    );
  }

  /// Clears the read marker so the conversation shows as unread again.
  Future<ChatReadResponse> markChatUnread({
    required ChatMarkUnreadRequest markUnreadRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('DELETE', markUnreadRequest.uri, abortTrigger)
      ..headers.addAll({
        ...markUnreadRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _chatReadAllowedStatusCodes,
      maximumBytes: chatMaximumResponseBytes,
    );
    return decodeChatReadResponse(
      request: markUnreadRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: ChatResponseHeaders.fromMap(payload.headers),
    );
  }

  Future<AvatarResponse> getAvatar({
    required ServerBase server,
    required Uri avatarUri,
    required String loginName,
    required String appPassword,
    String? ifNoneMatch,
    String? ifModifiedSince,
  }) async {
    if (!_isAllowedAvatarUri(server, avatarUri)) {
      throw const NextcloudApiException(NextcloudApiError.invalidAvatarUri);
    }
    final request = http.Request('GET', avatarUri)
      ..headers.addAll({
        'Accept': 'image/png,image/jpeg,image/webp,image/gif,image/svg+xml',
        'OCS-APIRequest': 'true',
        'Authorization': _basicAuthorization(loginName, appPassword),
        'If-None-Match': ?ifNoneMatch,
        'If-Modified-Since': ?ifModifiedSince,
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 304, 404},
      maximumBytes: _avatarMaximumBytes,
      readBodyForStatusCodes: const {200},
    );
    final status = switch (payload.statusCode) {
      200 => AvatarResponseStatus.image,
      304 => AvatarResponseStatus.notModified,
      404 => AvatarResponseStatus.notFound,
      _ => throw const NextcloudApiException(
        NextcloudApiError.unexpectedStatus,
      ),
    };
    String? contentType;
    if (status == AvatarResponseStatus.image) {
      contentType = payload.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (payload.body.isEmpty ||
          !const {
            'image/png',
            'image/jpeg',
            'image/webp',
            'image/gif',
            'image/svg+xml',
          }.contains(contentType)) {
        throw const NextcloudApiException(
          NextcloudApiError.invalidAvatarResponse,
        );
      }
    }
    return AvatarResponse(
      status: status,
      body: payload.body,
      contentType: contentType,
      isCustomAvatar: status == AvatarResponseStatus.image
          ? _optionalBooleanHeader(payload.headers['x-nc-iscustomavatar'])
          : null,
      cacheControl: payload.headers['cache-control'],
      etag: payload.headers['etag'],
      lastModified: payload.headers['last-modified'],
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

  Future<_BodyPayload> _sendBody(
    http.Request request, {
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

  /// Edits/deletes a message or adds/removes a reaction. Every one of these
  /// mutations returns an OCS envelope the protocol layer decodes and
  /// classifies on its own, so the transport only has to accept the wider
  /// status-code range `decodeRichChatResponse` knows how to interpret.
  Future<RichChatResponse> sendRichChat({
    required RichChatRequest richChatRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            _richChatHttpMethod(richChatRequest.method),
            richChatRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...richChatRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final formBody = richChatRequest.formBody;
    if (formBody != null) {
      request.bodyFields = formBody.map(
        (key, value) => MapEntry(key, value.toString()),
      );
    }
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _richChatAllowedStatusCodes,
      maximumBytes: richChatMaximumResponseBytes,
    );
    return decodeRichChatResponse(
      request: richChatRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
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
