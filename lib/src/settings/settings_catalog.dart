// The settings catalog — single source of truth for every
// user-facing setting. Add a new field here and it shows up in
// the settings UI, the validation list, the search index, and
// the schema documentation automatically.

import 'package:flutter/material.dart';
import 'setting.dart';
import 'setting_codec.dart';

enum CursorStyle { block, underline, bar }

enum BellMode { none, visual, sound }

/// Sentinel for `terminal.cursorColor` meaning "Auto" — the cursor uses
/// inverse video (the cell's foreground), which is theme-safe on both light
/// and dark palettes. Stored as fully-transparent black; the color picker
/// (opacity disabled) can't produce it, so it round-trips as a distinct
/// "unset" marker separate from any real color the user picks.
const Color kAutoCursorColor = Color(0x00000000);

/// Modifier required to open an OSC 8 hyperlink with the mouse.
///
/// The flutter_alacritty package's default is Ctrl (or Cmd on macOS),
/// mirrored here as [ctrl]. The other options let users pick a chord
/// that doesn't collide with shell bindings — tmux prefixes with
/// Ctrl+click in some configs, vim maps Ctrl+click to "jump to
/// definition", and readline apps often bind it themselves.
///
/// [none] means a plain left-click on a link opens it directly; this
/// still leaves Ctrl+click working (the package's built-in path) as a
/// fallback so users don't lose the chord they may be used to.
enum LinkClickModifier { ctrl, alt, shift, none }

String _enumName(Enum e) => e.name;

class SettingsCatalog {
  final general = GeneralSettingsSection();
  final terminal = TerminalSettingsSection();
  final shortcuts = ShortcutSettingsSection();
  final update = UpdateSettingsSection();

  /// All settings in declaration order. Used by the settings UI
  /// to build the section list and by the schema validator.
  Iterable<Setting<dynamic>> get all sync* {
    yield* general.all;
    yield* terminal.all;
    yield* shortcuts.all;
    yield* update.all;
  }
}

class TerminalSettingsSection {
  final fontFamily = StringSetting(
    'terminal.fontFamily',
    defaultValue: 'Cascadia Code',
    title: 'Font family',
    subtitle: 'Take effect for new workspace.',
    icon: Icons.text_fields,
  );

  final fontSize = DoubleSetting(
    'terminal.fontSize',
    defaultValue: 14.0,
    min: 10.0,
    max: 24.0,
    title: 'Font size',
    subtitle: 'Terminal cell height, in points.',
    icon: Icons.format_size,
  );

  final cursorStyle = EnumSetting<CursorStyle>(
    'terminal.cursorStyle',
    defaultValue: CursorStyle.block,
    values: CursorStyle.values,
    label: _enumName,
    title: 'Cursor style',
    icon: Icons.mouse,
  );

  /// Terminal cursor tint. Defaults to [kAutoCursorColor] ("Auto"), which
  /// keeps the classic inverse-video cursor; picking a real color overrides
  /// it for apps that use the terminal cursor (cmd/status lines, shells).
  /// A program-set OSC 12 color always wins over this.
  final cursorColor = ColorSetting(
    'terminal.cursorColor',
    defaultValue: kAutoCursorColor,
    title: 'Cursor color',
    subtitle: 'Terminal cursor tint. "Auto" inverts the cell color.',
    icon: Icons.colorize,
  );

  final cursorBlink = BoolSetting(
    'terminal.cursorBlink',
    defaultValue: true,
    title: 'Cursor blink',
    icon: Icons.flash_on,
  );

  final scrollbackLines = IntSetting(
    'terminal.scrollbackLines',
    defaultValue: 10000,
    min: 100,
    max: 100000,
    title: 'Scrollback lines',
    subtitle: 'How many lines of history to keep in memory.',
    icon: Icons.history,
  );

  final copyOnSelect = BoolSetting(
    'terminal.copyOnSelect',
    defaultValue: true,
    title: 'Copy on select',
    subtitle: 'When true, selecting text automatically copies it.',
    icon: Icons.content_copy,
  );

  final bellMode = EnumSetting<BellMode>(
    'terminal.bellMode',
    defaultValue: BellMode.visual,
    values: BellMode.values,
    label: _enumName,
    title: 'Bell',
    subtitle: 'What to do when a shell emits the bell character.',
    icon: Icons.notifications_active,
  );

