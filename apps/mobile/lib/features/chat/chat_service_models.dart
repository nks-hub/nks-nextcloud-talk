part of 'chat_service.dart';

final class _ChatSynchronizationCancelled implements Exception {
  const _ChatSynchronizationCancelled();
}

final class _ChatSynchronizationStale implements Exception {
  const _ChatSynchronizationStale();
}

final class _UnknownThreadNotFound implements Exception {
  const _UnknownThreadNotFound();
}

final class _PreparedChat {
  const _PreparedChat({
    required this.account,
    required this.conversation,
    required this.room,
    required this.threadId,
    required this.networkThreadId,
    required this.namedThread,
    required this.appPassword,
    required this.profile,
    required this.capabilityFingerprint,
    required this.capabilitiesVerifiedOnline,
    required this.authority,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final ConversationRoom room;
  final int? threadId;
  final int? networkThreadId;
  final bool? namedThread;
  final String appPassword;
  final ChatCapabilityProfile profile;
  final String capabilityFingerprint;
  final bool capabilitiesVerifiedOnline;
  final ChatTextSendAuthority authority;

  _PreparedChat asRootBackedView() => _PreparedChat(
    account: account,
    conversation: conversation,
    room: room,
    threadId: threadId,
    networkThreadId: null,
    namedThread: false,
    appPassword: appPassword,
    profile: profile,
    capabilityFingerprint: capabilityFingerprint,
    capabilitiesVerifiedOnline: capabilitiesVerifiedOnline,
    authority: authority,
  );

  _PreparedChat asNamedThread() => _PreparedChat(
    account: account,
    conversation: conversation,
    room: room,
    threadId: threadId,
    networkThreadId: threadId,
    namedThread: true,
    appPassword: appPassword,
    profile: profile,
    capabilityFingerprint: capabilityFingerprint,
    capabilitiesVerifiedOnline: capabilitiesVerifiedOnline,
    authority: authority,
  );
}

final class _PreparedCapabilities {
  const _PreparedCapabilities({
    required this.talkFeatures,
    required this.fingerprint,
    required this.generation,
    required this.verifiedOnline,
    required this.readPrivacyIsPublic,
  });

  final Set<String> talkFeatures;
  final String fingerprint;
  final int generation;
  final bool verifiedOnline;

  /// Whether this account shares its read markers, which decides if the
  /// server reports a common read cursor at all. It is not part of the Talk
  /// feature list, so it only survives alongside a live snapshot; the cached
  /// path leaves it false rather than assuming a marker that may never come.
  final bool readPrivacyIsPublic;
}

bool _conversationIsFederated(CachedConversation conversation) {
  try {
    return ConversationRoom.fromJson(
      jsonDecode(conversation.rawJson),
    ).isFederated;
  } on FormatException {
    throw const ChatServiceException(ChatServiceError.invalidResponse);
  }
}

ChatServiceError _mapApiError(NextcloudApiException error) {
  return switch (error.statusCode) {
    401 => ChatServiceError.reauthenticationRequired,
    429 => ChatServiceError.rateLimited,
    500 || 502 || 503 || 504 => ChatServiceError.serviceUnavailable,
    _ => switch (error.code) {
      NextcloudApiError.network ||
      NextcloudApiError.timeout => ChatServiceError.network,
      NextcloudApiError.cancelled =>
        throw const _ChatSynchronizationCancelled(),
      NextcloudApiError.responseTooLarge ||
      NextcloudApiError.invalidJson ||
      NextcloudApiError.invalidAvatarUri ||
      NextcloudApiError.invalidAvatarResponse ||
      NextcloudApiError.invalidWebPushResponse ||
      NextcloudApiError.unexpectedStatus => ChatServiceError.invalidResponse,
    },
  };
}

bool _isTransientCapabilityFailure(NextcloudApiException error) {
  if (error.statusCode == 429 ||
      error.statusCode == 500 ||
      error.statusCode == 502 ||
      error.statusCode == 503 ||
      error.statusCode == 504) {
    return true;
  }
  return error.statusCode == null &&
      (error.code == NextcloudApiError.network ||
          error.code == NextcloudApiError.timeout);
}

int _nowSeconds() =>
    DateTime.now().toUtc().millisecondsSinceEpoch ~/
    Duration.millisecondsPerSecond;

String _roomKey(String accountId, String roomToken) =>
    '$accountId\u0000$roomToken';

String _scopeSyncKey(String accountId, String roomToken, int? threadId) =>
    '${_roomKey(accountId, roomToken)}\u0000${threadId ?? 'root'}';

String _networkScopeKey(String accountId, String roomToken, int? threadId) =>
    '${_scopeSyncKey(accountId, roomToken, threadId)}\u0000network';
