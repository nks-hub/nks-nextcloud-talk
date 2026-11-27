part of 'chat_message_content.dart';

ChatGalleryImage? chatGalleryImage(StoredAccount account, ChatMessage message) {
  if (message.deleted ||
      message.messageType != 'comment' ||
      message.systemMessage.isNotEmpty) {
    return null;
  }
  final files = message.messageParameters.values.where((p) => p.type == 'file');
  if (files.length != 1) return null;
  return _galleryFile(account, files.single);
}

List<ChatGalleryImage> sharedPhotosInMessage(
  StoredAccount account,
  ChatMessage message,
) {
  if (message.deleted ||
      message.messageType != 'comment' ||
      message.systemMessage.isNotEmpty) {
    return const [];
  }
  return [
    for (final file in message.messageParameters.values)
      if (file.type == 'file')
        ?_galleryFile(account, file, originalOnlyAllowed: true),
  ];
}

ChatGalleryImage? _galleryFile(
  StoredAccount account,
  ChatRichObjectParameter file, {
  bool originalOnlyAllowed = false,
}) {
  final mime = _mimeType(file);
  final preview = _previewUri(account, file, mime);
  final original = _davAttachment(account, file)?.uri;
  if (original == null ||
      mime == null ||
      !mime.startsWith('image/') ||
      (preview == null && !originalOnlyAllowed)) {
    return null;
  }
  return ChatGalleryImage(
    previewUri: preview == null ? original : _fullScreenPreviewUri(preview),
    smallerPreviewUri: preview,
    originalUri: original,
    contentType: mime,
    name: file.name ?? '',
  );
}

ChatRichObjectParameter _fileOf(ChatMessage message) =>
    message.messageParameters.values.singleWhere((p) => p.type == 'file');

final class ChatPhotoAlbumContent extends ConsumerWidget {
  const ChatPhotoAlbumContent({
    super.key,
    required this.account,
    required this.messages,
    required this.foregroundColor,
    required this.onMessageActions,
    required this.onReactionTap,
    this.onOpenParent,
    this.showReplyPreview = true,
  });

  final StoredAccount account;
  final List<ChatMessage> messages;
  final Color foregroundColor;
  final ValueChanged<ChatMessage> onMessageActions;
  final void Function(ChatMessage, String) onReactionTap;
  final ValueChanged<int>? onOpenParent;
  final bool showReplyPreview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = [...this.messages]
      ..sort(
        (a, b) => ChatPhotoAlbumReference.tryParse(a.referenceId)!.index
            .compareTo(ChatPhotoAlbumReference.tryParse(b.referenceId)!.index),
      );
    final images = messages.map((m) => chatGalleryImage(account, m)!).toList();
    final visibleCount = math.min(4, messages.length);
    void open(int index) {
      final navigator = Navigator.of(context);
      final opener = ref.read(appSettingsOpenerProvider);
      unawaited(
        showAuthenticatedImageGallery(
          context,
          account: account,
          images: images,
          initialIndex: index,
          repository: ref.read(chatMediaRepositoryProvider),
          openAppSettings: opener.open,
          onImageActions: (index) {
            navigator.pop();
            onMessageActions(messages[index]);
          },
          onOpenFile: (index) {
            final message = messages[index];
            final open = _attachmentOpenFile(
              context,
              ref,
              account: account,
              parameter: _fileOf(message),
              roomToken: message.roomToken.value,
              messageId: message.messageId,
              index: 0,
            );
            if (open != null) unawaited(open());
          },
          onForward: (index) =>
              _forwardFileAction(context, _fileOf(messages[index]))?.call(),
        ),
      );
    }

    return SizedBox(
      width: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChatMessageContent(
            account: account,
            message: messages.first,
            fallbackText: '',
            foregroundColor: foregroundColor,
            showReplyPreview: showReplyPreview,
            showAttachments: false,
            onOpenParent: onOpenParent,
            onReactionTap: (emoji) => onReactionTap(messages.first, emoji),
          ),
          const SizedBox(height: 4),
          GridView.builder(
            key: Key('chat-photo-album-${messages.first.messageId}'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: visibleCount,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemBuilder: (context, index) {
              final message = messages[index];
              final parameter = _fileOf(message);
              return GestureDetector(
                onLongPress: () => onMessageActions(message),
                onSecondaryTap: () => onMessageActions(message),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ChatAttachment(
                      account: account,
                      parameter: parameter,
                      roomToken: message.roomToken.value,
                      messageId: message.messageId,
                      index: 0,
                      compact: true,
                      onOpenImage: () => open(index),
                    ),
                    if (index == visibleCount - 1 &&
                        messages.length > visibleCount)
                      Material(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          onTap: () => open(index),
                          child: Center(
                            child: Text(
                              '+${messages.length - visibleCount}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          for (final message in messages.skip(1))
            if (message.reactions.isNotEmpty ||
                message.message.trim() !=
                    '{${message.messageParameters.entries.singleWhere((e) => e.value.type == 'file').key}}')
              ChatMessageContent(
                account: account,
                message: message,
                fallbackText: '',
                foregroundColor: foregroundColor,
                showReplyPreview: false,
                showAttachments: false,
                onReactionTap: (emoji) => onReactionTap(message, emoji),
              ),
        ],
      ),
    );
  }
}
