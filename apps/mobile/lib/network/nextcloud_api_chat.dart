part of 'nextcloud_api.dart';

mixin _NextcloudApiChat on _HttpNextcloudApiBase {
  Future<LocationShareResponse> shareLocation({
    required LocationShareRequest locationRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', locationRequest.uri, abortTrigger)
      ..headers.addAll({
        ...locationRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = locationRequest.formBody.map(
        (key, value) => MapEntry(key, value.toString()),
      );
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {
        201,
        400,
        401,
        403,
        404,
        413,
        429,
        500,
        502,
        503,
        504,
      },
      maximumBytes: locationShareMaximumResponseBytes,
      readBodyForStatusCodes: const {201},
    );
    return decodeLocationShareResponse(
      request: locationRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  Future<SharedItemsOverviewResponse> getSharedItemsOverview({
    required SharedItemsOverviewRequest overviewRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', overviewRequest.uri, abortTrigger)
      ..headers.addAll({
        ...overviewRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _sharedItemsAllowedStatusCodes,
      maximumBytes: sharedItemsMaximumResponseBytes,
    );
    return decodeSharedItemsOverviewResponse(
      request: overviewRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  Future<SharedItemsPageResponse> getSharedItemsPage({
    required SharedItemsPageRequest pageRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', pageRequest.uri, abortTrigger)
      ..headers.addAll({
        ...pageRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _sharedItemsAllowedStatusCodes,
      maximumBytes: sharedItemsMaximumResponseBytes,
    );
    return decodeSharedItemsPageResponse(
      request: pageRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: ChatResponseHeaders.fromMap(payload.headers),
    );
  }

  Future<PrivateReplyParentContextResponse> getPrivateReplyParentContext({
    required PrivateReplyParentContextRequest contextRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', contextRequest.uri, abortTrigger)
      ..headers.addAll({
        ...contextRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 304, 401, 403, 404, 429, 503},
      maximumBytes: chatMaximumResponseBytes,
    );
    return decodePrivateReplyParentContextResponse(
      request: contextRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: ChatResponseHeaders.fromMap(payload.headers),
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

  /// Moves the read marker to [ChatSetReadMarkerRequest.lastReadMessage].
  Future<ChatReadResponse> markChatRead({
    required ChatSetReadMarkerRequest readRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final formBody = readRequest.formBody;
    if (formBody is! Map<String, Object>) {
      throw const NextcloudApiException(NextcloudApiError.invalidJson);
    }
    final request = _request('POST', readRequest.uri, abortTrigger)
      ..headers.addAll({
        ...readRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = formBody.map(
        (key, value) => MapEntry(key, value.toString()),
      );
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _chatReadAllowedStatusCodes,
      maximumBytes: chatMaximumResponseBytes,
    );
    return decodeChatReadResponse(
      request: readRequest,
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
}
