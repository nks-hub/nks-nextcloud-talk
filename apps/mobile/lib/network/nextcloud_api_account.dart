part of 'nextcloud_api.dart';

mixin _NextcloudApiAccount on _HttpNextcloudApiBase {
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
      ..headers['User-Agent'] = loginFlowUserAgent
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
      ..headers['User-Agent'] = loginFlowUserAgent
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
    final read = await getAuthenticatedCapabilitiesWithSource(
      server: server,
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    return read.snapshot;
  }

  /// Reads authenticated capabilities and reports whether transport occurred.
  ///
  /// [forceRefresh] bypasses a valid in-memory snapshot without disabling the
  /// cache for other callers.
  Future<AuthenticatedCapabilityRead> getAuthenticatedCapabilitiesWithSource({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
    bool forceRefresh = false,
  }) async {
    final authorization = _basicAuthorization(loginName, appPassword);
    final fingerprint = _credentialFingerprint(authorization);
    final cacheKey = '${server.uri}\u0000$loginName';
    final now = _clock();
    final cached = _capabilityCache[cacheKey];
    if (!forceRefresh &&
        cached != null &&
        cached.credentialFingerprint == fingerprint &&
        now.isBefore(cached.expiresAt)) {
      return AuthenticatedCapabilityRead(
        snapshot: await cached.snapshot,
        source: CapabilitySnapshotSource.memoryCache,
      );
    }

    final pending = _readCapabilities(
      server: server,
      authorization: authorization,
      abortTrigger: abortTrigger,
    );
    // A cancellable read stays private: a caller that joined it must never have
    // its snapshot torn down by whoever happens to abort first. Every other read
    // is published while still in flight, so the burst of steps that opens a
    // room shares one request instead of racing several identical ones.
    final shared = abortTrigger == null;
    final entry = _CachedCapabilities(
      server: server,
      credentialFingerprint: fingerprint,
      snapshot: pending,
      expiresAt: now.add(capabilityCacheTtl),
    );
    if (shared) {
      _capabilityCache[cacheKey] = entry;
    }
    final CapabilitySnapshot snapshot;
    try {
      snapshot = await pending;
    } on Object {
      // No failure — network, 401, malformed payload — is ever cached, so the
      // next read after an error always reaches the server again.
      if (identical(_capabilityCache[cacheKey], entry)) {
        _capabilityCache.remove(cacheKey);
      }
      rethrow;
    }
    if (!shared) {
      if (forceRefresh) {
        _capabilityCache[cacheKey] = entry;
      } else {
        _capabilityCache[cacheKey] ??= entry;
      }
    }
    return AuthenticatedCapabilityRead(
      snapshot: snapshot,
      source: CapabilitySnapshotSource.network,
    );
  }

  Future<CapabilitySnapshot> _readCapabilities({
    required ServerBase server,
    required String authorization,
    required Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', server.capabilitiesUri, abortTrigger)
      ..headers.addAll({
        'Accept': 'application/json',
        'OCS-APIRequest': 'true',
        'Authorization': authorization,
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

  /// Destroys the app password this request authenticates with.
  ///
  /// Nextcloud documents `DELETE /ocs/v2.php/core/apppassword` for exactly
  /// this housekeeping step and specifies a plain OCS response with status
  /// 200, so anything else is reported as a failure rather than treated as a
  /// completed revocation. The same documentation tells clients to remove the
  /// account even when the call does not return 200, which is why every
  /// caller has to keep going after this throws.
  Future<void> revokeAppPassword({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      'DELETE',
      _appPasswordUri(server),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200},
      maximumBytes: _appPasswordMaximumBytes,
    );
    final root = payload.json;
    final ocs = root is Map<String, Object?> ? root['ocs'] : null;
    final meta = ocs is Map<String, Object?> ? ocs['meta'] : null;
    if (meta is! Map<String, Object?> ||
        meta['status'] != 'ok' ||
        meta['statuscode'] != 200) {
      throw const NextcloudApiException(
        NextcloudApiError.unexpectedStatus,
        statusCode: 200,
      );
    }
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

  /// Searches Talk messages via Nextcloud's unified search providers.
  Future<MessageSearchResponse> searchMessages({
    required MessageSearchRequest searchRequest,
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
      allowedStatusCodes: _messageSearchAllowedStatusCodes,
      maximumBytes: _messageSearchMaximumBytes,
      parseBodyForStatusCodes: const {200},
    );
    return decodeMessageSearchResponse(
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
}
