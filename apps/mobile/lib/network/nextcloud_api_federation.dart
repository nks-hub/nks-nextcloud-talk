part of 'nextcloud_api.dart';

mixin _NextcloudApiFederation on _HttpNextcloudApiBase {
  /// Pending invitations into conversations on other servers, as kept by the
  /// account's own server.
  Future<FederationInvitationListResponse> listFederationInvitations({
    required FederationInvitationListRequest listRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(listRequest.httpMethod, listRequest.uri, abortTrigger)
          ..headers.addAll({
            ...listRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 401, 403, 404, 429, 503},
      maximumBytes: federationInvitationMaximumResponseBytes,
      readBodyForStatusCodes: const {200},
    );
    return decodeFederationInvitationListResponse(
      request: listRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Accepts or rejects one invitation; both go to the account's own server.
  Future<FederationInvitationDecisionResponse> decideFederationInvitation({
    required FederationInvitationDecisionRequest decisionRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(decisionRequest.httpMethod, decisionRequest.uri, abortTrigger)
          ..headers.addAll({
            ...decisionRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 400, 401, 404, 410, 429, 503},
      maximumBytes: federationInvitationMaximumResponseBytes,
      readBodyForStatusCodes: const {200},
    );
    return decodeFederationInvitationDecisionResponse(
      request: decisionRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}
