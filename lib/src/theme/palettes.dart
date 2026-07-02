// Theme palettes — the set of named color schemes the user can pick
// from. Each palette defines every chrome color the app references,
// plus the canonical `surface0` which doubles as the terminal
// background (the alacritty renderer reads the palette's `surface0`
// via `TerminalWorkspace`'s settings snapshot).
//
// New palettes go in the [_builtin] list. The registry order is what
// the Settings → Theme dropdown shows, so the default (Catppuccin
// Mocha) goes first.

import 'package:flutter/material.dart';

abstract class ThemePalette {
  const ThemePalette();

  /// Stable string id persisted to settings.json. Lowercase,
  /// hyphen-separated. Changing this is a breaking change for
  /// existing users — the codec falls back to the default on
  /// unknown ids.
  String get id;

  /// Human-readable name shown in the Settings → Theme dropdown.
  String get displayName;

  /// Light or dark. Drives Material's `ThemeMode` and the choice
  /// between `ThemeData.light()` and `ThemeData.dark()`.
  Brightness get brightness;

  // ── Brand accents (Catppuccin-style 7) ───────────────────────────

  Color get accentBlue;
  Color get accentGreen;
  Color get accentYellow;
  Color get accentPink;
  Color get accentPurple;
  Color get accentTeal;
  Color get accentOrange;

  // ── Text tiers (foreground hierarchy) ────────────────────────────

  Color get textPrimary;
  Color get textBody;
  Color get textSecondary;
  Color get textMuted;
  Color get textOverlay;

  // ── Surfaces (background hierarchy) ──────────────────────────────

  /// Scaffold / window / terminal background. The alacritty
  /// renderer reads this as the terminal grid background (via
  /// `TerminalSettings.backgroundColor`, which is populated from
  /// `palette.surface0` in `TerminalWorkspace._initSettings`).
  Color get surface0;

  /// Generic surface tier 1 — slightly raised panels.
  Color get surface1;

  /// Generic surface tier 2 — more raised (e.g. cards on top of a
  /// surface1 background).
  Color get surface2;

  /// Background of modal dialogs (settings, confirmations, etc.).
  Color get dialogSurface;

  /// Background of persistent sidebars (workspace drawer).
  Color get drawerSurface;

  /// Background of popovers / menus.
  Color get popupSurface;

  /// Background of list rows (settings rows, update popover entries).
  Color get rowSurface;

  /// 1px outline color (panel borders, dividers, input borders).
  Color get outline;

  // ── Terminal palette ─────────────────────────────────────────────

  /// Terminal default foreground. Used by the alacritty renderer for
  /// cells with no explicit SGR foreground (e.g. `echo hello`).
  /// Picked so contrast against the palette's surface0 is high in
  /// both light and dark variants — light palettes invert cleanly.
  Color get terminalForeground;

  /// Selection overlay drawn over highlighted cells. Conventional
  /// translucent tint (~35-50% alpha) of the palette's accent.
  Color get terminalSelection;

  /// 16 ANSI colors in alacritty's canonical order: indices 0..7 are
  /// the normal intensities (black, red, green, yellow, blue,
  /// magenta, cyan, white) and 8..15 are the bright intensities
  /// (bright black … bright white). Must always be exactly 16
  /// entries — `flutter_alacritty`'s [fa.TerminalColors.ansi] asserts
  /// the length and will throw otherwise.
  List<Color> get terminalAnsiColors;

  // ── State overlays (computed once per palette) ───────────────────

  /// Mocha-Blue-equivalent at ~30% alpha — the "anywhere the pointer
  /// hovers over a Material widget" tint. High enough to be
  /// instantly noticeable against every surface in the app without
  /// masking the underlying text/icon.
  Color get hoverOverlay => accentBlue.withValues(alpha: 0.30);

  /// Accent at ~45% alpha — pressed/focused states that should feel
  /// stronger than a hover but not blind the user.
  Color get focusOverlay => accentBlue.withValues(alpha: 0.45);

  // ── Workspace swatches ───────────────────────────────────────────

  /// Seven curated colors shown as the "Custom" tab in the
  /// workspace color picker. Each palette contributes its own
  /// set: dark palettes ship high-luminance accents (e.g. Mocha
  /// blue #89B4FA) that glow against a dark drawer surface, light
  /// palettes ship saturated/dark accents (e.g. Latte blue
  /// #1E66F5) that read on a pale surface. Picking a swatch from
  /// the active palette gives a workspace indicator visible in
  /// both the active theme and (with reduced contrast) the other.
  List<Color> get workspaceSwatches => [
        accentBlue,
        accentGreen,
        accentYellow,
        accentPink,
        accentPurple,
        accentTeal,
        accentOrange,
      ];
}

