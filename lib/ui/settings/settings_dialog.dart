// The settings dialog:
//   * NavigationDrawer on the left (General / Terminal / Settings
//     files).
//   * Detail pane on the right: a single eager (non-lazy)
//     SingleChildScrollView with all sections upfront, so any
//     row can be scrolled to via GlobalKey.
//   * Top-right toggle: "Show JSON paths" (debug).
//   * Bottom bar: "Open settings.json" (reveals the file) and
//     "Reset all to defaults".

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../src/app_info.dart';
import '../../src/log.dart';
import '../../src/settings/setting.dart';
import '../../src/settings/settings_catalog.dart';
import '../../src/settings/settings_runtime.dart';
import 'chrome/settings_card.dart';
import 'chrome/settings_row.dart';
import 'widgets/trailing_widgets.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  bool _showJsonPaths = false;
  String _section = 'general';

  /// Timestamp of the most recent write, used to drive the
  /// "Saved" indicator in the footer. null = no writes yet.
  DateTime? _lastWrite;

  /// Set briefly after a write to drive a pulse animation.
  bool _pulse = false;

  StreamSubscription<void>? _writeSub;

  @override
  void initState() {
    super.initState();
    _writeSub = SettingsRuntime.instance.store
        .watchWrites()
        .listen((_) => _onWrite());
  }

  @override
  void dispose() {
    _writeSub?.cancel();
    super.dispose();
  }

  void _onWrite() {
    if (!mounted) return;
    setState(() {
      _lastWrite = DateTime.now();
      _pulse = true;
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _pulse = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final runtime = SettingsRuntime.instance;
    final catalog = runtime.catalog;
    return Dialog(
      backgroundColor: const Color(0xFF1A1A24),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF45475A), width: 1),
      ),
      child: SizedBox(
        width: 900,
        height: 640,
        child: Column(
          children: [
            _Header(showJsonPaths: _showJsonPaths,
                onToggleJsonPaths: (v) => setState(() => _showJsonPaths = v)),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: _Sidebar(
                      selected: _section,
                      onSelect: (s) => setState(() => _section = s),
                    ),
                  ),
                  Container(width: 1, color: const Color(0xFF313244)),
                  Expanded(
                    child: _Detail(
                      section: _section,
                      catalog: catalog,
                      showJsonPaths: _showJsonPaths,
                    ),
                  ),
                ],
              ),
            ),
            _Footer(
              runtime: runtime,
              lastWrite: _lastWrite,
              pulse: _pulse,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final bool showJsonPaths;
  final ValueChanged<bool> onToggleJsonPaths;
  const _Header({required this.showJsonPaths, required this.onToggleJsonPaths});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: Color(0xFF242430),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
        border: Border(bottom: BorderSide(color: Color(0xFF45475A), width: 1)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF89B4FA).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.settings, size: 16, color: Color(0xFF89B4FA)),
          ),
          const SizedBox(width: 10),
          const Text('Settings',
              style: TextStyle(
                  color: Color(0xFFEFF1F5),
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF313244),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(kAppName,
                style: const TextStyle(
                    color: Color(0xFFBAC2DE),
                    fontSize: 10,
                    fontFamily: 'monospace')),
          ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Show JSON paths',
                  style: TextStyle(color: Color(0xFFBAC2DE), fontSize: 11)),
              const SizedBox(width: 6),
              Switch(
                value: showJsonPaths,
                onChanged: onToggleJsonPaths,
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: const Color(0xFFBAC2DE),
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;
  const _Sidebar({required this.selected, required this.onSelect});

  static const _items = [
    ('general', 'General', Icons.tune),
    ('terminal', 'Terminal', Icons.terminal),
    ('paths', 'Settings files', Icons.folder),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF20202A),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final (id, label, icon) in _items)
            _SidebarItem(
              label: label,
              icon: icon,
              selected: id == selected,
              onTap: () => onSelect(id),
            ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF89B4FA).withValues(alpha: 0.20)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected
                  ? const Color(0xFF89B4FA).withValues(alpha: 0.6)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15,
                  color: selected
                      ? const Color(0xFF89B4FA)
                      : const Color(0xFF7F849C)),
              const SizedBox(width: 10),
              Text(label,
                  style: TextStyle(
                      color: selected
                          ? const Color(0xFFEFF1F5)
                          : const Color(0xFFBAC2DE),
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  final String section;
  final SettingsCatalog catalog;
  final bool showJsonPaths;
  const _Detail({
    required this.section,
    required this.catalog,
    required this.showJsonPaths,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A24),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        // Eager (non-lazy) — every row is built upfront so any can
        // be scrolled to via GlobalKey.
        child: switch (section) {
          'general' => _buildGeneral(),
          'terminal' => _buildTerminal(),
          'paths' => _buildPaths(context),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }

  Widget _buildTerminal() {
    final store = SettingsRuntime.instance.store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader('TERMINAL'),
        SettingsCard(children: [
          _rowFor(catalog.terminal.fontFamily, showJsonPaths, store),
          _rowFor(catalog.terminal.fontSize, showJsonPaths, store),
          _rowFor(catalog.terminal.cursorStyle, showJsonPaths, store),
          _rowFor(catalog.terminal.cursorBlink, showJsonPaths, store),
          _rowFor(catalog.terminal.scrollbackLines, showJsonPaths, store),
          _rowFor(catalog.terminal.copyOnSelect, showJsonPaths, store),
          _rowFor(catalog.terminal.bellMode, showJsonPaths, store),
        ]),
      ],
    );
  }

  Widget _buildGeneral() {
    final store = SettingsRuntime.instance.store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader('GENERAL'),
        SettingsCard(children: [
          _rowFor(catalog.general.drawerDefaultCollapsed, showJsonPaths, store),
          _rowFor(catalog.general.confirmOnExit, showJsonPaths, store),
        ]),
      ],
    );
  }

  Widget _buildPaths(BuildContext context) {
    final runtime = SettingsRuntime.instance;
    final store = runtime.store;
    final path = store.path;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader('SETTINGS FILE'),
        SettingsCard(children: [
          _PathRow(store: store, isPrimary: true),
        ]),
        const SettingsSectionHeader('ACTIONS'),
        SettingsCard(children: [
          _ActionRow(
            icon: Icons.folder_open,
            title: 'Reveal settings file in file manager',
            subtitle: 'Open the location of the settings file.',
            onTap: () => runtime.hostActions.revealInFileManager(path),
          ),
          _ActionRow(
            icon: Icons.edit,
            title: 'Open settings file in text editor',
            subtitle: 'Edit the JSONC file directly. Changes hot-reload.',
            onTap: () => runtime.hostActions.openInExternalEditor(path),
          ),
          _ActionRow(
            icon: Icons.restart_alt,
            title: 'Reset all to defaults',
            subtitle: 'Clear every setting in the settings file.',
            destructive: true,
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Reset all settings?'),
                  content: const Text(
                      'This clears every value in the settings file. Defaults will be used.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Reset')),
                  ],
                ),
              );
              if (confirm == true) {
                await runtime.store.resetAll();
              }
            },
          ),
        ]),
      ],
    );
  }

  Widget _rowFor(Setting<dynamic> setting, bool showJsonPaths, store) {
    final trailing = _trailingFor(setting, store);
    return SettingsCardRow(
      jsonKey: setting.key,
      title: setting.title,
      subtitle: setting.subtitle,
      leadingIcon: setting.icon,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          trailing,
          const SizedBox(width: 6),
          ResetButtonTrailing(
            setting: setting,
            store: store,
            isAtDefault: !store.isExplicitlySet(setting),
          ),
        ],
      ),
      showJsonPaths: showJsonPaths,
    );
  }

  Widget _trailingFor(Setting<dynamic> setting, store) {
    if (setting is BoolSetting) {
      return BoolToggleTrailing(setting: setting, store: store);
    } else if (setting is IntSetting) {
      return IntInputTrailing(setting: setting, store: store);
    } else if (setting is DoubleSetting) {
      return DoubleInputTrailing(setting: setting, store: store);
    } else if (setting is StringSetting) {
      // Special-case the terminal font: a free-text field lets the
      // user type typos that silently fall back to monospace, which
      // they then can't debug. Show a dropdown of the monospace
      // faces commonly installed on Windows (plus the user's current
      // value if it's a custom face not in the known list).
      if (setting.key == 'terminal.fontFamily') {
        return FontFamilyDropdownTrailing(setting: setting, store: store);
      }
      return StringTextFieldTrailing(setting: setting, store: store);
    } else if (setting is EnumSetting) {
      return EnumDropdownTrailing(setting: setting, store: store);
    } else if (setting is ColorSetting) {
      return ColorHexFieldTrailing(setting: setting, store: store);
    }
    return const SizedBox.shrink();
  }
}

