// The settings catalog — single source of truth for every
// user-facing setting. Add a new field here and it shows up in
// the settings UI, the validation list, the search index, and
// the schema documentation automatically.

import 'package:flutter/material.dart';
import 'setting.dart';
import 'setting_codec.dart';

enum CursorStyle { block, underline, bar }
enum BellMode { none, visual, sound }

String _enumName(Enum e) => e.name;

class SettingsCatalog {
  final general = GeneralSettingsSection();
  final terminal = TerminalSettingsSection();
  final update = UpdateSettingsSection();

  /// All settings in declaration order. Used by the settings UI
  /// to build the section list and by the schema validator.
  Iterable<Setting<dynamic>> get all sync* {
    yield* general.all;
    yield* terminal.all;
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

  Iterable<Setting<dynamic>> get all sync* {
    yield fontFamily;
    yield fontSize;
    yield cursorStyle;
    yield cursorBlink;
    yield scrollbackLines;
    yield copyOnSelect;
    yield bellMode;
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
    yield drawerDefaultCollapsed;
    yield confirmOnExit;
  }
}

class UpdateSettingsSection {
  final autoCheck = BoolSetting(
    'update.autoCheck',
    defaultValue: true,
    title: 'Check for updates automatically',
    subtitle:
        'Probe the update feed on launch and once an hour while running.',
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

  Iterable<Setting<dynamic>> get all sync* {
    yield autoCheck;
    yield repository;
  }
}
