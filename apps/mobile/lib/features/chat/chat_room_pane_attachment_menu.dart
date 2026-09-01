part of 'chat_room_pane.dart';

extension _ChatRoomPaneAttachmentMenu on _ChatRoomPaneState {
  List<AttachmentMenuAction> _attachmentMenuActions({
    required AppLocalizations strings,
    required bool attachmentSupported,
    required RichChatCapabilityProfile? actionsProfile,
    required AsyncValue<bool>? pollAvailable,
  }) => <AttachmentMenuAction>[
    AttachmentMenuAction(
      key: const Key('attach-source-gallery'),
      icon: const Icon(Icons.image_outlined),
      label: strings.attachFromGallery,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(
              _mediaComposerController.pickAttachment(
                AttachmentPickerSource.gallery,
              ),
            ),
    ),
    AttachmentMenuAction(
      key: const Key('attach-source-camera'),
      icon: const Icon(Icons.photo_camera_outlined),
      label: strings.attachFromCamera,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(
              _mediaComposerController.pickAttachment(
                AttachmentPickerSource.camera,
              ),
            ),
    ),
    AttachmentMenuAction(
      key: const Key('attach-source-file'),
      icon: const Icon(Icons.insert_drive_file_outlined),
      label: strings.attachFromFile,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(
              _mediaComposerController.pickAttachment(
                AttachmentPickerSource.file,
              ),
            ),
    ),
    AttachmentMenuAction(
      key: const Key('attach-source-contact'),
      icon: const Icon(Icons.contact_page_outlined),
      label: strings.contactAttachment,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(_mediaComposerController.pickContact()),
    ),
    if (actionsProfile?.geoLocation ?? false)
      AttachmentMenuAction(
        key: const Key('share-current-location'),
        icon: const Icon(Icons.location_on_outlined),
        label: strings.shareLocation,
        onSelected:
            _sending ||
                (widget.threadId != null &&
                    _currentThreadContext?.isNamed != true)
            ? null
            : () => unawaited(_shareCurrentLocation()),
      ),
    if (pollAvailable?.isLoading ?? false)
      AttachmentMenuAction(
        key: const Key('create-poll-checking'),
        icon: const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: strings.pollChecking,
        onSelected: null,
      ),
    if (pollAvailable?.valueOrNull ?? false)
      AttachmentMenuAction(
        key: const Key('create-poll'),
        icon: const Icon(Icons.poll_outlined),
        label: strings.pollMenuAction,
        onSelected: _sending ? null : () => unawaited(_openPollComposer()),
      ),
  ];
}
