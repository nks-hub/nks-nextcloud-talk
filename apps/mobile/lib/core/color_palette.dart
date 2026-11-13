import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import 'text_prompt_dialog.dart';

/// Colours offered wherever a colour is chosen: six light ones, six dark ones.
const List<String> colorPaletteHexes = [
  '#FFFFFF',
  '#F8EBB0',
  '#CFEBD8',
  '#CDE3F7',
  '#F7D0D8',
  '#2F6FEB',
  '#1E3A5F',
  '#1F4D3A',
  '#4A2C5E',
  '#7A2E3A',
  '#2B2B2E',
  '#000000',
];

/// Czech or English name of a palette colour, `null` for any other value.
String? colorPaletteName(AppLocalizations strings, String? hex) =>
    switch (hex?.toUpperCase()) {
      '#FFFFFF' => strings.colorNameWhite,
      '#F8EBB0' => strings.colorNameLemon,
      '#CFEBD8' => strings.colorNameMint,
      '#CDE3F7' => strings.colorNameSky,
      '#F7D0D8' => strings.colorNamePink,
      '#2F6FEB' => strings.colorNameBlue,
      '#1E3A5F' => strings.colorNameNavy,
      '#1F4D3A' => strings.colorNameForest,
      '#4A2C5E' => strings.colorNamePlum,
      '#7A2E3A' => strings.colorNameBurgundy,
      '#2B2B2E' => strings.colorNameGraphite,
      '#000000' => strings.colorNameBlack,
      _ => null,
    };

Color _swatchColor(String hex) =>
    Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

/// The swatches themselves. Each one is a labelled button of at least
/// 48 x 48 dp; [selected] is marked with a check mark and the "selected"
/// semantics flag.
final class ColorSwatchGrid extends StatelessWidget {
  const ColorSwatchGrid({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  /// The colour in use, compared case-insensitively; may be a colour that is
  /// not in the palette.
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final outline = Theme.of(context).colorScheme.outline;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final hex in colorPaletteHexes)
          _Swatch(
            key: Key('color-swatch-$hex'),
            color: _swatchColor(hex),
            name: colorPaletteName(strings, hex)!,
            selected: selected?.toUpperCase() == hex,
            outline: outline,
            onTap: () => onSelected(hex),
          ),
      ],
    );
  }
}

final class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.color,
    required this.name,
    required this.selected,
    required this.outline,
    required this.onTap,
  });

  final Color color;
  final String name;
  final bool selected;
  final Color outline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: name,
        excludeFromSemantics: true,
        child: InkResponse(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: outline, width: selected ? 2 : 1),
                ),
                child: selected ? Icon(Icons.check, color: onColor) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

sealed class ColorPaletteChoice {
  const ColorPaletteChoice();
}

final class ColorPaletteColor extends ColorPaletteChoice {
  const ColorPaletteColor(this.hex);

  final String hex;
}

/// "Follow the theme": the value is cleared.
final class ColorPaletteTheme extends ColorPaletteChoice {
  const ColorPaletteTheme();
}

/// "Custom": the caller asks for a hex value next.
final class ColorPaletteCustom extends ColorPaletteChoice {
  const ColorPaletteCustom();
}

/// A palette dialog; `null` when it is dismissed. It scrolls, so it also fits
/// a phone held sideways and large text.
Future<ColorPaletteChoice?> showColorPaletteDialog({
  required BuildContext context,
  required String title,
  required String? current,
  Key? dialogKey,
}) {
  return showDialog<ColorPaletteChoice>(
    context: context,
    builder: (dialogContext) {
      final strings = AppLocalizations.of(dialogContext);
      final inPalette = colorPaletteName(strings, current) != null;
      return AlertDialog(
        key: dialogKey,
        title: Text(title),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        content: SizedBox(
          width: 312,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ColorSwatchGrid(
                selected: current,
                onSelected: (hex) =>
                    Navigator.of(dialogContext).pop(ColorPaletteColor(hex)),
              ),
              const SizedBox(height: 8),
              ListTile(
                key: const Key('color-palette-custom'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tune),
                title: Text(strings.colorPaletteCustom),
                subtitle: current != null && !inPalette
                    ? Text(current.toUpperCase())
                    : null,
                trailing: current != null && !inPalette
                    ? const Icon(Icons.check)
                    : null,
                selected: current != null && !inPalette,
                onTap: () =>
                    Navigator.of(dialogContext).pop(const ColorPaletteCustom()),
              ),
              ListTile(
                key: const Key('color-palette-theme'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.format_color_reset_outlined),
                title: Text(strings.ownTalkSharedThemeDefault),
                trailing: current == null ? const Icon(Icons.check) : null,
                selected: current == null,
                onTap: () =>
                    Navigator.of(dialogContext).pop(const ColorPaletteTheme()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
        ],
      );
    },
  );
}

/// What [pickColor] decided: [value] is the new `#RRGGBB`, or `null` to clear.
typedef ColorPick = ({String? value});

/// Palette first, then the hex field when the user chooses "Custom". Returns
/// `null` when the user backed out, and a pick with a `null` value for "follow
/// the theme". An invalid hex calls [onInvalid] and picks nothing.
Future<ColorPick?> pickColor({
  required BuildContext context,
  required String title,
  required String? current,
  required String fieldLabel,
  required String? Function(String text) normalize,
  required VoidCallback onInvalid,
  Key? paletteKey,
  Key? promptKey,
  Key? fieldKey,
  Key? confirmKey,
}) async {
  final choice = await showColorPaletteDialog(
    context: context,
    title: title,
    current: current,
    dialogKey: paletteKey,
  );
  if (choice == null || !context.mounted) {
    return null;
  }
  switch (choice) {
    case ColorPaletteColor(:final hex):
      return (value: hex);
    case ColorPaletteTheme():
      return (value: null);
    case ColorPaletteCustom():
      final strings = AppLocalizations.of(context);
      final text = await showTextPromptDialog(
        context: context,
        title: title,
        initialValue: current ?? '#00679E',
        fieldLabel: fieldLabel,
        helperText: strings.ownTalkSharedClearHint,
        cancelLabel: strings.cancel,
        confirmLabel: strings.roomDetailsSave,
        dialogKey: promptKey,
        fieldKey: fieldKey,
        confirmKey: confirmKey,
        maxLength: 7,
      );
      if (text == null) {
        return null;
      }
      final trimmed = text.trim();
      if (trimmed.isEmpty) {
        return (value: null);
      }
      final normalized = normalize(trimmed);
      if (normalized == null) {
        onInvalid();
        return null;
      }
      return (value: normalized);
  }
}
