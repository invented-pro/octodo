import 'package:flutter/material.dart';

/// Catppuccin Mocha accent palette + theme tokens used across the app.
///
/// Single source of truth for the brand colors so widgets don't each
/// carry hardcoded hex values. Hex literals still appear in places
/// that pre-date this file (the tab chip, the workspace drawer,
/// etc.) and will be migrated gradually; new code should reach for
/// these constants instead.
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

  /// Mocha-Blue at ~30% alpha — the global "anywhere the pointer
  /// hovers over a Material widget" tint. Picked high enough to be
  /// instantly noticeable against every dark surface in the app
  /// (Catppuccin `surface0..2`, dialog bg, drawer bg) without
  /// masking the underlying text/icon.
  static final Color hoverOverlay = accentBlue.withValues(alpha: 0.30);

  /// A softer accent tint for pressed/focused states that should
  /// feel stronger than a hover but not blind the user.
  static final Color focusOverlay = accentBlue.withValues(alpha: 0.45);
}

/// Builds the app's [ThemeData]. [backgroundColor] is the live
/// `terminal.backgroundColor` setting; it's wired into both the
/// `Scaffold` (via [scaffoldBackgroundColor]) and the native window
/// (via [WindowOptions.backgroundColor] in `main()`), so the chrome
/// never flashes a different shade around the terminal grid.
///
/// Hover state is intentionally aggressive: every focusable Material
/// widget ([TextButton], [FilledButton], [IconButton], …) gets the
/// Mocha-Blue [AppColors.hoverOverlay] tint instead of the M3 default
/// `onSurface @ ~8%`, which is invisible on the dark surfaces.
///
/// [`SplashFactory`] is set to `NoSplash` so hover changes feel
/// instant — splash animation delays the visible feedback and, on a
/// dark theme, looks like a flicker rather than a hover.
ThemeData buildAppTheme({required Color backgroundColor}) {
  return ThemeData.dark(useMaterial3: true).copyWith(
    scaffoldBackgroundColor: backgroundColor,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accentBlue,
      secondary: AppColors.accentBlue,
      surface: AppColors.surface2,
      onPrimary: AppColors.surface0,
      onSurface: AppColors.textPrimary,
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return AppColors.accentBlue;
          }
          return null;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return AppColors.focusOverlay;
          }
          if (states.contains(WidgetState.hovered)) {
            return AppColors.hoverOverlay;
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
                    ? AppColors.accentBlue.withValues(alpha: 0.7)
                    : AppColors.accentBlue.withValues(alpha: 0.30),
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
            return AppColors.focusOverlay;
          }
          if (states.contains(WidgetState.hovered)) {
            return AppColors.hoverOverlay;
          }
          return null;
        }),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.popupSurface,
      textStyle: TextStyle(color: AppColors.textPrimary, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        side: BorderSide(color: AppColors.outline, width: 1),
      ),
    ),
    splashFactory: NoSplash.splashFactory,
    hoverColor: AppColors.hoverOverlay,
    highlightColor: AppColors.accentBlue.withValues(alpha: 0.15),
  );
}
