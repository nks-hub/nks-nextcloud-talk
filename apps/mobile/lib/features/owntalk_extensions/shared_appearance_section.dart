import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../core/color_palette.dart';
import '../../core/text_prompt_dialog.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_background_theme.dart';
import '../chat/chat_wallpaper.dart';
import 'background_sheet.dart';
import 'owntalk_background_photo.dart';
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
      _rowsFor(capability).isNotEmpty;
}

/// The three fields behind the one "background" row, in precedence order.
const List<OwnTalkSettingField> _backgroundFields = [
  OwnTalkSettingField.chatBackgroundImage,
  OwnTalkSettingField.chatBackgroundPreset,
  OwnTalkSettingField.chatBackgroundColor,
];

/// One row per setting, except that the background fields share a single row,
/// represented by [OwnTalkSettingField.chatBackgroundColor].
List<OwnTalkSettingField> _rowsFor(OwnTalkExtensionsCapability capability) => [
  if (_backgroundFields.any(capability.supportsField))
    OwnTalkSettingField.chatBackgroundColor,
  for (final field in const [
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
  OwnTalkSettingField.chatBackgroundPreset =>
    strings.ownTalkBackgroundTabPreset,
  OwnTalkSettingField.chatBackgroundImage => strings.ownTalkBackgroundTabPhoto,
  OwnTalkSettingField.bubbleOwnColor => strings.ownTalkSharedOwnBubble,
  OwnTalkSettingField.bubbleOwnTextColor => strings.ownTalkSharedOwnText,
  OwnTalkSettingField.bubbleOtherColor => strings.ownTalkSharedOtherBubble,
  OwnTalkSettingField.bubbleOtherTextColor => strings.ownTalkSharedOtherText,
  OwnTalkSettingField.composerQuickEmoji => strings.ownTalkSharedQuickEmoji,
  OwnTalkSettingField.chatAccentColor => field.wireKey,
};

/// A value as a person reads it: "Follow the theme" for nothing, the wallpaper
/// by name, a photo as "Your photo", a colour as its hex.
String _valueLabel(
  AppLocalizations strings,
  OwnTalkSettingField field,
  String? value,
) {
  if (value == null) {
    return strings.ownTalkSharedThemeDefault;
  }
  return switch (field.kind) {
    OwnTalkSettingKind.image => strings.ownTalkBackgroundPhotoSet,
    OwnTalkSettingKind.preset => ownTalkPresetName(strings, value),
    _ => value,
  };
}

String _fieldKey(OwnTalkSettingField field) =>
    field == OwnTalkSettingField.chatBackgroundColor
    ? 'owntalk-shared-background'
    : 'owntalk-shared-${field.wireKey.replaceAll('.', '-').toLowerCase()}';

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
  bool _uploading = false;

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
        for (final field in _rowsFor(extras.capability!))
          _row(context, strings, field, extras, canEdit),
        if (_uploading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Semantics(
              label: strings.ownTalkBackgroundUploading,
              child: const LinearProgressIndicator(
                key: Key('owntalk-shared-uploading'),
              ),
            ),
          ),
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
    if (field == OwnTalkSettingField.chatBackgroundColor) {
      return _backgroundRow(context, strings, extras, canEdit);
    }
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
            : _colorDot(scheme, color),
      ),
      title: Text(_fieldTitle(strings, field)),
      subtitle: Text(value ?? strings.ownTalkSharedThemeDefault),
      onTap: canEdit && !_busy ? () => _edit(field, value) : null,
    );
  }

  Widget _colorDot(ColorScheme scheme, Color? color) => Container(
    width: 28,
    height: 28,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: scheme.outline),
    ),
    child: color == null
        ? Icon(Icons.palette_outlined, size: 16, color: scheme.onSurfaceVariant)
        : null,
  );

  /// The background row shows what is in effect, in the precedence the chat
  /// uses: photo, then a wallpaper this client can draw, then the colour.
  Widget _backgroundRow(
    BuildContext context,
    AppLocalizations strings,
    OwnTalkRoomExtras extras,
    bool canEdit,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final image = extras.valueOf(OwnTalkSettingField.chatBackgroundImage);
    final presetId = extras.valueOf(OwnTalkSettingField.chatBackgroundPreset);
    final preset = chatWallpaperPresetById(presetId);
    final colorValue = extras.valueOf(OwnTalkSettingField.chatBackgroundColor);
    final Widget leading;
    final String subtitle;
    if (image != null) {
      leading = Icon(Icons.photo_outlined, color: scheme.onSurfaceVariant);
      subtitle = strings.ownTalkBackgroundPhotoSet;
    } else if (preset != null) {
      leading = ClipOval(
        child: SizedBox.square(
          dimension: 28,
          child: ChatWallpaper(preset: preset),
        ),
      );
      subtitle = ownTalkPresetName(strings, preset.id);
    } else {
      leading = _colorDot(scheme, parseChatBackgroundColor(colorValue));
      subtitle = colorValue ?? strings.ownTalkSharedThemeDefault;
    }
    return ListTile(
      key: Key(_fieldKey(OwnTalkSettingField.chatBackgroundColor)),
      leading: ExcludeSemantics(
        child: SizedBox.square(dimension: 28, child: Center(child: leading)),
      ),
      title: Text(strings.ownTalkSharedBackgroundAll),
      subtitle: Text(subtitle),
      onTap: canEdit && !_busy ? _editBackground : null,
    );
  }

  Future<void> _editBackground() async {
    final extras = ref.read(ownTalkRoomExtrasProvider(_key));
    final capability = extras.capability;
    if (capability == null) {
      return;
    }
    // A poll may land while the sheet is open; the write must still be
    // checked against what the user was looking at.
    final base = extras.settings?.revision ?? 0;
    final choice = await showOwnTalkBackgroundSheet(
      context: context,
      accountId: widget.accountId,
      roomToken: widget.roomToken,
      capability: capability,
      color: extras.valueOf(OwnTalkSettingField.chatBackgroundColor),
      preset: extras.valueOf(OwnTalkSettingField.chatBackgroundPreset),
      image: extras.valueOf(OwnTalkSettingField.chatBackgroundImage),
    );
    if (!mounted || choice == null) {
      return;
    }
    switch (choice) {
      case BackgroundColorChosen(:final hex):
        await _setBackground(base, color: hex);
      case BackgroundCustomColor():
        await _customBackgroundColor(base);
      case BackgroundPresetChosen(:final id):
        await _setBackground(base, preset: id);
      case BackgroundUseTheme():
        await _setBackground(base);
      case BackgroundRemovePhoto():
        await _applyChanges({
          OwnTalkSettingField.chatBackgroundImage: null,
        }, base);
      case BackgroundPickPhoto():
        await _uploadPhoto(base, capability);
    }
  }

  /// Sets a colour or a wallpaper, or with neither clears the whole
  /// background. Whatever outranks the new choice is cleared with it, because
  /// the chat shows photo before wallpaper before colour and the choice would
  /// otherwise stay invisible.
  Future<void> _setBackground(int base, {String? color, String? preset}) {
    final extras = ref.read(ownTalkRoomExtrasProvider(_key));
    final changes = <OwnTalkSettingField, String?>{
      OwnTalkSettingField.chatBackgroundColor: ?color,
      OwnTalkSettingField.chatBackgroundPreset: ?preset,
    };
    final outranking = color != null
        ? const [
            OwnTalkSettingField.chatBackgroundImage,
            OwnTalkSettingField.chatBackgroundPreset,
          ]
        : preset != null
        ? const [OwnTalkSettingField.chatBackgroundImage]
        : _backgroundFields;
    for (final field in outranking) {
      changes.putIfAbsent(field, () => null);
    }
    changes.removeWhere((field, value) => extras.valueOf(field) == value);
    return changes.isEmpty
        ? Future<void>.value()
        : _applyChanges(changes, base);
  }

  Future<void> _customBackgroundColor(int base) async {
    final strings = AppLocalizations.of(context);
    final current = ref
        .read(ownTalkRoomExtrasProvider(_key))
        .valueOf(OwnTalkSettingField.chatBackgroundColor);
    final text = await showTextPromptDialog(
      context: context,
      title: strings.ownTalkSharedBackgroundAll,
      initialValue: current ?? '#00679E',
      fieldLabel: strings.ownTalkSharedColorLabel,
      helperText: strings.ownTalkSharedClearHint,
      cancelLabel: strings.cancel,
      confirmLabel: strings.roomDetailsSave,
      dialogKey: const Key('owntalk-shared-dialog'),
      fieldKey: const Key('owntalk-shared-field'),
      confirmKey: const Key('owntalk-shared-save'),
      maxLength: 7,
    );
    if (!mounted || text == null) {
      return;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      await _setBackground(base);
      return;
    }
    final color = normalizeOwnTalkSettingValue(
      OwnTalkSettingField.chatBackgroundColor,
      trimmed,
    );
    if (color == null) {
      _message(strings.ownTalkSharedInvalidValue);
      return;
    }
    await _setBackground(base, color: color);
  }

  Future<void> _uploadPhoto(
    int base,
    OwnTalkExtensionsCapability capability,
  ) async {
    final strings = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _uploading = true;
    });
    try {
      final OwnTalkBackgroundPhoto? photo;
      try {
        photo = await ref.read(ownTalkPhotoPickerProvider)(
          maxBytes: capability.maxImageBytes,
          maxEdge: capability.maxImageEdge,
        );
      } on OwnTalkPhotoException catch (error) {
        _message(switch (error.error) {
          OwnTalkPhotoError.unsupportedType => strings.ownTalkPhotoRejectedType,
          OwnTalkPhotoError.unreadable => strings.ownTalkPhotoUnreadable,
          OwnTalkPhotoError.tooLarge => strings.ownTalkPhotoTooLargeLocal(
            ownTalkMegabytes(capability.maxImageBytes),
          ),
        });
        return;
      } on Object {
        _message(strings.ownTalkPhotoUnreadable);
        return;
      }
      if (!mounted || photo == null) {
        return;
      }
      final chosen = photo;
      await _apply(
        (revision) => ref
            .read(ownTalkRoomExtrasProvider(_key).notifier)
            .uploadImage(
              bytes: chosen.bytes,
              contentType: chosen.contentType,
              baseRevision: revision,
              announcement: strings.ownTalkAppearanceChangedNotice,
            ),
        base,
        fields: const [OwnTalkSettingField.chatBackgroundImage],
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploading = false;
        });
      }
    }
  }

  Future<void> _edit(OwnTalkSettingField field, String? current) async {
    final strings = AppLocalizations.of(context);
    // A poll may land while the dialog is open; the write must still be
    // checked against what the user was looking at.
    final base =
        ref.read(ownTalkRoomExtrasProvider(_key)).settings?.revision ?? 0;
    final String? next;
    if (field.isEmoji) {
      final result = await showTextPromptDialog(
        context: context,
        title: _fieldTitle(strings, field),
        initialValue: current ?? '',
        fieldLabel: strings.ownTalkSharedEmojiLabel,
        helperText: strings.ownTalkSharedClearHint,
        cancelLabel: strings.cancel,
        confirmLabel: strings.roomDetailsSave,
        dialogKey: const Key('owntalk-shared-dialog'),
        fieldKey: const Key('owntalk-shared-field'),
        confirmKey: const Key('owntalk-shared-save'),
        maxLength: 16,
      );
      if (!mounted || result == null) {
        return;
      }
      final text = result.trim();
      if (text.isEmpty) {
        next = null;
      } else {
        next = normalizeOwnTalkSettingValue(field, text);
        if (next == null) {
          _message(strings.ownTalkSharedInvalidValue);
          return;
        }
      }
    } else {
      final pick = await pickColor(
        context: context,
        title: _fieldTitle(strings, field),
        current: current,
        fieldLabel: strings.ownTalkSharedColorLabel,
        normalize: (text) => normalizeOwnTalkSettingValue(field, text),
        onInvalid: () => _message(strings.ownTalkSharedInvalidValue),
        paletteKey: const Key('owntalk-shared-palette'),
        promptKey: const Key('owntalk-shared-dialog'),
        fieldKey: const Key('owntalk-shared-field'),
        confirmKey: const Key('owntalk-shared-save'),
      );
      if (!mounted || pick == null) {
        return;
      }
      next = pick.value;
    }
    if (next == current) {
      return;
    }
    await _applyChanges({field: next}, base);
  }

  Future<void> _applyChanges(
    Map<OwnTalkSettingField, String?> changes,
    int baseRevision,
  ) {
    final announcement = AppLocalizations.of(
      context,
    ).ownTalkAppearanceChangedNotice;
    return _apply(
      (revision) => ref
          .read(ownTalkRoomExtrasProvider(_key).notifier)
          .save(
            changes,
            baseRevision: revision,
            announcement: announcement,
          ),
      baseRevision,
      fields: changes.keys.toList(),
      wanted: changes,
    );
  }

  /// Runs one write against [baseRevision] and reports the outcome. [wanted],
  /// when known, lets a conflict that already holds those values count as
  /// saved; an upload cannot know its resulting hash, so it has none.
  Future<void> _apply(
    Future<OwnTalkSettingsUpdateResult> Function(int baseRevision) run,
    int baseRevision, {
    required List<OwnTalkSettingField> fields,
    Map<OwnTalkSettingField, String?>? wanted,
  }) async {
    final strings = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final result = await run(baseRevision);
      if (!mounted) {
        return;
      }
      switch (result) {
        case OwnTalkSettingsSaved():
          _message(strings.ownTalkSharedSaved);
        // A retried write whose first attempt did land meets its own values.
        case final OwnTalkSettingsConflict conflict
            when wanted != null &&
                wanted.entries.every(
                  (change) => conflict.current[change.key] == change.value,
                ):
          _message(strings.ownTalkSharedSaved);
        case final OwnTalkSettingsConflict conflict:
          setState(() => _busy = false);
          await _resolveConflict(run, fields, wanted, conflict);
        case OwnTalkSettingsUpdateFailure(:final kind, :final errorCode):
          _message(switch (kind) {
            OwnTalkExtensionsFailureKind.forbidden => _readOnlyText(
              strings,
              ref.read(ownTalkRoomExtrasProvider(_key)).capability,
            ),
            OwnTalkExtensionsFailureKind.payloadTooLarge =>
              strings.ownTalkPhotoTooLargeServer,
            OwnTalkExtensionsFailureKind.unsupportedMediaType =>
              strings.ownTalkPhotoRejectedType,
            OwnTalkExtensionsFailureKind.quotaExceeded =>
              strings.ownTalkPhotoQuota,
            OwnTalkExtensionsFailureKind.rateLimited
                when fields.contains(OwnTalkSettingField.chatBackgroundImage) =>
              strings.ownTalkPhotoRateLimited,
            OwnTalkExtensionsFailureKind.rejected
                when errorCode == 'invalid_image' =>
              strings.ownTalkPhotoRejectedImage,
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
    Future<OwnTalkSettingsUpdateResult> Function(int baseRevision) run,
    List<OwnTalkSettingField> mine,
    Map<OwnTalkSettingField, String?>? wanted,
    OwnTalkSettingsConflict conflict,
  ) async {
    final strings = AppLocalizations.of(context);
    final fields = conflict.conflictingFields.isEmpty
        ? mine
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
                  _valueLabel(strings, field, conflict.current[field]),
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
      await _apply(
        run,
        conflict.current.revision,
        fields: mine,
        wanted: wanted,
      );
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
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }
}
