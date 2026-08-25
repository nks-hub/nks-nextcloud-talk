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
    authority: authority,
  );
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

int _nowSeconds() =>
    DateTime.now().toUtc().millisecondsSinceEpoch ~/
    Duration.millisecondsPerSecond;

String _roomKey(String accountId, String roomToken) =>
    '$accountId\u0000$roomToken';

String _scopeSyncKey(String accountId, String roomToken, int? threadId) =>
    '${_roomKey(accountId, roomToken)}\u0000${threadId ?? 'root'}';

String _networkScopeKey(String accountId, String roomToken, int? threadId) =>
    '${_scopeSyncKey(accountId, roomToken, threadId)}\u0000network';