// ── Built-in palettes ───────────────────────────────────────────────
//
// All hex values are sourced from each project's published palette
// (Catppuccin, Dracula, Solarized, Tokyo Night, Nord). Token names
// match the semantic role the app assigns to them rather than the
// upstream token, so e.g. Dracula's `Cyan` maps to `accentTeal` (no
// `accentBlue` exists in Dracula upstream).

class CatppuccinMochaPalette extends ThemePalette {
  const CatppuccinMochaPalette();

  @override
  String get id => 'catppuccin-mocha';
  @override
  String get displayName => 'Catppuccin Mocha';
  @override
  Brightness get brightness => Brightness.dark;

  @override
  Color get accentBlue => const Color(0xFF89B4FA);
  @override
  Color get accentGreen => const Color(0xFFA6E3A1);
  @override
  Color get accentYellow => const Color(0xFFF9E2AF);
  @override
  Color get accentPink => const Color(0xFFF38BA8);
  @override
  Color get accentPurple => const Color(0xFFCBA6F7);
  @override
  Color get accentTeal => const Color(0xFF94E2D5);
  @override
  Color get accentOrange => const Color(0xFFFAB387);

  @override
  Color get textPrimary => const Color(0xFFEFF1F5);
  @override
  Color get textBody => const Color(0xFFCDD6F4);
  @override
  Color get textSecondary => const Color(0xFFBAC2DE);
  @override
  Color get textMuted => const Color(0xFF7F849C);
  @override
  Color get textOverlay => const Color(0xFF6C7086);

  @override
  Color get surface0 => const Color(0xFF11111B);
  @override
  Color get surface1 => const Color(0xFF181825);
  @override
  Color get surface2 => const Color(0xFF1E1E2E);
  @override
  Color get dialogSurface => const Color(0xFF1A1A24);
  @override
  Color get drawerSurface => const Color(0xFF20202A);
  @override
  Color get popupSurface => const Color(0xFF242430);
  @override
  Color get rowSurface => const Color(0xFF313244);
  @override
  Color get outline => const Color(0xFF45475A);

  // Terminal palette — official Catppuccin Mocha terminal ANSI
  // mapping. Bracketed-paste / hyperlink accents fall back to the
  // accentBlue-tinted selection so they read clearly against the
  // base0 background without screaming for attention.
  @override
  Color get terminalForeground => const Color(0xFFCDD6F4); // text
  @override
  Color get terminalSelection =>
      const Color(0x59357CDD); // sapphire @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF45475A), // 0 black        = surface1
        Color(0xFFF38BA8), // 1 red          = red (accentPink)
        Color(0xFFA6E3A1), // 2 green        = green (accentGreen)
        Color(0xFFF9E2AF), // 3 yellow       = yellow (accentYellow)
        Color(0xFF89B4FA), // 4 blue         = blue (accentBlue)
        Color(0xFFF5C2E7), // 5 magenta      = pink
        Color(0xFF94E2D5), // 6 cyan         = teal (accentTeal)
        Color(0xFFBAC2DE), // 7 white        = subtext1 (textSecondary)
        Color(0xFF585B70), // 8 bright black = surface2
        Color(0xFFF38BA8), // 9 bright red
        Color(0xFFA6E3A1), // 10 bright green
        Color(0xFFF9E2AF), // 11 bright yellow
        Color(0xFF89B4FA), // 12 bright blue
        Color(0xFFF5C2E7), // 13 bright magenta
        Color(0xFF94E2D5), // 14 bright cyan
        Color(0xFFA6ADC8), // 15 bright white = subtext0
      ];
}

class CatppuccinMacchiatoPalette extends ThemePalette {
  const CatppuccinMacchiatoPalette();

  @override
  String get id => 'catppuccin-macchiato';
  @override
  String get displayName => 'Catppuccin Macchiato';
  @override
  Brightness get brightness => Brightness.dark;

  @override
  Color get accentBlue => const Color(0xFF8AADF4);
  @override
  Color get accentGreen => const Color(0xFFA6DA95);
  @override
  Color get accentYellow => const Color(0xFFEED49F);
  @override
  Color get accentPink => const Color(0xFFED8796);
  @override
  Color get accentPurple => const Color(0xFFC6A0F6);
  @override
  Color get accentTeal => const Color(0xFF8BD5CA);
  @override
  Color get accentOrange => const Color(0xFFF5A97F);

