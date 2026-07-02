// BuildContext extension that resolves the active [ThemePalette]
// from the surrounding [ThemeData]. Widgets should reach for this
// instead of the legacy `AppColors` static class — palette colors
// retint when the user picks a different theme, whereas the static
// class only ever returns the Catppuccin Mocha defaults.

import 'package:flutter/material.dart';
import 'palettes.dart';

extension PaletteContext on BuildContext {
  /// The active palette. Always non-null in widgets built inside a
  /// MaterialApp whose `theme`/`darkTheme` was produced by
  /// [buildAppTheme]. The bang is safe under that contract.
  ThemePalette get palette =>
      Theme.of(this).extension<ThemePaletteExtension>()!.palette;
}

/// Carries the active [ThemePalette] on [ThemeData.extensions] so
/// `Theme.of(context).extension<ThemePaletteExtension>()?.palette`
/// works from any widget.
class ThemePaletteExtension extends ThemeExtension<ThemePaletteExtension> {
  final ThemePalette palette;
  const ThemePaletteExtension(this.palette);

  @override
  ThemePaletteExtension copyWith({ThemePalette? palette}) =>
      ThemePaletteExtension(palette ?? this.palette);

  /// Palettes are discrete — we don't interpolate between Catppuccin
  /// Mocha and Latte. Flutter calls this during theme transitions;
  /// returning [this] until t crosses 0.5 yields a clean snap.
  @override
  ThemePaletteExtension lerp(
    ThemeExtension<ThemePaletteExtension>? other,
    double t,
  ) {
    if (other is! ThemePaletteExtension) return this;
    return t < 0.5 ? this : other;
  }
}