  final linkClickModifier = EnumSetting<LinkClickModifier>(
    'terminal.linkClickModifier',
    defaultValue: LinkClickModifier.ctrl,
    values: LinkClickModifier.values,
    label: _enumName,
    title: 'Open links with',
    subtitle:
        'Modifier key to open OSC 8 hyperlinks emitted by TUIs '
        '(opencode, gh, lazygit, etc.). Ctrl+click is the package default.',
    icon: Icons.link,
  );

  /// Show OSC 9 (iTerm2) / OSC 777 (urxvt) desktop notifications as
  /// snackbars. Some shells and shell frameworks (PSReadLine on
  /// Linux, starship, oh-my-zsh hooks) emit iTerm2-style "state"
  /// notifications on every prompt — payloads like `4:1:6` that
  /// aren't user-facing text and produce a flood of snackbars.
  /// Default is `false` because the noise outweighs the signal for
  /// most users; opt in if a particular tool relies on this channel.
  final notifyOnOsc9 = BoolSetting(
    'terminal.notifyOnOsc9',
    defaultValue: false,
    title: 'Desktop notifications from terminal',
    subtitle:
        'Show snackbars when a shell or tool emits an OSC 9 / OSC 777 '
        'desktop notification (e.g. `printf \'\\e]9;build done\\a\'`). '
        'Off by default because the iTerm2 state form is noisy.',
    icon: Icons.notifications,
  );

  Iterable<Setting<dynamic>> get all sync* {
    yield fontFamily;
    yield fontSize;
    yield cursorStyle;
    yield cursorColor;
    yield cursorBlink;
    yield scrollbackLines;
    yield copyOnSelect;
    yield bellMode;
    yield linkClickModifier;
    yield notifyOnOsc9;
  }
}

class GeneralSettingsSection {
  /// Active theme palette id (Catppuccin Mocha, Catppuccin Latte,
  /// Dracula, etc.). The [PaletteIdCodec] validates against the
  /// built-in registry and falls back to the default for unknown
  /// ids, so a stale settings file still boots into a known theme.
  final themeName = StringSetting(
    'appearance.themeName',
    defaultValue: 'catppuccin-mocha',
    codecOverride: const PaletteIdCodec(),
    title: 'Theme',
    subtitle: 'Color palette for chrome (drawer, dialogs, menus).',
    icon: Icons.palette,
  );

  /// Opacity of the terminal / window background, 0.0 (fully
  /// transparent) → 1.0 (fully opaque). Applied as an alpha
  /// multiplier on the active palette's `surface0` — the same
  /// value drives the alacritty renderer background, the Material
  /// scaffold, and the native window background, so all three
  /// agree (see [kTerminalBackground], [buildAppTheme] and
  /// `TerminalSettings.backgroundColor`). Mirrors Alacritty's
  /// `window.opacity`.
  final backgroundOpacity = DoubleSetting(
    'appearance.backgroundOpacity',
    defaultValue: 0.9,
    min: 0.0,
    max: 1.0,
    title: 'Background opacity',
    subtitle: 'Transparency of the terminal background. Lower to see through.',
    icon: Icons.opacity,
  );

  /// Native Windows acrylic (frosted-glass) blur of the desktop behind
  /// the whole window. When on, the window backdrop is blurred instead
  /// of sharp; [frostLevel] controls the tint strength. Implemented via
  /// `SetWindowCompositionAttribute` (ACCENT_ENABLE_ACRYLICBLURBEHIND),
  /// so Windows 10 1809+ / Windows 11 only — no-op elsewhere.
  final frostedBackground = BoolSetting(
    'appearance.frostedBackground',
    defaultValue: false,
    title: 'Frosted background',
    subtitle: 'Blur the desktop behind the window (native acrylic).',
    icon: Icons.blur_on,
  );

  /// Tint strength of the acrylic blur (0 = clear blur, 1 = opaque
  /// tint). Only takes effect while [frostedBackground] is on.
  final frostLevel = DoubleSetting(
    'appearance.frostLevel',
    defaultValue: 0.05,
    min: 0.0,
    max: 1.0,
    title: 'Frost level',
    subtitle: 'Tint strength of the acrylic blur (frosted background on).',
    icon: Icons.blur_linear,
  );