  @override
  Color get textPrimary => const Color(0xFFCAD3F5);
  @override
  Color get textBody => const Color(0xFFB0BBD7);
  @override
  Color get textSecondary => const Color(0xFFA5ADCB);
  @override
  Color get textMuted => const Color(0xFF8087A2);
  @override
  Color get textOverlay => const Color(0xFF6E738D);

  @override
  Color get surface0 => const Color(0xFF181926);
  @override
  Color get surface1 => const Color(0xFF1E2030);
  @override
  Color get surface2 => const Color(0xFF24273A);
  @override
  Color get dialogSurface => const Color(0xFF1B1D2B);
  @override
  Color get drawerSurface => const Color(0xFF22243A);
  @override
  Color get popupSurface => const Color(0xFF24273A);
  @override
  Color get rowSurface => const Color(0xFF363A4F);
  @override
  Color get outline => const Color(0xFF494D64);

  // Terminal palette — official Catppuccin Macchiato terminal ANSI
  // mapping. Selection uses the Macchiato sapphire @ ~35% so it
  // stays a true tint (not a recolor) over any background cell.
  @override
  Color get terminalForeground => const Color(0xFFCAD3F5); // text
  @override
  Color get terminalSelection =>
      const Color(0x597D8AD3); // sapphire @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF494D64), // 0 black        = surface1
        Color(0xFFED8796), // 1 red          = red (accentPink)
        Color(0xFFA6DA95), // 2 green        = green (accentGreen)
        Color(0xFFEED49F), // 3 yellow       = yellow (accentYellow)
        Color(0xFF8AADF4), // 4 blue         = blue (accentBlue)
        Color(0xFFF5C2E7), // 5 magenta      = pink
        Color(0xFF8BD5CA), // 6 cyan         = teal (accentTeal)
        Color(0xFFB0BBD7), // 7 white        = subtext1 (textBody)
        Color(0xFF5B6078), // 8 bright black = surface2
        Color(0xFFED8796), // 9 bright red
        Color(0xFFA6DA95), // 10 bright green
        Color(0xFFEED49F), // 11 bright yellow
        Color(0xFF8AADF4), // 12 bright blue
        Color(0xFFF5C2E7), // 13 bright magenta
        Color(0xFF8BD5CA), // 14 bright cyan
        Color(0xFFA5ADCB), // 15 bright white = subtext0 (textSecondary)
      ];
}

class CatppuccinFrappePalette extends ThemePalette {
  const CatppuccinFrappePalette();

  @override
  String get id => 'catppuccin-frappe';
  @override
  String get displayName => 'Catppuccin Frappé';
  @override
  Brightness get brightness => Brightness.dark;

  @override
  Color get accentBlue => const Color(0xFF8CAAEE);
  @override
  Color get accentGreen => const Color(0xFFA6D189);
  @override
  Color get accentYellow => const Color(0xFFE5C890);
  @override
  Color get accentPink => const Color(0xFFF4B8E4);
  @override
  Color get accentPurple => const Color(0xFFCA9EE6);
  @override
  Color get accentTeal => const Color(0xFF81C8BE);
  @override
  Color get accentOrange => const Color(0xFFEF9F76);

  @override
  Color get textPrimary => const Color(0xFFC6CEF0);
  @override
  Color get textBody => const Color(0xFFB5BFE2);
  @override
  Color get textSecondary => const Color(0xFFA5ADCE);
  @override
  Color get textMuted => const Color(0xFF838BA7);
  @override
  Color get textOverlay => const Color(0xFF737994);

  @override
  Color get surface0 => const Color(0xFF232634);
  @override
  Color get surface1 => const Color(0xFF292C3C);
  @override
  Color get surface2 => const Color(0xFF303446);
  @override
  Color get dialogSurface => const Color(0xFF262837);
  @override
  Color get drawerSurface => const Color(0xFF2D2F42);
  @override
  Color get popupSurface => const Color(0xFF303446);
  @override
  Color get rowSurface => const Color(0xFF414559);
  @override
  Color get outline => const Color(0xFF51576D);

