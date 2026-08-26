part of 'request.dart';

/// Changes whether this participant treats a conversation as important.
///
/// Evidence: Talk `f2958bb25be6604240c58a3faf9a2033a30d20e5`,
/// `RoomController::markConversationAsImportant` and
/// `RoomController::markConversationAsUnimportant`. Both v4 endpoints accept
/// every logged-in participant, require `important-conversations`, and carry
/// no form or query fields.
final class SetImportantRequest {
  SetImportantRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    required this.important,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    _requireAuthenticatedFeature(capabilities, 'important-conversations');
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final bool important;
  final String userAgent;

  String get httpMethod => important ? 'POST' : 'DELETE';

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'important');

  @override
  String toString() => 'SetImportantRequest(important: $important)';
}

/// Changes whether previews for this participant's conversation are hidden.
///
/// Evidence: Talk `f2958bb25be6604240c58a3faf9a2033a30d20e5`,
/// `RoomController::markConversationAsSensitive` and
/// `RoomController::markConversationAsInsensitive`. Both v4 endpoints accept
/// every logged-in participant, require `sensitive-conversations`, and carry
/// no form or query fields. Classified rooms reject the DELETE variant.
final class SetSensitiveRequest {
  SetSensitiveRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    required this.sensitive,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    _requireAuthenticatedFeature(capabilities, 'sensitive-conversations');
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final bool sensitive;
  final String userAgent;

  String get httpMethod => sensitive ? 'POST' : 'DELETE';

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'sensitive');

  @override
  String toString() => 'SetSensitiveRequest(sensitive: $sensitive)';
}

void _requireAuthenticatedFeature(
  CapabilitySnapshot capabilities,
  String feature,
) {
  if (capabilities.context != CapabilityContext.authenticated ||
      !capabilities.supportsTalk(feature)) {
    protocolFailure(_requestCode, r'$.capabilities.' + feature);
  }
}
