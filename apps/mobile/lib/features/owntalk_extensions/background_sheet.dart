import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../core/color_palette.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_wallpaper.dart';
import 'owntalk_image_cache.dart';

sealed class OwnTalkBackgroundChoice {
  const OwnTalkBackgroundChoice();
}

final class BackgroundColorChosen extends OwnTalkBackgroundChoice {
  const BackgroundColorChosen(this.hex);

  final String hex;
}

/// "Custom": the caller asks for a hex value next.
final class BackgroundCustomColor extends OwnTalkBackgroundChoice {
  const BackgroundCustomColor();
}

final class BackgroundPresetChosen extends OwnTalkBackgroundChoice {
  const BackgroundPresetChosen(this.id);

  final String id;
}

/// The caller opens the photo picker next.
final class BackgroundPickPhoto extends OwnTalkBackgroundChoice {
  const BackgroundPickPhoto();
}

final class BackgroundRemovePhoto extends OwnTalkBackgroundChoice {
  const BackgroundRemovePhoto();
}

/// Clears colour, wallpaper and photo.
final class BackgroundUseTheme extends OwnTalkBackgroundChoice {
  const BackgroundUseTheme();
}

enum _Tab { color, preset, photo }

String ownTalkPresetName(AppLocalizations strings, String id) => switch (id) {
  'aurora' => strings.ownTalkPresetAurora,
  'sunset' => strings.ownTalkPresetSunset,
  'forest' => strings.ownTalkPresetForest,
  'ocean' => strings.ownTalkPresetOcean,
  'dots' => strings.ownTalkPresetDots,
  'grid' => strings.ownTalkPresetGrid,
  _ => id,
};

/// Megabytes for the upload hint, with a decimal only when it is needed.
String ownTalkMegabytes(int bytes) {
  final megabytes = bytes / (1024 * 1024);
  return megabytes == megabytes.roundToDouble()
      ? megabytes.round().toString()
      : megabytes.toStringAsFixed(1);
}

/// The one place to choose the shared background: a colour, a wallpaper the
/// client draws, or a photo. Only the kinds the server supports get a tab.
/// Resolves to what the user picked, or `null` when dismissed.
Future<OwnTalkBackgroundChoice?> showOwnTalkBackgroundSheet({
  required BuildContext context,
  required String accountId,
  required String roomToken,
  required OwnTalkExtensionsCapability capability,
  required String? color,
  required String? preset,
  required String? image,
}) {
  return showModalBottomSheet<OwnTalkBackgroundChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    // Flutter's own label for the barrier is "Scrim" even in Czech.
    barrierLabel: AppLocalizations.of(context).ownTalkBackgroundSheetBarrier,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheetContext) => _BackgroundSheet(
      accountId: accountId,
      roomToken: roomToken,
      capability: capability,
      color: color,
      preset: preset,
      image: image,
    ),
  );
}

final class _BackgroundSheet extends StatefulWidget {
  const _BackgroundSheet({
    required this.accountId,
    required this.roomToken,
    required this.capability,
    required this.color,
    required this.preset,
    required this.image,
  });

  final String accountId;
  final String roomToken;
  final OwnTalkExtensionsCapability capability;
  final String? color;
  final String? preset;
  final String? image;

  @override
  State<_BackgroundSheet> createState() => _BackgroundSheetState();
}

final class _BackgroundSheetState extends State<_BackgroundSheet> {
  late final List<_Tab> _tabs = [
    if (widget.capability.supportsField(
      OwnTalkSettingField.chatBackgroundColor,
    ))
      _Tab.color,
    if (widget.capability.supportsField(
          OwnTalkSettingField.chatBackgroundPreset,
        ) &&
        offeredChatWallpaperPresets(widget.capability.presets).isNotEmpty)
      _Tab.preset,
    if (widget.capability.supportsField(
      OwnTalkSettingField.chatBackgroundImage,
    ))
      _Tab.photo,
  ];

  /// Opens on the kind that is in effect now: photo, then wallpaper, then
  /// colour.
  late _Tab _tab = _initialTab();

  _Tab _initialTab() {
    final wanted = widget.image != null && _tabs.contains(_Tab.photo)
        ? _Tab.photo
        : widget.preset != null && _tabs.contains(_Tab.preset)
        ? _Tab.preset
        : _Tab.color;
    return _tabs.contains(wanted) ? wanted : _tabs.first;
  }