  // Terminal palette — official Catppuccin Frappé terminal ANSI
  // mapping. Selection overlay uses sapphire @ ~35% alpha so it
  // reads as a true translucent highlight over any ANSI cell color.
  @override
  Color get terminalForeground => const Color(0xFFC6CEF0); // text
  @override
  Color get terminalSelection =>
      const Color(0x5985C1DC); // sapphire @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF51576D), // 0 black        = surface1
        Color(0xFFE67E80), // 1 red          = red (accentPink)
        Color(0xFFA6D189), // 2 green        = green (accentGreen)
        Color(0xFFE5C890), // 3 yellow       = yellow (accentYellow)
        Color(0xFF8CAAEE), // 4 blue         = blue (accentBlue)
        Color(0xFFF4B8E4), // 5 magenta      = pink (accentPink-ish)
        Color(0xFF81C8BE), // 6 cyan         = teal (accentTeal)
        Color(0xFFB5BFE2), // 7 white        = subtext1 (textBody)
        Color(0xFF626880), // 8 bright black = surface2
        Color(0xFFE67E80), // 9 bright red
        Color(0xFFA6D189), // 10 bright green
        Color(0xFFE5C890), // 11 bright yellow
        Color(0xFF8CAAEE), // 12 bright blue
        Color(0xFFF4B8E4), // 13 bright magenta
        Color(0xFF81C8BE), // 14 bright cyan
        Color(0xFFA5ADCE), // 15 bright white = subtext0 (textSecondary)
      ];
}

class CatppuccinLattePalette extends ThemePalette {
  const CatppuccinLattePalette();

  @override
  String get id => 'catppuccin-latte';
  @override
  String get displayName => 'Catppuccin Latte';
  @override
  Brightness get brightness => Brightness.light;

  @override
  Color get accentBlue => const Color(0xFF1E66F5);
  @override
  Color get accentGreen => const Color(0xFF40A02B);
  @override
  Color get accentYellow => const Color(0xFFDF8E1D);
  @override
  Color get accentPink => const Color(0xFFEA76CB);
  @override
  Color get accentPurple => const Color(0xFF8839EF);
  @override
  Color get accentTeal => const Color(0xFF179299);
  @override
  Color get accentOrange => const Color(0xFFFE640B);

  @override
  Color get textPrimary => const Color(0xFF4C4F69);
  @override
  Color get textBody => const Color(0xFF5C5F77);
  @override
  Color get textSecondary => const Color(0xFF6C6F85);
  @override
  Color get textMuted => const Color(0xFF8C8FA1);
  @override
  Color get textOverlay => const Color(0xFF9CA0B0);

  // In Catppuccin, surfaces go from `base` (lightest) toward
  // `surface0..2` (darker raised panels). For Latte the base is
  // the lightest token, so surface0 is the lightest "panel" tier.
  @override
  Color get surface0 => const Color(0xFFEFF1F5);
  @override
  Color get surface1 => const Color(0xFFE6E9EF);
  @override
  Color get surface2 => const Color(0xFFDCE0E8);
  @override
  Color get dialogSurface => const Color(0xFFEAECF1);
  @override
  Color get drawerSurface => const Color(0xFFE2E5EC);
  @override
  Color get popupSurface => const Color(0xFFDCE0E8);
  @override
  Color get rowSurface => const Color(0xFFCCD0DA);
  @override
  Color get outline => const Color(0xFFBCC0CC);

  // Terminal palette — official Catppuccin Latte terminal ANSI
  // mapping. The Latte palette inverts the bright/normal contrast
  // vs Mocha: the "bright" tones are stronger, the "normal" tones
  // softer, because Latte renders dark text on a light background.
  // Selection overlay uses sapphire @ ~35% alpha; the translucent
  // sapphire reads as a blue tint on either polarity.
  @override
  Color get terminalForeground => const Color(0xFF4C4F69); // text
  @override
  Color get terminalSelection =>
      const Color(0x592091DD); // sapphire @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFFBCC0CC), // 0 black        = surface1
        Color(0xFFD20F39), // 1 red          = red
        Color(0xFF40A02B), // 2 green        = green (accentGreen)
        Color(0xFFDF8E1D), // 3 yellow       = yellow (accentYellow)
        Color(0xFF1E66F5), // 4 blue         = blue (accentBlue)
        Color(0xFFEA76CB), // 5 magenta      = pink (accentPink)
        Color(0xFF179299), // 6 cyan         = teal (accentTeal)
        Color(0xFFACB0BE), // 7 white        = subtext0
        Color(0xFFCCD0DA), // 8 bright black = surface2
        Color(0xFFDE293E), // 9 bright red
        Color(0xFF49AF3D), // 10 bright green
        Color(0xFFEEA02D), // 11 bright yellow
        Color(0xFF3667D6), // 12 bright blue
        Color(0xFFF087D4), // 13 bright magenta
        Color(0xFF2D8FA2), // 14 bright cyan
        Color(0xFFBCC0CC), // 15 bright white = surface1
      ];
}

