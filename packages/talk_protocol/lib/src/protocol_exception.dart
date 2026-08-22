/// Stable error categories emitted while validating untrusted wire data.
enum TalkProtocolErrorCode {
  invalidServerAddress,
  insecureServerAddress,
  invalidServerHost,
  invalidServerPath,
  invalidServerStatus,
  invalidLoginInitialization,
  untrustedLoginEndpoint,
  invalidLoginCredentials,
  untrustedCredentialServer,
  invalidCapabilities,
  ocsFailure,
  invalidConversationIdentifier,
  invalidConversationRequest,
  invalidConversationResponse,
  invalidConversationHeaders,
  duplicateConversationToken,
  previewConversationMismatch,
  invalidConversationMerge,
  invalidChatIdentifier,
  invalidChatProfile,
  invalidChatRequest,
  invalidChatResponse,
  invalidChatHeaders,
  invalidChatState,
  invalidChatMerge,
  invalidChatOutbox,
  unsupportedChatOperation,
  unsupportedHttpStatus,
}

/// A redacted protocol error that never includes an untrusted field value.
final class TalkProtocolException implements Exception {
  const TalkProtocolException(this.code, {required this.path});

  final TalkProtocolErrorCode code;
  final String path;

  @override
  String toString() => 'TalkProtocolException(code: ${code.name}, path: $path)';
}

Never protocolFailure(TalkProtocolErrorCode code, String path) =>
    throw TalkProtocolException(code, path: path);
