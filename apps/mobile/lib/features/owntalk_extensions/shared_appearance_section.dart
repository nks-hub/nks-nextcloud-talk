import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../core/text_prompt_dialog.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_background_theme.dart';
import 'owntalk_extensions_service.dart';
import 'owntalk_room_extras.dart';
import 'owntalk_settings_store.dart';

/// Whether the shared appearance can exist for this conversation: the server
/// offers the extension, supports the room type, answered with a settings
/// document, and the conversation is not federated. The server enforces the same, so this only decides what to show.
bool ownTalkSharedAppearanceApplies(
  OwnTalkRoomExtras extras, {
  required int roomType,
  required bool federated,
}) {
  final capability = extras.capability;
  // Without a document the server has not said who may edit yet (or answered
  // 404), so there is nothing truthful to show.
  return capability != null &&
      extras.settings != null &&
      !federated &&
      capability.supportsRoomType(roomType) &&
      _fieldsFor(capability).isNotEmpty;
}

List<OwnTalkSettingField> _fieldsFor(OwnTalkExtensionsCapability capability) =>
    [
      for (final field in const [
        OwnTalkSettingField.chatBackgroundColor,
        OwnTalkSettingField.bubbleOwnColor,
        OwnTalkSettingField.bubbleOwnTextColor,
        OwnTalkSettingField.bubbleOtherColor,
        OwnTalkSettingField.bubbleOtherTextColor,
        OwnTalkSettingField.composerQuickEmoji,
      ])
        if (capability.supportsField(field)) field,
    ];

String _fieldTitle(
  AppLocalizations strings,
  OwnTalkSettingField field,
) => switch (field) {
  OwnTalkSettingField.chatBackgroundColor => strings.ownTalkSharedBackground,
  OwnTalkSettingField.bubbleOwnColor => strings.ownTalkSharedOwnBubble,
  OwnTalkSettingField.bubbleOwnTextColor => strings.ownTalkSharedOwnText,
  OwnTalkSettingField.bubbleOtherColor => strings.ownTalkSharedOtherBubble,
  OwnTalkSettingField.bubbleOtherTextColor => strings.ownTalkSharedOtherText,
  OwnTalkSettingField.composerQuickEmoji => strings.ownTalkSharedQuickEmoji,
  OwnTalkSettingField.chatAccentColor => field.wireKey,
};

String _fieldKey(OwnTalkSettingField field) =>
    'owntalk-shared-${field.wireKey.replaceAll('.', '-').toLowerCase()}';

/// Room details block "Appearance for everyone". Renders nothing unless
/// [ownTalkSharedAppearanceApplies] holds.
final class OwnTalkSharedAppearanceSection extends ConsumerStatefulWidget {
  const OwnTalkSharedAppearanceSection({
    super.key,
    required this.accountId,
    required this.roomToken,
    required this.roomType,
    required this.federated,
  });

  final String accountId;
  final String roomToken;
  final int roomType;
  final bool federated;

  @override
  ConsumerState<OwnTalkSharedAppearanceSection> createState() =>
      _OwnTalkSharedAppearanceSectionState();
}