class DraculaPalette extends ThemePalette {
  const DraculaPalette();

  @override
  String get id => 'dracula';
  @override
  String get displayName => 'Dracula';
  @override
  Brightness get brightness => Brightness.dark;

  // Dracula has no canonical `blue` accent; its `cyan` is the
  // closest stand-in.
  @override
  Color get accentBlue => const Color(0xFF8BE9FD);
  @override
  Color get accentGreen => const Color(0xFF50FA7B);
  @override
  Color get accentYellow => const Color(0xFFF1FA8C);
  @override
  Color get accentPink => const Color(0xFFFF79C6);
  @override
  Color get accentPurple => const Color(0xFFBD93F9);
  @override
  Color get accentTeal => const Color(0xFF8BE9FD);
  @override
  Color get accentOrange => const Color(0xFFFFB86C);

  @override
  Color get textPrimary => const Color(0xFFF8F8F2);
  @override
  Color get textBody => const Color(0xFFE6E6E0);
  @override
  Color get textSecondary => const Color(0xFFCFCFD0);
  @override
  Color get textMuted => const Color(0xFF9CA0AD);
  @override
  Color get textOverlay => const Color(0xFF6272A4);

  @override
  Color get surface0 => const Color(0xFF282A36);
  @override
  Color get surface1 => const Color(0xFF2E303E);
  @override
  Color get surface2 => const Color(0xFF34363F);
  @override
  Color get dialogSurface => const Color(0xFF2A2C38);
  @override
  Color get drawerSurface => const Color(0xFF2C2E3A);
  @override
  Color get popupSurface => const Color(0xFF34363F);
  @override
  Color get rowSurface => const Color(0xFF44475A);
  @override
  Color get outline => const Color(0xFF6272A4);

  // Terminal palette — official Dracula ANSI mapping from the
  // upstream `dracula-theme` repo. Foreground matches textPrimary;
  // selection is purple @ ~35% alpha so it tints both dark and
  // bright ANSI cells without obscuring them.
  @override
  Color get terminalForeground => const Color(0xFFF8F8F2); // foreground
  @override
  Color get terminalSelection =>
      const Color(0x59BD93F9); // purple @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF21222C), // 0 black        = background-dark
        Color(0xFFFF5555), // 1 red          = red
        Color(0xFF50FA7B), // 2 green        = green (accentGreen)
        Color(0xFFF1FA8C), // 3 yellow       = yellow (accentYellow)
        Color(0xFFBD93F9), // 4 blue         = purple (accentPurple)
        Color(0xFFFF79C6), // 5 magenta      = pink (accentPink)
        Color(0xFF8BE9FD), // 6 cyan         = cyan (accentTeal)
        Color(0xFFF8F8F2), // 7 white        = foreground (textPrimary)
        Color(0xFF6272A4), // 8 bright black = comment (textOverlay)
        Color(0xFFFF6E6E), // 9 bright red
        Color(0xFF69FF94), // 10 bright green
        Color(0xFFFFFFA5), // 11 bright yellow
        Color(0xFFD6ACFF), // 12 bright blue
        Color(0xFFFF92DF), // 13 bright magenta
        Color(0xFFA4FFFF), // 14 bright cyan
        Color(0xFFFFFFFF), // 15 bright white
      ];
}

class SolarizedDarkPalette extends ThemePalette {
  const SolarizedDarkPalette();

  @override
  String get id => 'solarized-dark';
  @override
  String get displayName => 'Solarized Dark';
  @override
  Brightness get brightness => Brightness.dark;

  @override
  Color get accentBlue => const Color(0xFF268BD2);
  @override
  Color get accentGreen => const Color(0xFF859900);
  @override
  Color get accentYellow => const Color(0xFFB58900);
  @override
  Color get accentPink => const Color(0xFFD33682);
  @override
  Color get accentPurple => const Color(0xFF6C71C4);
  @override
  Color get accentTeal => const Color(0xFF2AA198);
  @override
  Color get accentOrange => const Color(0xFFCB4B16);

  @override
  Color get textPrimary => const Color(0xFF839496);
  @override
  Color get textBody => const Color(0xFF93A1A1);
  @override
  Color get textSecondary => const Color(0xFF657B83);
  @override
  Color get textMuted => const Color(0xFF586E75);
  @override
  Color get textOverlay => const Color(0xFF586E75);