  void _choose(OwnTalkBackgroundChoice choice) =>
      Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final anySet =
        widget.color != null || widget.preset != null || widget.image != null;
    // A phone held sideways leaves about 300 dp for the whole sheet. There the
    // title, the tabs and the actions scroll with the body instead of keeping
    // a few dp for it between two fixed bars.
    final compact = MediaQuery.sizeOf(context).height < 480;
    final body = switch (_tab) {
      _Tab.color => _colorBody(strings),
      _Tab.preset => _presetBody(strings),
      _Tab.photo => _photoBody(strings, compact: compact),
    };
    final themeAction = anySet
        ? Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: TextButton.icon(
              key: const Key('owntalk-background-theme'),
              onPressed: () => _choose(const BackgroundUseTheme()),
              icon: const Icon(Icons.format_color_reset_outlined),
              label: Text(strings.ownTalkSharedThemeDefault),
            ),
          )
        : null;
    final column = Column(
      key: const Key('owntalk-background-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Semantics(
            header: true,
            child: Text(
              strings.ownTalkSharedBackgroundAll,
              style: theme.textTheme.titleLarge,
            ),
          ),
        ),
        if (_tabs.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<_Tab>(
              key: const Key('owntalk-background-tabs'),
              showSelectedIcon: false,
              segments: [
                for (final tab in _tabs)
                  ButtonSegment<_Tab>(
                    value: tab,
                    label: Text(
                      key: Key('owntalk-tab-${tab.name}'),
                      switch (tab) {
                        _Tab.color => strings.ownTalkBackgroundTabColor,
                        _Tab.preset => strings.ownTalkBackgroundTabPreset,
                        _Tab.photo => strings.ownTalkBackgroundTabPhoto,
                      },
                    ),
                  ),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) =>
                  setState(() => _tab = selection.first),
            ),
          ),
        if (compact)
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: body)
        else
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: body,
            ),
          ),
        ?themeAction,
      ],
    );
    return SafeArea(
      child: compact ? SingleChildScrollView(child: column) : column,
    );
  }

  Widget _colorBody(AppLocalizations strings) {
    final color = widget.color;
    final custom = color != null && colorPaletteName(strings, color) == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ColorSwatchGrid(
          selected: color,
          onSelected: (hex) => _choose(BackgroundColorChosen(hex)),
        ),
        ListTile(
          key: const Key('owntalk-color-custom'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.tune),
          title: Text(strings.colorPaletteCustom),
          subtitle: custom ? Text(color.toUpperCase()) : null,
          trailing: custom ? const Icon(Icons.check) : null,
          selected: custom,
          onTap: () => _choose(const BackgroundCustomColor()),
        ),
      ],
    );
  }

  Widget _presetBody(AppLocalizations strings) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final preset in offeredChatWallpaperPresets(
          widget.capability.presets,
        ))
          _PresetTile(
            key: Key('owntalk-preset-${preset.id}'),
            preset: preset,
            name: ownTalkPresetName(strings, preset.id),
            selected: widget.preset == preset.id,
            onTap: () => _choose(BackgroundPresetChosen(preset.id)),
          ),
      ],
    );
  }

  Widget _photoBody(AppLocalizations strings, {required bool compact}) {
    final image = widget.image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (image != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _PhotoPreview(
              key: const Key('owntalk-photo-preview'),
              image: (
                accountId: widget.accountId,
                roomToken: widget.roomToken,
                sha256: image,
              ),
              label: strings.ownTalkBackgroundPhotoPreview,
              height: compact ? 72 : 120,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            strings.ownTalkBackgroundPhotoHint(
              ownTalkMegabytes(widget.capability.maxImageBytes),
            ),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        FilledButton.tonalIcon(
          key: const Key('owntalk-photo-pick'),
          onPressed: () => _choose(const BackgroundPickPhoto()),
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(
            image == null
                ? strings.ownTalkBackgroundPhotoPick
                : strings.ownTalkBackgroundPhotoChange,
          ),
        ),
        if (image != null)
          TextButton.icon(
            key: const Key('owntalk-photo-remove'),
            onPressed: () => _choose(const BackgroundRemovePhoto()),
            icon: const Icon(Icons.delete_outline),
            label: Text(strings.ownTalkBackgroundPhotoRemove),
          ),
      ],
    );
  }
}

final class _PresetTile extends StatelessWidget {
  const _PresetTile({
    super.key,
    required this.preset,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final ChatWallpaperPreset preset;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 96,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ChatWallpaper(preset: preset),
                      if (selected)
                        Icon(Icons.check_circle, color: scheme.primary),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The current photo, loaded through the same cache the chat uses.
final class _PhotoPreview extends ConsumerWidget {
  const _PhotoPreview({
    super.key,
    required this.image,
    required this.label,
    required this.height,
  });

  final OwnTalkImageKey image;
  final String label;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(ownTalkRoomImageProvider(image)).valueOrNull;
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: height,
        child: bytes == null
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: Icon(
                    Icons.image_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                width: double.infinity,
                cacheWidth: 640,
                semanticLabel: label,
                errorBuilder: (context, error, stackTrace) =>
                    ColoredBox(color: scheme.surfaceContainerHighest),
              ),
      ),
    );
  }
}
