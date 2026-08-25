part of 'chat_room_pane.dart';

final class _ChatErrorNotice extends StatelessWidget {
  const _ChatErrorNotice({required this.error, required this.onRetry});

  final ChatServiceError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _chatErrorMessage(strings, error),
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              IconButton(
                key: const Key('retry-chat-sync'),
                onPressed: onRetry,
                tooltip: strings.retry,
                color: scheme.onErrorContainer,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

ChatServiceError? _storedError(String? value) {
  if (value == null) {
    return null;
  }
  return ChatServiceError.values
      .where((error) => error.name == value)
      .firstOrNull;
}

String _chatErrorMessage(AppLocalizations strings, ChatServiceError error) {
  return switch (error) {
    ChatServiceError.credentialMissing ||
    ChatServiceError.reauthenticationRequired => strings.syncCredentialMissing,
    ChatServiceError.talkUnavailable ||
    ChatServiceError.chatUnsupported ||
    ChatServiceError.sendUnsupported => strings.chatUnsupported,
    ChatServiceError.rateLimited => strings.syncRateLimited,
    ChatServiceError.serviceUnavailable ||
    ChatServiceError.network => strings.chatUnavailable,
    ChatServiceError.readOnly => strings.readOnlyConversation,
    ChatServiceError.accountMissing ||
    ChatServiceError.conversationMissing ||
    ChatServiceError.invalidResponse => strings.chatInvalidResponse,
  };
}

String _messageActionErrorMessage(
  AppLocalizations strings,
  ChatMessageActionError error,
) {
  return switch (error) {
    ChatMessageActionError.credentialMissing ||
    ChatMessageActionError.reauthenticationRequired =>
      strings.syncCredentialMissing,
    ChatMessageActionError.talkUnavailable => strings.talkUnavailable,
    ChatMessageActionError.actionUnsupported =>
      strings.messageActionUnsupported,
    ChatMessageActionError.messageMissing ||
    ChatMessageActionError.notFound => strings.messageActionMessageMissing,
    ChatMessageActionError.rateLimited => strings.syncRateLimited,
    ChatMessageActionError.serviceUnavailable ||
    ChatMessageActionError.network => strings.chatUnavailable,
    ChatMessageActionError.accountMissing ||
    ChatMessageActionError.conversationMissing ||
    ChatMessageActionError.invalidResponse => strings.chatInvalidResponse,
  };
}

/// Decodes a scope's stored `blocks` column, or `null` when the scope
/// hasn't loaded yet or its blocks are unreadable. A missing/undecodable
/// scope means the client cannot yet judge what is contiguous, so callers
/// fall back to showing the cache unfiltered rather than hiding everything.