  @override
  Color get surface0 => const Color(0xFF002B36);
  @override
  Color get surface1 => const Color(0xFF073642);
  @override
  Color get surface2 => const Color(0xFF0A4554);
  @override
  Color get dialogSurface => const Color(0xFF00252E);
  @override
  Color get drawerSurface => const Color(0xFF013038);
  @override
  Color get popupSurface => const Color(0xFF073642);
  @override
  Color get rowSurface => const Color(0xFF0E4853);
  @override
  Color get outline => const Color(0xFF586E75);

  // Terminal palette — Solarized Dark ANSI mapping per the
  // canonical Solarized spec (https://ethanschoonover.com/solarized/).
  // The dim/bright distinction follows base0/base00 semantics —
  // bright colors are the lighter base tones that read on the
  // dark base03 background. Selection uses blue @ ~35% alpha so
  // it overlays cleanly without erasing the underlying fg/bg.
  @override
  Color get terminalForeground => const Color(0xFF93A1A1); // base1
  @override
  Color get terminalSelection =>
      const Color(0x59268BD2); // blue @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF073642), // 0 black        = base02 (surface1)
        Color(0xFFDC322F), // 1 red
        Color(0xFF859900), // 2 green        = green (accentGreen)
        Color(0xFFB58900), // 3 yellow       = yellow (accentYellow)
        Color(0xFF268BD2), // 4 blue         = blue (accentBlue)
        Color(0xFFD33682), // 5 magenta      = magenta (accentPink)
        Color(0xFF2AA198), // 6 cyan         = cyan (accentTeal)
        Color(0xFFEEE8D5), // 7 white        = base2
        Color(0xFF002B36), // 8 bright black = base03 (surface0)
        Color(0xFFCB4B16), // 9 bright red   = orange (accentOrange)
        Color(0xFF586E75), // 10 bright green= base01 (textMuted)
        Color(0xFF657B83), // 11 bright yellow= base00 (textSecondary)
        Color(0xFF839496), // 12 bright blue = base0 (textPrimary)
        Color(0xFF6C71C4), // 13 bright magenta= violet (accentPurple)
        Color(0xFF93A1A1), // 14 bright cyan = base1 (textBody)
        Color(0xFFFDF6E3), // 15 bright white= base3
      ];
}

class SolarizedLightPalette extends ThemePalette {
  const SolarizedLightPalette();

  @override
  String get id => 'solarized-light';
  @override
  String get displayName => 'Solarized Light';
  @override
  Brightness get brightness => Brightness.light;

  @override
  Color get accentBlue => const Color(0xFF268BD2);
  @override
  Color get accentGreen => const Color(0xFF859900);
  @override
  Color get accentYellow => const Color(0xFFB58900);
  @override
  Color get accentPink => const Color(0xFFD33682);
  @override
  Color get accentPurple => const Color(0xFF6C71C4);
  @override
  Color get accentTeal => const Color(0xFF2AA198);
  @override
  Color get accentOrange => const Color(0xFFCB4B16);

  @override
  Color get textPrimary => const Color(0xFF657B83);
  @override
  Color get textBody => const Color(0xFF586E75);
  @override
  Color get textSecondary => const Color(0xFF657B83);
  @override
  Color get textMuted => const Color(0xFF93A1A1);
  @override
  Color get textOverlay => const Color(0xFF93A1A1);

  @override
  Color get surface0 => const Color(0xFFFDF6E3);
  @override
  Color get surface1 => const Color(0xFFEEE8D5);
  @override
  Color get surface2 => const Color(0xFFE3DCC4);
  @override
  Color get dialogSurface => const Color(0xFFFAF1DC);
  @override
  Color get drawerSurface => const Color(0xFFF5EBD3);
  @override
  Color get popupSurface => const Color(0xFFEEE8D5);
  @override
  Color get rowSurface => const Color(0xFFE0D9C0);
  @override
  Color get outline => const Color(0xFF93A1A1);

