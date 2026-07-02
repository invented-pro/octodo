// Theme builder. Single entry point: [buildAppTheme] takes a
// [ThemePalette] and returns the corresponding [ThemeData]. The
// palette is also installed as a [ThemePaletteExtension] so widgets
// can read palette tokens via `context.palette` (see palette_context.dart).

import 'package:flutter/material.dart';
import 'palette_context.dart';
import 'palettes.dart';

/// Builds the app's [ThemeData] for [palette].
///
/// [palette] is installed as a [ThemePaletteExtension] on the returned
/// theme so widgets can read palette tokens via `context.palette` /
/// `Theme.of(context).extension<ThemePaletteExtension>()`. The scaffold
/// background defaults to `palette.surface0` (which also doubles as
/// the terminal background — the alacritty renderer reads it from
/// the same palette via `TerminalSettings.backgroundColor`).
///
/// Hover state is intentionally aggressive: every focusable Material
/// widget ([TextButton], [FilledButton], [IconButton], …) gets the
/// palette's `hoverOverlay` tint instead of the M3 default `onSurface
/// @ ~8%`, which is invisible on the dark surfaces.
///
/// [`SplashFactory`] is set to `NoSplash` so hover changes feel
/// instant — splash animation delays the visible feedback and, on a
/// dark theme, looks like a flicker rather than a hover.
ThemeData buildAppTheme({required ThemePalette palette}) {
  final isDark = palette.brightness == Brightness.dark;
  final base = isDark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  final hoverOverlay = palette.hoverOverlay;
  final focusOverlay = palette.focusOverlay;
  return base.copyWith(
    scaffoldBackgroundColor: palette.surface0,
    extensions: [ThemePaletteExtension(palette)],
    colorScheme: isDark
        ? ColorScheme.dark(
            primary: palette.accentBlue,
            secondary: palette.accentBlue,
            surface: palette.surface2,
            onPrimary: palette.surface0,
            onSurface: palette.textPrimary,
          )
        : ColorScheme.light(
            primary: palette.accentBlue,
            secondary: palette.accentBlue,
            surface: palette.surface2,
            onPrimary: Colors.white,
            onSurface: palette.textPrimary,
          ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return palette.accentBlue;
          }
          return null;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return focusOverlay;
          }
          if (states.contains(WidgetState.hovered)) {
            return hoverOverlay;
          }
          return null;
        }),
        padding: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)) {
            return const EdgeInsets.symmetric(horizontal: 16, vertical: 10);
          }
          return null;
        }),
        shape: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)) {
            return RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: states.contains(WidgetState.focused)
                    ? palette.accentBlue.withValues(alpha: 0.7)
                    : palette.accentBlue.withValues(alpha: 0.30),
                width: 1.5,
              ),
            );
          }
          return const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          );
        }),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return Colors.white.withValues(alpha: 0.45);
          }
          if (states.contains(WidgetState.hovered)) {
            return Colors.white.withValues(alpha: 0.18);
          }
          return null;
        }),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)) {
            return focusOverlay;
          }
          if (states.contains(WidgetState.hovered)) {
            return hoverOverlay;
          }
          return null;
        }),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.popupSurface,
      textStyle: TextStyle(color: palette.textPrimary, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: palette.outline, width: 1),
      ),
    ),
    splashFactory: NoSplash.splashFactory,
    hoverColor: hoverOverlay,
    highlightColor: palette.accentBlue.withValues(alpha: 0.15),
  );
}

// ── Legacy AppColors shim ───────────────────────────────────────────
//
// Older code (and a few pre-existing trailing widgets) still import
// the static `AppColors` class for color tokens. To keep those
// widgets compiling, `AppColors` is kept here as a thin wrapper that
// returns the Catppuccin Mocha defaults — the same values it used to
// carry as `const`. New code should reach for `context.palette`
// instead so it retints when the user picks a different theme.

class AppColors {
  AppColors._();

  static const Color accentBlue = Color(0xFF89B4FA);
  static const Color accentGreen = Color(0xFFA6E3A1);
  static const Color accentYellow = Color(0xFFF9E2AF);
  static const Color accentPink = Color(0xFFF38BA8);
  static const Color accentPurple = Color(0xFFCBA6F7);
  static const Color accentTeal = Color(0xFF94E2D5);
  static const Color accentOrange = Color(0xFFFAB387);

  static const Color textPrimary = Color(0xFFEFF1F5);
  static const Color textBody = Color(0xFFCDD6F4);
  static const Color textSecondary = Color(0xFFBAC2DE);
  static const Color textMuted = Color(0xFF7F849C);
  static const Color textOverlay = Color(0xFF6C7086);

  static const Color surface0 = Color(0xFF11111B);
  static const Color surface1 = Color(0xFF181825);
  static const Color surface2 = Color(0xFF1E1E2E);
  static const Color dialogSurface = Color(0xFF1A1A24);
  static const Color drawerSurface = Color(0xFF20202A);
  static const Color popupSurface = Color(0xFF242430);
  static const Color rowSurface = Color(0xFF313244);
  static const Color outline = Color(0xFF45475A);

  static final Color hoverOverlay = accentBlue.withValues(alpha: 0.30);
  static final Color focusOverlay = accentBlue.withValues(alpha: 0.45);
}