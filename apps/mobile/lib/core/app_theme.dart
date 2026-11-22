import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const Color _seed = Color(0xFF00679E);
  static const Color _secondarySeed = Color(0xFF4F6A7D);
  static const Color _tertiarySeed = Color(0xFF17616D);
  static const Color _lightSurface = Color(0xFFFAF8F5);
  static const Color _darkSurface = Color(0xFF13161B);

  /// Mouse and keyboard do not need the touch target minimum, and Nextcloud's
  /// own clients size their controls around `--default-clickable-area: 34px`.
  /// Only the platforms driven by a pointer get the tighter values; phones and
  /// tablets keep 48 dp so the touch target minimum still holds.
  static bool get _pointerFirst => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };

  static ThemeData light({Color? seedColor}) =>
      _create(Brightness.light, seedColor: seedColor);

  static ThemeData dark({Color? seedColor}) =>
      _create(Brightness.dark, seedColor: seedColor);

  static Color? seedFromServerHex(String? value) {
    if (value == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
      return null;
    }
    final rgb = int.tryParse(value.substring(1), radix: 16);
    return rgb == null ? null : Color(0xFF000000 | rgb);
  }

  static ColorScheme _withSecondary(ColorScheme base, Brightness brightness) {
    final secondary = ColorScheme.fromSeed(
      seedColor: _secondarySeed,
      brightness: brightness,
    );
    return base.copyWith(
      secondary: secondary.primary,
      onSecondary: secondary.onPrimary,
      secondaryContainer: secondary.primaryContainer,
      onSecondaryContainer: secondary.onPrimaryContainer,
    );
  }

  static ColorScheme _withTertiary(ColorScheme base, Brightness brightness) {
    final tertiary = ColorScheme.fromSeed(
      seedColor: _tertiarySeed,
      brightness: brightness,
    );
    return base.copyWith(
      tertiary: tertiary.primary,
      onTertiary: tertiary.onPrimary,
      tertiaryContainer: tertiary.primaryContainer,
      onTertiaryContainer: tertiary.onPrimaryContainer,
      tertiaryFixed: tertiary.tertiaryFixed,
      tertiaryFixedDim: tertiary.tertiaryFixedDim,
    );
  }

  /// Violet through magenta to pink, 250 to 345 degrees; a grey has no hue.
  static bool _isVioletOrPink(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl.saturation > 0.08 && hsl.hue >= 250 && hsl.hue <= 345;
  }

  /// The stock Nextcloud blue, which is also what a stock server sends, gets
  /// the fixed blue-grey and teal roles. Any other server colour keeps the
  /// roles Material derives from it, except that a tertiary which would land
  /// in violet or pink for a server colour that is not itself violet or pink
  /// becomes the fixed teal.
  static ColorScheme _roles(
    ColorScheme generated,
    Brightness brightness,
    Color? seedColor,
  ) {
    if (seedColor == null || seedColor == _seed) {
      return _withTertiary(_withSecondary(generated, brightness), brightness);
    }
    if (_isVioletOrPink(generated.tertiaryContainer) &&
        !_isVioletOrPink(seedColor)) {
      return _withTertiary(generated, brightness);
    }
    return generated;
  }

  static ThemeData _create(Brightness brightness, {Color? seedColor}) {
    final isDark = brightness == Brightness.dark;
    final pointer = _pointerFirst;
    // Flutter already gives desktop VisualDensity.compact, which takes 8 off
    // the resolved minimumSize. Desktop numbers below are therefore written
    // 8 larger than the size they are meant to end up at: 44 -> 36, 46 -> 38.
    final interactiveMin = pointer ? 44.0 : 48.0;
    final filledMin = pointer ? 46.0 : 52.0;
    // An IconButton is sized by its padding around the 24 dp icon, not by
    // minimumSize, so the padding is the knob: 6 + 24 + 6 = 36.
    final iconMin = pointer ? 36.0 : 48.0;
    final iconPadding = pointer ? const EdgeInsets.all(6) : null;
    final outlineWidth = pointer ? 1.0 : 2.0;
    final inputRadius = pointer ? 8.0 : 16.0;
    final cardRadius = pointer ? 12.0 : 24.0;
    final inputPadding = pointer
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 12)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 16);
    final filledPadding = pointer
        ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 20, vertical: 14);
    final generated = ColorScheme.fromSeed(
      seedColor: seedColor ?? _seed,
      brightness: brightness,
    );
    final roles = _roles(generated, brightness, seedColor);
    final scheme = roles.copyWith(
      surface: isDark ? _darkSurface : _lightSurface,
      // Fills inputs and the cards inside bubbles. Near-black in the dark theme
      // read as a hole in a bubble, so it stops a step short of that.
      surfaceContainerLowest: isDark ? const Color(0xFF101319) : Colors.white,
      surfaceContainerLow: isDark
          ? const Color(0xFF172331)
          : const Color(0xFFECF3FA),
      surfaceContainer: isDark
          ? const Color(0xFF202C39)
          : const Color(0xFFE3EBF5),
      outline: isDark ? const Color(0xFF6A7886) : const Color(0xFF66717D),
      // 3:1 against the surface or better, with headroom: the shared chat
      // background is a tint of the surface and has to keep that ratio too.
      outlineVariant: isDark
          ? const Color(0xFF617080)
          : const Color(0xFF7A8693),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      disabledColor: scheme.onSurfaceVariant,
    );
    final chipLabelColor = WidgetStateColor.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return scheme.onSurface.withValues(alpha: 0.38);
      }
      if (states.contains(WidgetState.selected)) {
        return scheme.onSecondaryContainer;
      }
      return scheme.onSurfaceVariant;
    });
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.5),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
        bodySmall: base.textTheme.bodySmall?.copyWith(height: 1.4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: pointer,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(inputRadius),
          borderSide: BorderSide(color: scheme.outline, width: outlineWidth),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(inputRadius),
          borderSide: BorderSide(color: scheme.outline, width: outlineWidth),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(inputRadius),
          borderSide: BorderSide(color: scheme.primary, width: outlineWidth),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(inputRadius),
          borderSide: BorderSide(
            color: scheme.outlineVariant,
            width: outlineWidth,
          ),
        ),
        contentPadding: inputPadding,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(interactiveMin, filledMin),
          padding: filledPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(inputRadius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          disabledBackgroundColor: isDark
              ? const Color(0xFF92A1AE)
              : const Color(0xFF66727E),
          disabledForegroundColor: isDark
              ? const Color(0xFF111820)
              : Colors.white,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: Size(interactiveMin, interactiveMin),
          disabledForegroundColor: scheme.onSurfaceVariant,
          side: BorderSide(color: scheme.outline, width: outlineWidth),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(pointer ? 8 : 14),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: Size(iconMin, iconMin),
          padding: iconPadding,
          disabledForegroundColor: scheme.onSurfaceVariant,
          // IconButton keeps the padded 48 dp tap target unless told otherwise,
          // which on a pointer platform is exactly the padding we are removing.
          tapTargetSize: pointer
              ? MaterialTapTargetSize.shrinkWrap
              : MaterialTapTargetSize.padded,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: scheme.outlineVariant, width: outlineWidth),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        disabledColor: scheme.surfaceContainer,
        selectedColor: scheme.secondaryContainer,
        secondarySelectedColor: scheme.secondaryContainer,
        checkmarkColor: scheme.onSecondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(pointer ? 8 : 14),
        ),
        labelStyle: base.textTheme.labelLarge?.copyWith(color: chipLabelColor),
        secondaryLabelStyle: base.textTheme.labelLarge?.copyWith(
          color: chipLabelColor,
        ),
      ),
      // Content scrolling under a bar must not tint it: the tint turns the
      // bar blue-grey against the warm surface. The bottom line keeps the
      // full outlineVariant, the 3:1 boundary the chat background relies on.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