  // Terminal palette — Solarized Light ANSI mapping. The dim/bright
  // slots are inverted vs Dark: base01/base02 become the "dark"
  // tones (used for foreground / normal bg-like swatches) and base2
  // /base3 fill the bright slots where they read clearly against
  // the light background. Foreground uses base00 so plain text
  // stands out against the base3 background; selection is blue @
  // ~35% alpha (same recipe as Dark).
  @override
  Color get terminalForeground => const Color(0xFF657B83); // base00
  @override
  Color get terminalSelection =>
      const Color(0x59268BD2); // blue @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF073642), // 0 black        = base02
        Color(0xFFDC322F), // 1 red
        Color(0xFF859900), // 2 green        = green (accentGreen)
        Color(0xFFB58900), // 3 yellow       = yellow (accentYellow)
        Color(0xFF268BD2), // 4 blue         = blue (accentBlue)
        Color(0xFFD33682), // 5 magenta      = magenta (accentPink)
        Color(0xFF2AA198), // 6 cyan         = cyan (accentTeal)
        Color(0xFF586E75), // 7 white        = base01 (textBody)
        Color(0xFF002B36), // 8 bright black = base03
        Color(0xFFCB4B16), // 9 bright red   = orange (accentOrange)
        Color(0xFF93A1A1), // 10 bright green= base1 (textMuted)
        Color(0xFF839496), // 11 bright yellow= base0
        Color(0xFF657B83), // 12 bright blue = base00 (textPrimary)
        Color(0xFF6C71C4), // 13 bright magenta= violet (accentPurple)
        Color(0xFF586E75), // 14 bright cyan = base01
        Color(0xFFFDF6E3), // 15 bright white= base3 (surface0)
      ];
}

class TokyoNightPalette extends ThemePalette {
  const TokyoNightPalette();

  @override
  String get id => 'tokyo-night';
  @override
  String get displayName => 'Tokyo Night';
  @override
  Brightness get brightness => Brightness.dark;

  @override
  Color get accentBlue => const Color(0xFF7AA2F7);
  @override
  Color get accentGreen => const Color(0xFF9ECE6A);
  @override
  Color get accentYellow => const Color(0xFFE0AF68);
  @override
  Color get accentPink => const Color(0xFFF7768E);
  @override
  Color get accentPurple => const Color(0xFFBB9AF7);
  @override
  Color get accentTeal => const Color(0xFF2AC3DE);
  @override
  Color get accentOrange => const Color(0xFFFF9E64);

  @override
  Color get textPrimary => const Color(0xFFC0CAF5);
  @override
  Color get textBody => const Color(0xFFA9B1D6);
  @override
  Color get textSecondary => const Color(0xFF9AA5CE);
  @override
  Color get textMuted => const Color(0xFF565F89);
  @override
  Color get textOverlay => const Color(0xFF565F89);

  @override
  Color get surface0 => const Color(0xFF1A1B26);
  @override
  Color get surface1 => const Color(0xFF1F2230);
  @override
  Color get surface2 => const Color(0xFF24283B);
  @override
  Color get dialogSurface => const Color(0xFF1D1F2C);
  @override
  Color get drawerSurface => const Color(0xFF1F2230);
  @override
  Color get popupSurface => const Color(0xFF24283B);
  @override
  Color get rowSurface => const Color(0xFF2F334D);
  @override
  Color get outline => const Color(0xFF414868);

  // Terminal palette — official Tokyo Night terminal ANSI mapping
  // (see tokyo-night.nvim / vscode-tokyo-night). The terminal
  // background is one step deeper than the chrome surface0 so the
  // "black" ANSI swatch isn't indistinguishable from the empty
  // grid. Selection uses blue @ ~35% alpha.
  @override
  Color get terminalForeground => const Color(0xFFC0CAF5); // textPrimary
  @override
  Color get terminalSelection =>
      const Color(0x597AA2F7); // blue @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF15161E), // 0 black        = terminal_black
        Color(0xFFF7768E), // 1 red          = red (accentPink)
        Color(0xFF9ECE6A), // 2 green        = green (accentGreen)
        Color(0xFFE0AF68), // 3 yellow       = yellow (accentYellow)
        Color(0xFF7AA2F7), // 4 blue         = blue (accentBlue)
        Color(0xFFBB9AF7), // 5 magenta      = magenta (accentPurple)
        Color(0xFF7DCFFF), // 6 cyan         = cyan
        Color(0xFFA9B1D6), // 7 white        = textBody
        Color(0xFF414868), // 8 bright black = terminal ansi_black (outline)
        Color(0xFFF7768E), // 9 bright red
        Color(0xFF9ECE6A), // 10 bright green
        Color(0xFFE0AF68), // 11 bright yellow
        Color(0xFF7AA2F7), // 12 bright blue
        Color(0xFFBB9AF7), // 13 bright magenta
        Color(0xFF7DCFFF), // 14 bright cyan
        Color(0xFFC0CAF5), // 15 bright white= textPrimary
      ];
}

class NordPalette extends ThemePalette {
  const NordPalette();

  @override
  String get id => 'nord';
  @override
  String get displayName => 'Nord';
  @override
  Brightness get brightness => Brightness.dark;