class _PathRow extends StatelessWidget {
  final dynamic store;
  final bool isPrimary;
  const _PathRow({
    required this.store,
    required this.isPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsCardRow(
      title: isPrimary ? '★ Settings file' : 'Layer',
      subtitle: store.path,
      leadingIcon: Icons.edit_note,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.folder_open, size: 14),
            color: const Color(0xFF89B4FA),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            tooltip: 'Reveal',
            onPressed: () =>
                SettingsRuntime.instance.hostActions.revealInFileManager(store.path),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 14),
            color: const Color(0xFF89B4FA),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            tooltip: 'Copy path',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: store.path));
            },
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool destructive;
  const _ActionRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsCardRow(
      title: title,
      subtitle: subtitle,
      leadingIcon: icon,
      trailing: Icon(
        Icons.chevron_right,
        size: 16,
        color: destructive ? const Color(0xFFF38BA8) : const Color(0xFF6C7086),
      ),
      onTap: onTap,
    );
  }
}

class _Footer extends StatelessWidget {
  final SettingsRuntime runtime;
  final DateTime? lastWrite;
  final bool pulse;
  const _Footer({
    required this.runtime,
    required this.lastWrite,
    required this.pulse,
  });

  String _ago(DateTime? t) {
    if (t == null) return 'never';
    final dt = DateTime.now().difference(t);
    if (dt.inSeconds < 1) return 'just now';
    if (dt.inSeconds < 60) return '${dt.inSeconds}s ago';
    if (dt.inMinutes < 60) return '${dt.inMinutes}m ago';
    return '${dt.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    final path = runtime.store.path;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: Color(0xFF242430),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        border: Border(top: BorderSide(color: Color(0xFF45475A), width: 1)),
      ),
      child: Row(
        children: [
          // ── Saved indicator ────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: pulse
                  ? const Color(0xFFA6E3A1).withValues(alpha: 0.20)
                  : const Color(0xFF313244),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: pulse
                    ? const Color(0xFFA6E3A1)
                    : const Color(0xFF45475A),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  pulse ? Icons.check_circle : Icons.save_outlined,
                  size: 12,
                  color: pulse
                      ? const Color(0xFFA6E3A1)
                      : const Color(0xFF7F849C),
                ),
                const SizedBox(width: 5),
                Text(
                  pulse ? 'Saved' : 'Last saved: ${_ago(lastWrite)}',
                  style: TextStyle(
                    color: pulse
                        ? const Color(0xFFA6E3A1)
                        : const Color(0xFFBAC2DE),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // ── Write target path (clickable) ──────────────────────
          const Icon(Icons.edit_note, size: 14, color: Color(0xFF7F849C)),
          const SizedBox(width: 4),
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () =>
                    runtime.hostActions.revealInFileManager(path),
                child: Text(
                  path,
                  style: const TextStyle(
                    color: Color(0xFFBAC2DE),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.underline,
                    decorationColor: Color(0xFF45475A),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Show the dialog ────────────────────────────────────────────────

Future<void> showSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => const SettingsDialog(),
  );
}

// ── OS helpers (used by host actions) ─────────────────────────────

final Logger _osLog = moduleLogger('settings.os');

void revealInExplorer(String path) {
  // `explorer /select,<path>` highlights the file in Explorer.
  if (Platform.isWindows) {
    _startOrLog('explorer', ['/select,', path], action: 'reveal in Explorer');
  } else if (Platform.isMacOS) {
    _startOrLog('open', ['-R', path], action: 'reveal in Finder');
  } else {
    _startOrLog('xdg-open', [File(path).parent.path],
        action: 'reveal in file manager');
  }
}

void openInTextEditor(String path) {
  if (Platform.isWindows) {
    _startOrLog('notepad.exe', [path], action: 'open in notepad');
  } else if (Platform.isMacOS) {
    _startOrLog('open', ['-e', path], action: 'open in TextEdit');
  } else {
    _startOrLog('xdg-open', [path], action: 'open in default editor');
  }
}

/// Wrap [Process.start] so a launch failure (missing executable,
/// permission denied, path not found) is logged at WARNING instead of
/// silently dropped. The user gets no UI feedback either way — these
/// helpers are best-effort — but the log line is the only signal we'd
/// have when a settings dialog button appears to do nothing.
Future<void> _startOrLog(String executable, List<String> args,
    {required String action}) async {
  try {
    await Process.start(executable, args);
  } catch (e, st) {
    _osLog.log(
        Level.WARNING, '$action failed ($executable ${args.join(' ')}): $e', e, st);
  }
}