  final drawerDefaultCollapsed = BoolSetting(
    'appearance.drawerDefaultCollapsed',
    defaultValue: true,
    title: 'Start with sidebar collapsed',
    subtitle: 'Show only the workspace icons at startup.',
    icon: Icons.view_sidebar,
  );

  /// Confirm before quitting / closing the window. Enabled by
  /// default — a stray Ctrl+Shift+Q or accidental ×-click while
  /// typing shouldn't terminate a long-running build / interactive
  /// REPL session. Toggle off if you want a faster exit path.
  final confirmOnExit = BoolSetting(
    'appearance.confirmOnExit',
    defaultValue: true,
    title: 'Confirm before exit',
    subtitle:
        'Show a confirmation dialog when quitting (Ctrl+Shift+Q) or '
        'closing the window.',
    icon: Icons.exit_to_app,
  );

  Iterable<Setting<dynamic>> get all sync* {
    yield themeName;
    yield backgroundOpacity;
    yield frostedBackground;
    yield frostLevel;
    yield drawerDefaultCollapsed;
    yield confirmOnExit;
  }
}

class ShortcutSettingsSection {
  /// Master switch for the app-level early-key-event handler in
  /// `_AppShellState._buildMergedShortcuts`. When `false`, the
  /// merged binding map is replaced with an empty map so every
  /// shortcut in `AppShortcuts.all` is dispatched to `ignored`
  /// and the event falls through to the normal focus tree (and
  /// eventually to `flutter_alacritty`, which encodes unbound
  /// chords into PTY bytes — so a bare Ctrl+letter press still
  /// reaches the shell, just without the app intercepting it).
  ///
  /// Default `true` — every binding in the merged map is active
  /// at launch. Toggling it off is for users who want pure
  /// terminal behavior with no app-level key handling (e.g. a
  /// tmux power user who wants to bind Ctrl+Shift+B to a tmux
  /// command without conflicting with our drawer toggle).
  final enabled = BoolSetting(
    'shortcuts.enabled',
    defaultValue: true,
    title: 'Enable keyboard shortcuts',
    subtitle:
        'Turn off to disable every app-level shortcut. Bare Ctrl-letter '
        'chords will fall through to the shell, where they can be used by '
        'readline / vim / tmux / etc.',
    icon: Icons.keyboard,
  );

  Iterable<Setting<dynamic>> get all sync* {
    yield enabled;
  }
}

class UpdateSettingsSection {
  final autoCheck = BoolSetting(
    'update.autoCheck',
    defaultValue: true,
    title: 'Check for updates automatically',
    subtitle: 'Probe the update feed on launch and once an hour while running.',
    icon: Icons.sync,
  );

  final repository = StringSetting(
    'update.repository',
    defaultValue: '',
    title: 'Update repository (owner/repo)',
    subtitle:
        'Leave empty to follow invented-pro/octodo on GitHub. '
        'Use an "owner/repo" value to follow a fork or pre-release build.',
    icon: Icons.cloud_outlined,
  );

  /// Optional. JSON manifest URL mirroring GitHub's release shape
  /// (typically a Cloudflare R2 + custom domain, or any HTTPS bucket
  /// of static objects). Used when the primary GitHub feed fails —
  /// including rate-limit — so the in-app updater can still resolve
  /// a release.
  ///
  /// Defaults to the project's public R2 mirror so the fallback is
  /// active out of the box for official `invented-pro/octodo` builds.
  /// Forks point this at their own mirror (or set it to '' in their
  /// `settings.json` to disable the fallback entirely).
  ///
  /// Not surfaced in the settings dialog yet; the corresponding
  /// jsonc key is `update.fallbackUrl`.
  final fallbackUrl = StringSetting(
    'update.fallbackUrl',
    defaultValue: 'https://s3.primorial.net/octodo/manifest.json',
    title: 'Fallback update feed URL',
    subtitle:
        'Optional. JSON manifest mirroring GitHub\'s release shape; '
        'used when the primary GitHub feed fails (including rate-limit). '
        'Leave empty to disable.',
    icon: Icons.cloud_circle_outlined,
  );

  Iterable<Setting<dynamic>> get all sync* {
    yield autoCheck;
    yield repository;
    yield fallbackUrl;
  }
}