  @override
  Color get accentBlue => const Color(0xFF5E81AC);
  @override
  Color get accentGreen => const Color(0xFFA3BE8C);
  @override
  Color get accentYellow => const Color(0xFFEBCB8B);
  @override
  Color get accentPink => const Color(0xFFBF616A);
  @override
  Color get accentPurple => const Color(0xFFB48EAD);
  @override
  Color get accentTeal => const Color(0xFF88C0D0);
  @override
  Color get accentOrange => const Color(0xFFD08770);

  @override
  Color get textPrimary => const Color(0xFFECEFF4);
  @override
  Color get textBody => const Color(0xFFD8DEE9);
  @override
  Color get textSecondary => const Color(0xFFC2CDD9);
  @override
  Color get textMuted => const Color(0xFF7B88A1);
  @override
  Color get textOverlay => const Color(0xFF4C566A);

  @override
  Color get surface0 => const Color(0xFF2E3440);
  @override
  Color get surface1 => const Color(0xFF3B4252);
  @override
  Color get surface2 => const Color(0xFF434C5E);
  @override
  Color get dialogSurface => const Color(0xFF323844);
  @override
  Color get drawerSurface => const Color(0xFF353B47);
  @override
  Color get popupSurface => const Color(0xFF434C5E);
  @override
  Color get rowSurface => const Color(0xFF4C566A);
  @override
  Color get outline => const Color(0xFF4C566A);

  // Terminal palette — official Nord terminal ANSI mapping per the
  // canonical nord-spec. Note the "blue" ANSI slot uses Nord 10
  // (#81A1C1), NOT accentBlue (Nord 9 / Frost 1) — the ANSI palette
  // sits one shade lighter than the chrome accent on purpose so the
  // two don't compete. Selection uses Nord 10 blue @ ~35% alpha.
  @override
  Color get terminalForeground => const Color(0xFFECEFF4); // nord4 = textPrimary
  @override
  Color get terminalSelection =>
      const Color(0x595E81AC); // nord 9 / Frost 1 @ ~35% alpha
  @override
  List<Color> get terminalAnsiColors => const [
        Color(0xFF3B4252), // 0 black        = nord1 (surface1)
        Color(0xFFBF616A), // 1 red          = nord11 (accentPink)
        Color(0xFFA3BE8C), // 2 green        = nord14 (accentGreen)
        Color(0xFFEBCB8B), // 3 yellow       = nord13 (accentYellow)
        Color(0xFF81A1C1), // 4 blue         = nord10 (lighter than accentBlue)
        Color(0xFFB48EAD), // 5 magenta      = nord15 (accentPurple)
        Color(0xFF88C0D0), // 6 cyan         = nord8 (accentTeal)
        Color(0xFFE5E9F0), // 7 white        = nord6
        Color(0xFF4C566A), // 8 bright black = nord3 (outline)
        Color(0xFFBF616A), // 9 bright red
        Color(0xFFA3BE8C), // 10 bright green
        Color(0xFFEBCB8B), // 11 bright yellow
        Color(0xFF81A1C1), // 12 bright blue
        Color(0xFFB48EAD), // 13 bright magenta
        Color(0xFF8FBCBB), // 14 bright cyan = nord7
        Color(0xFFECEFF4), // 15 bright white= nord4 (textPrimary)
      ];
}

// ── Registry ───────────────────────────────────────────────────────

/// Registry of built-in palettes, in display order. The first entry
/// is the app default; reordering this list changes both the Settings
/// dropdown and the default for fresh installs.
class AppPalettes {
  AppPalettes._();

  static const List<ThemePalette> all = [
    CatppuccinMochaPalette(),
    CatppuccinMacchiatoPalette(),
    CatppuccinFrappePalette(),
    CatppuccinLattePalette(),
    DraculaPalette(),
    SolarizedDarkPalette(),
    SolarizedLightPalette(),
    TokyoNightPalette(),
    NordPalette(),
  ];

  /// Default palette id. Used by the `appearance.themeName` codec
  /// when the stored value is missing or unrecognized.
  static const String defaultId = 'catppuccin-mocha';

  /// Lookup by id. Unknown ids fall back to [defaultPalette]. Never
  /// throws — important so a settings file with a stale id (after a
  /// palette is renamed/removed) still boots.
  static ThemePalette byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return defaultPalette;
  }

  /// Convenience for the Settings UI / "Reset to default" action.
  static ThemePalette get defaultPalette => byId(defaultId);
}