final class _OwnTalkSharedAppearanceSectionState
    extends ConsumerState<OwnTalkSharedAppearanceSection> {
  bool _busy = false;

  OwnTalkRoomKey get _key =>
      (accountId: widget.accountId, roomToken: widget.roomToken);

  @override
  Widget build(BuildContext context) {
    final extras = ref.watch(ownTalkRoomExtrasProvider(_key));
    if (!ownTalkSharedAppearanceApplies(
      extras,
      roomType: widget.roomType,
      federated: widget.federated,
    )) {
      return const SizedBox.shrink();
    }
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final canEdit = extras.canEdit;
    return Column(
      key: const Key('owntalk-shared-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Semantics(
            header: true,
            child: Text(
              strings.ownTalkSharedHeader,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            canEdit
                ? strings.ownTalkSharedIntro
                : _readOnlyText(strings, extras.capability),
            key: canEdit
                ? const Key('owntalk-shared-intro')
                : const Key('owntalk-shared-read-only'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final field in _fieldsFor(extras.capability!))
          _row(context, strings, field, extras, canEdit),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations strings,
    OwnTalkSettingField field,
    OwnTalkRoomExtras extras,
    bool canEdit,
  ) {
    final value = extras.valueOf(field);
    final scheme = Theme.of(context).colorScheme;
    final color = field.isEmoji ? null : parseChatBackgroundColor(value);
    return ListTile(
      key: Key(_fieldKey(field)),
      leading: ExcludeSemantics(
        child: field.isEmoji
            ? SizedBox.square(
                dimension: 28,
                child: Center(
                  child: value == null
                      ? Icon(
                          Icons.emoji_emotions_outlined,
                          color: scheme.onSurfaceVariant,
                        )
                      : Text(value, style: const TextStyle(fontSize: 22)),
                ),
              )
            : Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outline),
                ),
                child: color == null
                    ? Icon(
                        Icons.palette_outlined,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      )
                    : null,
              ),
      ),
      title: Text(_fieldTitle(strings, field)),
      subtitle: Text(value ?? strings.ownTalkSharedThemeDefault),
      onTap: canEdit && !_busy ? () => _edit(field, value) : null,
    );
  }

  Future<void> _edit(OwnTalkSettingField field, String? current) async {
    final strings = AppLocalizations.of(context);
    // A poll may land while the dialog is open; the write must still be
    // checked against what the user was looking at.
    final base =
        ref.read(ownTalkRoomExtrasProvider(_key)).settings?.revision ?? 0;
    final result = await showTextPromptDialog(
      context: context,
      title: _fieldTitle(strings, field),
      initialValue: current ?? (field.isEmoji ? '' : '#00679E'),
      fieldLabel: field.isEmoji
          ? strings.ownTalkSharedEmojiLabel
          : strings.ownTalkSharedColorLabel,
      helperText: strings.ownTalkSharedClearHint,
      cancelLabel: strings.cancel,
      confirmLabel: strings.roomDetailsSave,
      dialogKey: const Key('owntalk-shared-dialog'),
      fieldKey: const Key('owntalk-shared-field'),
      confirmKey: const Key('owntalk-shared-save'),
      maxLength: field.isEmoji ? 16 : 7,
    );
    if (!mounted || result == null) {
      return;
    }
    final text = result.trim();
    final String? next;
    if (text.isEmpty) {
      next = null;
    } else {
      next = normalizeOwnTalkSettingValue(field, text);
      if (next == null) {
        _message(strings.ownTalkSharedInvalidValue);
        return;
      }
    }
    if (next == current) {
      return;
    }
    await _apply({field: next}, base);
  }

  Future<void> _apply(
    Map<OwnTalkSettingField, String?> changes,
    int baseRevision,
  ) async {
    final strings = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(ownTalkRoomExtrasProvider(_key).notifier)
          .save(changes, baseRevision: baseRevision);
      if (!mounted) {
        return;
      }
      switch (result) {
        case OwnTalkSettingsSaved():
          _message(strings.ownTalkSharedSaved);
        // A retried write whose first attempt did land meets its own values.
        case final OwnTalkSettingsConflict conflict
            when changes.entries.every(
              (change) => conflict.current[change.key] == change.value,
            ):
          _message(strings.ownTalkSharedSaved);
        case final OwnTalkSettingsConflict conflict:
          setState(() => _busy = false);
          await _resolveConflict(changes, conflict);
        case OwnTalkSettingsUpdateFailure(:final kind):
          _message(switch (kind) {
            OwnTalkExtensionsFailureKind.forbidden => _readOnlyText(
              strings,
              ref.read(ownTalkRoomExtrasProvider(_key)).capability,
            ),
            _ => strings.ownTalkSharedSaveFailed,
          });
      }
    } on OwnTalkExtensionsException catch (error) {
      if (mounted) {
        _message(
          error.code == OwnTalkExtensionsError.network
              ? strings.ownTalkSharedSaveOffline
              : strings.ownTalkSharedSaveFailed,
        );
      }
    } on Object {
      if (mounted) {
        _message(strings.ownTalkSharedSaveFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// `412`: someone else changed one of these fields first. The server's
  /// current values are shown, and the user may re-apply their own on top.
  Future<void> _resolveConflict(
    Map<OwnTalkSettingField, String?> mine,
    OwnTalkSettingsConflict conflict,
  ) async {
    final strings = AppLocalizations.of(context);
    final fields = conflict.conflictingFields.isEmpty
        ? mine.keys.toList()
        : conflict.conflictingFields;
    final reapply = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('owntalk-conflict-dialog'),
        title: Text(strings.ownTalkConflictTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.ownTalkConflictBody),
            const SizedBox(height: 8),
            for (final field in fields)
              Text(
                strings.ownTalkConflictLine(
                  _fieldTitle(strings, field),
                  conflict.current[field] ?? strings.ownTalkSharedThemeDefault,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('owntalk-conflict-keep'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.ownTalkConflictKeep),
          ),
          FilledButton(
            key: const Key('owntalk-conflict-apply'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.ownTalkConflictApply),
          ),
        ],
      ),
    );
    if (reapply == true && mounted) {
      await _apply(mine, conflict.current.revision);
    }
  }

  /// Without Talk roles nobody may edit a group conversation, so "only
  /// moderators" would be wrong there.
  String _readOnlyText(
    AppLocalizations strings,
    OwnTalkExtensionsCapability? capability,
  ) => capability?.acl == OwnTalkAclMode.membership
      ? strings.ownTalkSharedReadOnlyMembership
      : strings.ownTalkSharedReadOnly;

  void _message(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }
}
