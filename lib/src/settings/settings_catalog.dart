// The settings catalog — single source of truth for every
// user-facing setting. Add a new field here and it shows up in
// the settings UI, the validation list, the search index, and
// the schema documentation automatically.

import 'package:flutter/material.dart';
import 'setting.dart';

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

  /// Background color of the terminal grid. Driven to both the
  /// alacritty renderer AND the Flutter window/theme background —
  /// they must always match exactly so the chrome never flashes a
  /// different shade around the terminal.
  final backgroundColor = ColorSetting(
    'terminal.backgroundColor',
    defaultValue: const Color(0xFF181818),
    title: 'Background color',
    subtitle: 'Terminal background — also used by the surrounding chrome.',
    icon: Icons.format_color_fill,
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
    yield backgroundColor;
    yield cursorStyle;
    yield cursorBlink;
    yield scrollbackLines;
    yield copyOnSelect;
    yield bellMode;
  }
}

class GeneralSettingsSection {
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
