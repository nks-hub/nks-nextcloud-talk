part of 'room_details_screen.dart';

extension _RoomDetailsConversationTagsState on _RoomDetailsScreenState {
  bool get _canManageConversationTags =>
      _room != null &&
      _roomType != _roomTypeFormerOneToOne &&
      _talkFeatures.contains(_conversationTagsCapability);

  Future<void> _manageConversationTags() async {
    if (_busy || !_canManageConversationTags) {
      return;
    }
    _setBusy(true);
    final List<ConversationTagDefinition> definitions;
    try {
      definitions = await ref
          .read(conversationTagsServiceProvider)
          .fetchDefinitions(accountId: widget.account.id);
    } on ConversationTagsException catch (error) {
      _showConversationTagsError(error.code);
      return;
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
    if (!mounted) {
      return;
    }

    final custom = definitions
        .where((tag) => tag.type == ConversationTagType.custom)
        .toList(growable: false);
    final customIds = custom.map((tag) => tag.id).toSet();
    final current = _room!.tagIds;
    final selected = current.intersection(customIds);
    final nextCustom = await _showConversationTagsDialog(
      definitions: custom,
      selected: selected,
    );
    if (nextCustom == null || !mounted || _sameIds(selected, nextCustom)) {
      return;
    }

    _setBusy(true);
    try {
      final preserved = current.difference(customIds);
      final room = await ref
          .read(conversationTagsServiceProvider)
          .assign(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            tagIds: {...preserved, ...nextCustom},
          );
      if (mounted) {
        _setAuthoritativeRoom(room);
        _showMessage(
          AppLocalizations.of(context).roomDetailsConversationTagsSaved,
        );
      }
    } on ConversationTagsException catch (error) {
      _showConversationTagsError(error.code);
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
  }

  Future<Set<String>?> _showConversationTagsDialog({
    required List<ConversationTagDefinition> definitions,
    required Set<String> selected,
  }) {
    final strings = AppLocalizations.of(context);
    final pending = {...selected};
    return showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('room-details-conversation-tags-dialog'),
          title: Text(strings.roomDetailsConversationTagsDialogTitle),
          content: definitions.isEmpty
              ? Text(strings.roomDetailsConversationTagsEmpty)
              : SizedBox(
                  width: 360,
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          strings.roomDetailsConversationTagsDialogHint,
                        ),
                      ),
                      for (final tag in definitions)
                        CheckboxListTile(
                          key: Key('room-details-conversation-tag-${tag.id}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(tag.name),
                          value: pending.contains(tag.id),
                          onChanged: (checked) {
                            setDialogState(() {
                              if (checked ?? false) {
                                pending.add(tag.id);
                              } else {
                                pending.remove(tag.id);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ),
          actions: [
            TextButton(
              key: const Key('room-details-conversation-tags-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(strings.cancel),
            ),
            if (definitions.isNotEmpty)
              FilledButton(
                key: const Key('room-details-conversation-tags-save'),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(Set<String>.unmodifiable(pending)),
                child: Text(strings.roomDetailsConversationTagsSave),
              ),
          ],
        ),
      ),
    );
  }

  void _showConversationTagsError(ConversationTagsError code) {
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final message = switch (code) {
      ConversationTagsError.unsupported =>
        strings.roomDetailsConversationTagsUnsupported,
      ConversationTagsError.reauthenticationRequired =>
        strings.roomDetailsActionErrorReauth,
      ConversationTagsError.forbidden =>
        strings.roomDetailsActionErrorForbidden,
      ConversationTagsError.roomMissing =>
        strings.roomDetailsActionErrorRoomMissing,
      ConversationTagsError.accountMissing ||
      ConversationTagsError.credentialMissing ||
      ConversationTagsError.rateLimited ||
      ConversationTagsError.serviceUnavailable ||
      ConversationTagsError.invalidResponse ||
      ConversationTagsError.network => strings.roomDetailsActionErrorGeneric,
    };
    _showMessage(message);
  }
}

bool _sameIds(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
