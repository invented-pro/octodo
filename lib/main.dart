import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'src/app_info.dart';
import 'src/settings/json_settings_store.dart';
import 'src/settings/paths.dart';
import 'src/settings/settings_runtime.dart';
import 'src/log.dart';
import 'src/shortcuts/app_shortcuts.dart';
import 'src/terminal/shell_profiles.dart';
import 'src/terminal/terminal_workspace.dart';
import 'src/update/installer/apply_main.dart';
import 'src/update/update_controller.dart';
import 'src/update/update_state.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/palette_context.dart';
import 'src/theme/palettes.dart';
import 'ui/settings/settings_dialog.dart';
import 'ui/update/update_pill.dart';

/// The running app's version, fetched from the platform at startup
/// via `package_info_plus`. Compared against the manifest's
/// `version` to decide whether an update is available.
///
/// Initialized in `main()` *before* `runApp`, so the value is
/// non-null and stable by the time any widget reads it.
late final String kAppVersion;

final Logger _log = moduleLogger('main');

/// Resolves the effective terminal background color against the live
/// settings store. Used by both the Flutter window (via
/// [WindowOptions.backgroundColor]) and the Material [ThemeData]
/// scaffold background, so they always match the alacritty
/// renderer's background (which reads the same value in
/// `TerminalView._buildConfig`).
///
/// Always tracks the active palette's `surface0` — the previous
/// `terminal.backgroundColor` user override has been removed (it
/// defeated the "theme change retints the terminal" goal, since an
/// explicit override always won over the palette).
Color get kTerminalBackground {
  final store = SettingsRuntime.instance.store;
  final catalog = SettingsRuntime.instance.catalog;
  return AppPalettes
      .byId(store.get(catalog.general.themeName))
      .surface0;
}


Future<void> main() async {
  // Helper-mode entry: if the previous running app spawned us with
  // OCTODO_UPDATE_HELPER=1 (i.e. "apply the staged update and exit"),
  // we route away from any Flutter / window initialization. See
  // lib/src/update/installer/apply_main.dart.
  if (isHelperMode) {
    final code = await runUpdateHelper();
    // Use the dart:io exit; Flutter's binding isn't initialized
    // here, so we can't `runApp` on the helper-mode path.
    exit(code);
  }

  WidgetsFlutterBinding.ensureInitialized();
  // Wire up the root logger before anything else runs, so startup
  // diagnostics land in the same handler as the rest of the app.
  configureLogging();
  // flutter_alacritty is a flutter_rust_bridge wrapper; the bridge
  // must be initialized once at startup before any TerminalEngine is
  // constructed (otherwise the first surface throws
  // "RustLib has not been initialized"). Safe to call after
  // ensureInitialized() and before runApp().
  await RustLib.init();
  // Settings must be live before windowManager so the native window
  // background picks up the active palette's `surface0` — the same
  // value drives the alacritty renderer (see TerminalView._buildConfig)
  // and the Scaffold theme (see OctodoApp.build). All three must
  // agree so the chrome never flashes a different shade around the
  // terminal grid.
  await _initSettings();
  final backgroundColor = kTerminalBackground;
  // window_manager: required before any WindowOptions / show call so
  // the plugin's platform-channel handlers are wired up. Sets the
  // initial 1280×720 size + centers the window on the host monitor
  // (`center: true` resolves the monitor via the native Win32 API
  // and respects DPI + multi-monitor setups). `waitUntilReadyToShow`
  // defers `show()` until the first Flutter frame is rendered so the
  // user never sees the window flash at its initial (10, 10)
  // position with a white background.
  await windowManager.ensureInitialized();
  // The Windows AppUserModelID (a.k.a. package namespace) is pinned
  // in windows/runner/main.cpp via SetCurrentProcessExplicitAppUserModelID
  // *before* the first Flutter window is created — the Dart side can't
  // do this because window_manager 0.5.1 has no setAppUserModelId, and
  // setting it after the window exists means the first window is already
  // grouped under the wrong identity.
  final windowOptions = WindowOptions(
    size: Size(1280, 720),
    center: true,
    backgroundColor: backgroundColor,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    // Apply the localized title after the window is up — kAppName is
    // resolved from the system locale (currently always 'Octodo') and
    // isn't a compile-time constant, so it can't go inside the const
    // WindowOptions above.
    await windowManager.setTitle(kAppName);
  });
  try {
    final info = await PackageInfo.fromPlatform();
    kAppVersion = info.version;
  } catch (e) {
    // `package_info_plus` should never fail on a packaged build,
    // but fall back to a sentinel that will never compare as an
    // update (so the pill just stays idle).
    _log.severe('PackageInfo.fromPlatform failed: $e');
    kAppVersion = '0.0.0';
  }
  runApp(const OctodoApp());
}

/// Initialize the [SettingsRuntime] singleton. Persists all settings
/// to `<userHome>/.config/Octodo/settings.json` (created on first
/// write) and watches the file for external edits (250ms poll).
Future<void> _initSettings() async {
  final paths = SettingsPaths.resolve();
  // Initial settings load runs on a background isolate via
  // JsonSettingsStore.create — see json_settings_store.dart. Keeps
  // the file read + JSONC parse off the UI isolate's startup path
  // so the first frame isn't blocked.
  final store = await JsonSettingsStore.create(paths.file);
  SettingsRuntime.instance = SettingsRuntime.create(
    store: store,
    hostActions: SettingsHostActions(
      revealInFileManager: revealInExplorer,
      openInExternalEditor: openInTextEditor,
      restartApp: () {
        // Not implemented in v1 — would relaunch the app process.
      },
    ),
  );
}

class OctodoApp extends StatefulWidget {
  const OctodoApp({super.key});
  @override
  State<OctodoApp> createState() => _OctodoAppState();
}

class _OctodoAppState extends State<OctodoApp> {
  /// Subscribes to `appearance.themeName` so the MaterialApp rebuilds
  /// whenever the user picks a new palette. The window's native
  /// background (`WindowOptions.backgroundColor` in `main()`) is
  /// set once at startup — `window_manager` has no API to retint
  /// an open window without recreating it, so live changes affect
  /// the Scaffold background only; restarting the app is required
  /// to repaint the window frame itself.
  StreamSubscription<String>? _themeSub;

  @override
  void initState() {
    super.initState();
    final catalog = SettingsRuntime.instance.catalog;
    _themeSub = SettingsRuntime.instance.store
        .watch<String>(catalog.general.themeName)
        .listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _themeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalettes.byId(
      SettingsRuntime.instance.store
          .get(SettingsRuntime.instance.catalog.general.themeName),
    );
    // The same palette is provided to both `theme` and `darkTheme`;
    // Material picks which one to use based on `themeMode`, which
    // we derive from the palette's brightness.
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(palette: palette),
      darkTheme: buildAppTheme(palette: palette),
      themeMode: palette.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: const AppShell(),
    );
  }
}

// ── Workspace entry ──────────────────────────────────────────────────

class _WorkspaceEntry {
  final GlobalKey<TerminalWorkspaceState> key = GlobalKey();
  final String id;
  String name;
  Color color;

  /// True once the user has explicitly renamed this workspace via
  /// the drawer's double-click rename affordance. Drives the
  /// window-title suffix (we don't append the auto-generated
  /// "Workspace N" default — only user-customized names appear in
  /// the title bar / taskbar).
  bool renamed = false;

  bool exited = false;

  _WorkspaceEntry({
    required this.id,
    required this.name,
    required this.color,
  });
}

/// Payload carried by a workspace-tile drag. We only ship the
/// stable workspace ID; the parent [_AppShellState] resolves the
/// current index when a drop happens (drag/drop in Flutter is
/// payload-agnostic, so we don't trust the captured index).
class _WorkspaceDragData {
  final String workspaceId;
  const _WorkspaceDragData(this.workspaceId);
}

// ── App shell ────────────────────────────────────────────────────────

/// Top-level app shell — manages multiple workspaces via a collapsible
/// left-side drawer.
///
/// Layout:
///   ┌──────┬─────────────────────────────────────────────┐
///   │ WS   │  active workspace content                   │
///   │ bar  │  (tab bar + pane area)                      │
///   │      │                                              │
///   │ ▼    │                                              │
///   └──────┴─────────────────────────────────────────────┘
///
/// Shortcuts: see `lib/src/shortcuts/app_shortcuts.dart` for the
/// full scheme and the audit against readline / vim / tmux / btop
/// keybindings. The bindings themselves are installed by
/// [AppShellBindings.build] in the build method below.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WidgetsBindingObserver, WindowListener {
  final List<_WorkspaceEntry> _workspaces = [];
  int _currentIndex = 0;
  int _wsCounter = 0;
  /// Available shells for new tabs. `null` while the off-isolate
  /// probe is still running (see [_bootstrapAsync]); the build
  /// shows a loading placeholder in that case.
  List<ShellProfile>? _shells;
  late final UpdateStateModel _updateModel;
  late final UpdateController _updateController;

  /// Drawer collapsed = true (icon-only strip), false = full sidebar.
  /// Initial value comes from `general.drawerDefaultCollapsed`.
  late bool _drawerCollapsed = SettingsRuntime.instance.store
      .get(SettingsRuntime.instance.catalog.general.drawerDefaultCollapsed);

  /// Cached [BuildContext] of the app-shell subtree, captured on
  /// each [build]. Used by async mutators (e.g. the close-workspace
  /// confirmation dialog) that need a [BuildContext] but aren't
  /// invoked from a build-time callback. Always guarded by a
  /// `mounted` check before use — [_AppShellState] lives for the
  /// lifetime of the app, so the context stays valid in practice;
  /// the [mounted] guard handles hot restart / dispose.
  BuildContext? _shellContext;

  /// Workspace accent colors (cycled). Sourced from the active
  /// theme palette's [ThemePalette.workspaceSwatches] so the
  /// default workspace indicators stay legible on whatever
  /// drawer surface the user picked. Hardcoded Mocha accents
  /// would wash out on Latte's pale drawer (~1.5:1 contrast);
  /// each palette's own accent set is calibrated for both
  /// polarities.
  List<Color> _activeWsColors() => _activePalette().workspaceSwatches;

  /// Swatches derived from the active palette's workspace colors
  /// for the color picker's "Custom" tab. Each accent becomes a
  /// primary swatch (shades 50-900 generated around the source
  /// color as shade 500) so users can pick a quick curated color
  /// while keeping the HSV wheel tab open for free-form selection.
  ///
  /// Built lazily — [ColorTools.createPrimarySwatch] is a runtime
  /// computation, so the map can't be const.
  Map<ColorSwatch<Object>, String> _activeWsColorSwatches() {
    final names = ['Blue', 'Green', 'Yellow', 'Pink', 'Purple', 'Teal', 'Orange'];
    final colors = _activeWsColors();
    return {
      for (var i = 0; i < colors.length; i++)
        ColorTools.createPrimarySwatch(colors[i]): names[i],
    };
  }

  /// Resolve the live theme palette from settings. Mirrors the
  /// lookup [OctodoApp.build] does for the MaterialApp; read here
  /// whenever a workspace-level color decision has to be made
  /// outside a [BuildContext] (e.g. `_newWorkspace`).
  ThemePalette _activePalette() => AppPalettes.byId(
        SettingsRuntime.instance.store
            .get(SettingsRuntime.instance.catalog.general.themeName),
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    // Probe installed shells off the UI isolate so the ~90 ms
    // `wsl.exe --list --quiet` call (and ~6 `existsSync` checks)
    // don't block the first frame. The build shows a loading
    // placeholder until the future resolves; see [build].
    _bootstrapAsync();

    _updateModel = UpdateStateModel(currentVersion: kAppVersion);
    _updateController = UpdateController(
      model: _updateModel,
      settings: SettingsRuntime.instance.catalog.update,
      userAgentVersion: kAppVersion,
    );
    _updateController.start();

    // Install the hardware-level shortcut handler — see the comment
    // block above for why we can't rely on `CallbackShortcuts` here
    // (flutter_alacritty's `Focus.onKeyEvent` consumes every
    // keystroke before it bubbles up).
    _installEarlyKeyHandler();

    // Intercept the OS-level close signal so we can show the
    // "Exit Octodo?" dialog when the user clicks the window's × button.
    // The handler checks `general.confirmOnExit` at close time
    // and either lets `destroy()` run or cancels based on the user's
    // answer.
    windowManager.setPreventClose(true);
  }

  /// Resolves the shell list off-isolate, then mounts the first
  /// workspace and rebuilds. Until the future completes, [build]
  /// shows a minimal loading MaterialApp so the window has
  /// something to paint while the probe runs.
  Future<void> _bootstrapAsync() async {
    final shells = await detectShellsAsync();
    if (!mounted) return;
    setState(() {
      _shells = shells;
      _newWorkspace();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _activeWorkspace?.key.currentState?.focusCurrentPane();
      });
      return;
    }
    if (state == AppLifecycleState.detached) {
      // Window-close button on Windows triggers `detached` but does not
      // by itself terminate the process — flutter_pty's ConPTY reader
      // thread, the flutter_rust_bridge Tokio runtime, and any live
      // shell child process (pwsh.exe / wsl.exe / bash.exe) keep the
      // host isolate alive after the window is gone. `exit(0)` here
      // is the documented escape hatch (per the Flutter `ProcessExit`
      // guidance) and matches what cmd/PowerShell-hosted tools do.
      exit(0);
    }
  }

  _WorkspaceEntry? get _activeWorkspace =>
      _workspaces.isNotEmpty ? _workspaces[_currentIndex] : null;

  // ── Window title ──────────────────────────────────────────────────

  /// Build the native window title. Appends the active workspace's
  /// custom name only when the user has explicitly renamed it
  /// (driven by `_WorkspaceEntry.renamed`); auto-generated
  /// "Workspace N" defaults don't bloat the title bar / taskbar.
  /// Format: `kAppName — <custom name>` (em dash + spaces, the
  /// conventional document-title separator).
  String _composeWindowTitle() {
    final active = _activeWorkspace;
    if (active == null || !active.renamed) return kAppName;
    return '$kAppName — ${active.name}';
  }

  /// Push the current title to the host window. Safe to call from
  /// any mutator; idempotent if the title hasn't changed.
  void _updateWindowTitle() {
    if (!mounted) return;
    windowManager.setTitle(_composeWindowTitle());
  }

  // ── Top-level shortcut dispatch ──────────────────────────────
  //
  // We register a single `FocusManager.addEarlyKeyEventHandler` from
  // `initState`. "Early" handlers run **before** any Focus node's
  // `onKeyEvent` callback — including `flutter_alacritty`'s
  // `_onKeyFallback`, which lives on the innermost `Focus` inside
  // `TerminalView`. If we return `KeyEventResult.handled`, the focus
  // tree walk is short-circuited and FA never sees the event, so
  // nothing leaks into the PTY.
  //
  // Why this works (verified against `flutter/services/hardware_keyboard.dart`
  // and `flutter/widgets/focus_manager.dart`):
  //
  //   * `HardwareKeyboard.addHandler` is **not** sufficient. It
  //     runs in parallel with the focus tree dispatch — see
  //     `_HardwareKeyboardState._dispatchKeyEvent` (which iterates
  //     all handlers and OR-s their results, never breaking early)
  //     and `RawKeyboard.handleRawKeyEvent`, which always invokes
  //     both `handleKeyEvent` and `_dispatchKeyMessage` (the focus
  //     tree). So a `HardwareKeyboard` handler that returns `true`
  //     does NOT prevent `flutter_alacritty`'s `_onKeyFallback`
  //     from encoding the chord into PTY bytes — that was the
  //     ^B / ^N leak we saw earlier.
  //   * `FocusManager.addEarlyKeyEventHandler`, by contrast, is
  //     consulted **before** the focus tree walk in
  //     `FocusManager.handleKeyMessage`. Returning
  //     `KeyEventResult.handled` there returns `true` from
  //     `handleKeyMessage`, which makes the binding layer skip the
  //     rest of the dispatch chain. This is the only place in the
  //     pipeline that can suppress `flutter_alacritty`'s
  //     `_onKeyFallback`.
  //
  // Three additional concerns:
  //
  //   1. **EditableText passthrough.** The workspace rename
  //      `TextField` (and any future inline editor) needs Ctrl+V /
  //      Ctrl+Shift+C / Ctrl+Insert / Shift+Insert to act as
  //      paste / copy in the field. We skip those clipboard
  //      activators whenever the primary focus is on (or inside) an
  //      `EditableText`.
  //   2. **Closure capture.** The merged binding map captures
  //      `_AppShellState` instance methods by reference, so a fresh
  //      closure on each build correctly reads the latest
  //      `_currentIndex` / `_workspaces` / etc.
  //   3. **Lifecycle.** `FocusManager` is a process-wide singleton.
  //      We add in `initState` and remove in `dispose` so hot
  //      restart / app shutdown don't leak handlers.

  /// Cached merged binding map, rebuilt on each [build].
  Map<ShortcutActivator, VoidCallback>? _mergedShortcuts;

  /// Install in [initState]; uninstall in [dispose].
  void _installEarlyKeyHandler() {
    FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyKeyEvent);
  }

  void _uninstallEarlyKeyHandler() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKeyEvent);
  }

  /// The merged binding map for the early handler. Built fresh
  /// every build because closures over `_activeWorkspace` and
  /// friends need to track the current state.
  ///
  /// [buildContext] is the AppShell's [BuildContext] captured by
  /// the calling build method. The `openSettings` callback closes
  /// over it directly so it doesn't have to reach for `_shellContext`
  /// at dispatch time — `_shellContext` could in principle be null
  /// between `dispose` and a final rebuild (although rare), and a
  /// stale context captured by reference could in principle outlive
  /// the Element it came from. Capturing [buildContext] by value at
  /// build time dodges both concerns.
  Map<ShortcutActivator, VoidCallback> _buildMergedShortcuts(
    BuildContext buildContext,
  ) {
    return {
      ...AppShellBindings.build(
        toggleDrawer: _toggleDrawer,
        newWorkspace: _newWorkspace,
        closeCurrentWorkspace: () => _closeWorkspace(_currentIndex),
        nextWorkspace: _nextWorkspace,
        previousWorkspace: _previousWorkspace,
        jumpToWorkspace: _selectWorkspace,
        toggleFullscreen: _toggleFullscreen,
        quit: _quit,
        showReservedHint: _showReservedHint,
      ),
      ...WorkspaceBindings.build(
        newTab: _delegateNewTab,
        closeTab: _delegateCloseTab,
        nextTab: _delegateNextTab,
        previousTab: _delegatePreviousTab,
        jumpToTab: _delegateJumpToTab,
        splitRight: _delegateSplitRight,
        splitDown: _delegateSplitDown,
        focusPaneInDirection: _delegateFocusPaneInDirection,
        toggleMaximizePane: _delegateToggleMaximize,
      ),
      ...TerminalBindings.build(
        copySelection: _delegateCopySelection,
        paste: _delegatePaste,
        scrollPageUp: _delegateScrollPageUp,
        scrollPageDown: _delegateScrollPageDown,
        scrollPageUpFast: _delegateScrollPageUpFast,
        scrollPageDownFast: _delegateScrollPageDownFast,
      ),
    };
  }

  /// The early-key-event handler. Returns `KeyEventResult.handled`
  /// to short-circuit the focus tree walk (so `flutter_alacritty`'s
  /// `_onKeyFallback` never encodes the chord for the PTY) or
  /// `KeyEventResult.ignored` to let the event fall through to the
  /// normal focus tree dispatch.
  KeyEventResult _handleEarlyKeyEvent(KeyEvent event) {
    // Mirror what `CallbackShortcuts` does: only act on key-down /
    // key-repeat. Key-up is irrelevant for our intents.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final hw = HardwareKeyboard.instance;
    final bindings = _mergedShortcuts ?? const {};

    // Iterate the merged map in insertion order — Dart preserves
    // insertion order in `LinkedHashMap`, so the order is:
    //   App-level → Workspace-level → Terminal-level.
    // More-specific (deeper) bindings win on collisions. In
    // practice there are no collisions between scopes (the three
    // sets are disjoint — Ctrl+Shift+1..9 vs Ctrl+1..9 etc.), but
    // the ordering is the right default.
    for (final entry in bindings.entries) {
      final activator = entry.key;
      if (!activator.accepts(event, hw)) continue;

      // Clipboard passthrough: when an `EditableText` has focus
      // (e.g. the workspace rename `TextField`), let the framework's
      // normal text-editing shortcuts work — Ctrl+V paste,
      // Ctrl+Shift+C / Ctrl+Insert copy, Shift+Insert paste, etc.
      if (_isClipboardActivator(activator) && _isInEditableContext()) {
        continue;
      }

      entry.value();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Returns true for clipboard-related activators that should defer
  /// to an in-focus `EditableText`. Conservative: anything that
  /// looks like copy / paste.
  bool _isClipboardActivator(ShortcutActivator activator) {
    if (activator is! SingleActivator) return false;
    final key = activator.trigger;
    return key == LogicalKeyboardKey.keyV ||
        key == LogicalKeyboardKey.keyC ||
        key == LogicalKeyboardKey.insert ||
        key == LogicalKeyboardKey.keyX;
  }

  /// True when the current primary focus is on (or inside) an
  /// `EditableText` widget. `TextField` internally wraps an
  /// `EditableText`; the workspace rename field is one. We walk up
  /// the element tree from the focused widget's [BuildContext] to
  /// catch either layout (the focus node belongs to EditableText
  /// directly) or wrapper layout (focus is on a child of EditableText
  /// — Material's text field has a couple of layers).
  bool _isInEditableContext() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    final ctx = primary.context;
    if (ctx == null) return false;
    bool found = false;
    ctx.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = true;
        return false; // stop walking
      }
      return true; // keep walking
    });
    return found;
  }

  // Workspace-level dispatchers. Each one no-ops if there's no
  // active workspace (defensive — the binding only matches while the
  // app is in the foreground, so this should always have a target).
  void _delegateNewTab() =>
      _activeWorkspace?.key.currentState?.newTabPublic();
  void _delegateCloseTab() =>
      _activeWorkspace?.key.currentState?.closeTabPublic();
  void _delegateNextTab() =>
      _activeWorkspace?.key.currentState?.nextTabPublic();
  void _delegatePreviousTab() =>
      _activeWorkspace?.key.currentState?.previousTabPublic();
  void _delegateJumpToTab(int index) =>
      _activeWorkspace?.key.currentState?.jumpToTabPublic(index);
  void _delegateSplitRight() =>
      _activeWorkspace?.key.currentState?.splitRightPublic();
  void _delegateSplitDown() =>
      _activeWorkspace?.key.currentState?.splitDownPublic();
  void _delegateFocusPaneInDirection(PaneDirection direction) =>
      _activeWorkspace?.key.currentState?.focusPaneInDirectionPublic(direction);
  void _delegateToggleMaximize() =>
      _activeWorkspace?.key.currentState?.toggleMaximizePanePublic();

  // Terminal-level dispatchers. Each one resolves the focused
  // terminal view inside the active workspace; no-ops if no view is
  // available (rare — only the very first frames before
  // `_initRootPane` finishes).
  void _delegateCopySelection() => _activeWorkspace
      ?.key.currentState
      ?.getFocusedTerminalViewState()
      ?.copySelectionToClipboardPublic();
  void _delegatePaste() => _activeWorkspace
      ?.key.currentState
      ?.getFocusedTerminalViewState()
      ?.pasteFromClipboardPublic();
  void _delegateScrollPageUp() => _activeWorkspace
      ?.key.currentState
      ?.getFocusedTerminalViewState()
      ?.scrollPagePublic(-1);
  void _delegateScrollPageDown() => _activeWorkspace
      ?.key.currentState
      ?.getFocusedTerminalViewState()
      ?.scrollPagePublic(1);
  void _delegateScrollPageUpFast() => _activeWorkspace
      ?.key.currentState
      ?.getFocusedTerminalViewState()
      ?.scrollPageFastPublic(-1);
  void _delegateScrollPageDownFast() => _activeWorkspace
      ?.key.currentState
      ?.getFocusedTerminalViewState()
      ?.scrollPageFastPublic(1);

  // ── Workspace management ──────────────────────────────────────────

  _WorkspaceEntry _newWorkspace() {
    final ws = _WorkspaceEntry(
      id: 'ws-${_wsCounter++}',
      name: 'Workspace $_wsCounter',
      color: _activeWsColors()[(_wsCounter - 1) % _activeWsColors().length],
    );
    _workspaces.add(ws);
    _currentIndex = _workspaces.length - 1;
    setState(() {});
    _updateWindowTitle();
    // Focus is handled inside `TerminalWorkspaceState._initRootPane`
    // once the workspace's first surface has been created and the
    // rebuild has flushed — see that method for the rationale. Doing
    // it here in a postFrameCallback would fire too early (before
    // `_initRootPane` finishes awaiting `_makeSurface`, which awaits
    // the WSL `$HOME` query — up to 1 s), find `_focusedContainer`
    // still null, and silently no-op.
    return ws;
  }

  /// Commit a new display name for a workspace. The caller has
  /// already trimmed and rejected empty input; we just update the
  /// in-memory entry, flip the `renamed` flag (so the window title
  /// starts appending the custom name), and rebuild.
  ///
  /// Note: workspace state (including names) is not persisted across
  /// launches in v1 — see the comment block on [_WorkspaceEntry] /
  /// `initState`. This rename is therefore session-scoped. Persisting
  /// workspaces is a separate feature with its own design questions
  /// (color, order, pane layout, etc.).
  void _renameWorkspace(String id, String newName) {
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i < 0) return;
    if (_workspaces[i].name == newName) return;
    setState(() {
      _workspaces[i].name = newName;
      _workspaces[i].renamed = true;
    });
    _updateWindowTitle();
  }

  /// Show the workspace color picker. Returns the picked color, or
  /// null if the user cancelled (Cancel button, Esc, or tap outside
  /// the barrier).
  ///
  /// Uses [flex_color_picker] (`ColorPicker.showPickerDialog`) for
  /// full HSV-wheel flexibility plus the curated swatches exposed
  /// as the Custom tab for quick access. The picker's built-in
  /// dialog handles OK / Cancel / barrier-dismiss; we capture the
  /// latest color via [ColorPicker.onColorChanged] so we can
  /// return the final value (the built-in `showPickerDialog`
  /// returns `bool`, not `Color`).
  Future<Color?> _pickColor(BuildContext context, Color current) async {
    Color working = current;
    final ok = await ColorPicker(
      color: current,
      onColorChanged: (c) => working = c,
      enableOpacity: false,
      showColorCode: true,
      showColorName: true,
      showMaterialName: false,
      pickersEnabled: const <ColorPickerType, bool>{
        ColorPickerType.custom: true,
        ColorPickerType.wheel: true,
      },
      customColorSwatchesAndNames: _activeWsColorSwatches(),
      width: 36,
      height: 36,
      borderRadius: 4,
      copyPasteBehavior: const ColorPickerCopyPasteBehavior(
        copyButton: false,
        pasteButton: false,
        longPressMenu: false,
      ),
    ).showPickerDialog(
      context,
      constraints: const BoxConstraints(
        minHeight: 480,
        minWidth: 320,
        maxWidth: 320,
      ),
    );
    return ok ? working : null;
  }

  /// Entry point invoked from the drawer tile's color dot. Validates
  /// [id], opens the picker against the workspace's current color,
  /// and applies the choice via [_setWorkspaceColor].
  Future<void> _changeWorkspaceColor(String id) async {
    if (!mounted) return;
    final ctx = _shellContext;
    if (ctx == null) return;
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i < 0) return;

    Color? picked;
    try {
      picked = await _pickColor(ctx, _workspaces[i].color);
    } catch (e, st) {
      _log.severe('Color picker dialog failed: $e\n$st');
      return;
    }
    if (picked == null || !mounted) return;

    // Re-validate in case the list shifted while the modal was up.
    final j = _workspaces.indexWhere((w) => w.id == id);
    if (j < 0) return;
    if (_workspaces[j].color.toARGB32() == picked.toARGB32()) return;
    setState(() => _workspaces[j].color = picked!);
  }

  /// Show a confirmation dialog before closing a workspace.
  /// Returns true if the user confirmed, false if they cancelled
  /// (Cancel button, Esc, or tap outside the barrier).
  ///
  /// [isLast] adds a clarifying note when this is the only
  /// workspace — closing it will trigger [_newWorkspace] to spin
  /// up a fresh empty one, which is non-obvious from the bare
  /// "Close ...?" prompt.
  Future<bool> _confirmClose(
    BuildContext context,
    String name, {
    required bool isLast,
  }) async {
    final palette = context.palette;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.dialogSurface,
        title: const Text('Close workspace?'),
        content: Text(
          isLast
              ? "Close '$name'? A new empty workspace will be created in its place."
              : "Close '$name'?",
        ),
        actions: [
          // Both buttons are deliberately equal-weight TextButtons:
          // no button "wins" by static styling, so the *focused*
          // button is the only thing drawing the eye. autofocus on
          // Cancel makes Enter / Space dismiss safely by default;
          // its bright accent focus wash (from the global
          // textButtonTheme override) makes the active choice
          // unmistakable. The destructive Close keeps the palette's
          // pink accent text so it stays identifiable as destructive
          // without being loud in its default state.
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: palette.accentPink,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Close the workspace at [index], but only after the user
  /// confirms via [_confirmClose]. Both the drawer's close button
  /// and the `Ctrl+Shift+W` keyboard shortcut flow through here so
  /// neither can bypass the prompt.
  ///
  /// Re-validates [index] after the dialog returns — the workspace
  /// list could have shifted while the dialog was up (e.g. another
  /// shortcut fired). The dialog uses the cached [_shellContext]
  /// captured in [build].
  Future<void> _closeWorkspace(int index) async {
    if (index < 0 || index >= _workspaces.length) return;
    final ctx = _shellContext;
    if (ctx == null || !mounted) return;
    final ws = _workspaces[index];
    final isLast = _workspaces.length == 1;

    bool confirmed;
    try {
      confirmed = await _confirmClose(ctx, ws.name, isLast: isLast);
    } catch (e, st) {
      _log.severe('Close confirmation dialog failed: $e\n$st');
      return;
    }
    if (!confirmed || !mounted) return;

    // Re-validate in case the list shifted while the dialog was open.
    if (index < 0 || index >= _workspaces.length) return;

    if (_workspaces.length <= 1) {
      _workspaces.removeAt(index);
      _newWorkspace();
      return;
    }
    _workspaces.removeAt(index);
    _currentIndex = _currentIndex.clamp(0, _workspaces.length - 1);
    setState(() {});
    _updateWindowTitle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeWorkspace?.key.currentState?.focusCurrentPane();
    });
  }

  void _selectWorkspace(int index) {
    if (index < 0 || index >= _workspaces.length) return;
    if (index == _currentIndex) return;
    _currentIndex = index;
    setState(() {});
    _updateWindowTitle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeWorkspace?.key.currentState?.focusCurrentPane();
    });
  }

  /// Reorder a workspace in the list. Called by [_WorkspaceDrawer]
  /// when a tile is dropped on another tile (or on the end-of-list
  /// zone).
  ///
  /// Index semantics follow Flutter's [ReorderableListView]:
  /// [oldIndex] and [newIndex] are positions in `_workspaces`
  /// BEFORE the move. If [newIndex] > [oldIndex], the caller passed
  /// the "after" position; we subtract 1 to get the real
  /// post-removal index.
  ///
  /// After the move we update `_currentIndex` so the **active
  /// workspace stays selected** — if it was moved, the new index
  /// follows it; if other workspaces crossed the active one's
  /// position, the index shifts accordingly.
  void _reorderWorkspace(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _workspaces.length) return;
    if (newIndex < 0 || newIndex > _workspaces.length) return;
    if (oldIndex == newIndex) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
      if (oldIndex == newIndex) return;
    }

    setState(() {
      final ws = _workspaces.removeAt(oldIndex);
      _workspaces.insert(newIndex, ws);

      // Keep the active workspace selected across the move.
      if (_currentIndex == oldIndex) {
        // The active one was the one moved.
        _currentIndex = newIndex;
      } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
        // A workspace above the active one was moved past it.
        _currentIndex -= 1;
      } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
        // A workspace below the active one was moved above it.
        _currentIndex += 1;
      }
    });
    _updateWindowTitle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeWorkspace?.key.currentState?.focusCurrentPane();
    });
  }

  /// Reorder by workspace ID — the drag/drop payload carries only
  /// the ID (not the index), so the drop side resolves the source
  /// index here at accept time. [targetIndex] is the position of
  /// the drop target in `_workspaces` BEFORE the move; [after] is
  /// true if the drop landed on the bottom half of that target
  /// (insert after it) vs. the top half (insert before).
  void _reorderWorkspaceById(
    String sourceWorkspaceId,
    int targetIndex,
    bool after,
  ) {
    final oldIndex =
        _workspaces.indexWhere((w) => w.id == sourceWorkspaceId);
    if (oldIndex < 0) return;
    if (targetIndex < 0 || targetIndex >= _workspaces.length) return;
    if (oldIndex == targetIndex) {
      // Dropped on itself: only a no-op if we didn't toggle the
      // half — which never happens because we always drop on a
      // different tile or the end zone.
      return;
    }

    // Convert "insert before/after targetIndex" to a single
    // target position, then delegate to [_reorderWorkspace] which
    // applies the Flutter "newIndex > oldIndex ⇒ -1" convention.
    final desiredNew = after ? targetIndex + 1 : targetIndex;
    _reorderWorkspace(oldIndex, desiredNew);
  }

  void _nextWorkspace() {
    if (_workspaces.length <= 1) return;
    _selectWorkspace((_currentIndex + 1) % _workspaces.length);
  }

  void _previousWorkspace() {
    if (_workspaces.length <= 1) return;
    _selectWorkspace((_currentIndex - 1) % _workspaces.length);
  }

  void _toggleDrawer() {
    setState(() => _drawerCollapsed = !_drawerCollapsed);
  }

  // ── Window-level actions (fullscreen, quit) ───────────────────────

  /// Toggle the native window's fullscreen state via `window_manager`.
  /// Reads the current state first so we don't double-set on macOS
  /// (where `setFullScreen(true)` when already true is a no-op but
  /// still incurs a platform-channel round-trip).
  Future<void> _toggleFullscreen() async {
    try {
      final current = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!current);
    } catch (e, st) {
      _log.warning('windowManager fullscreen toggle failed: $e\n$st');
    }
  }

  /// Quit the app by sending the native window-close signal.
  /// `window_manager` will fire `AppLifecycleState.detached`, which the
  /// existing lifecycle observer in `didChangeAppLifecycleState`
  /// already handles via `exit(0)`. If the user has enabled
  /// `appearance.confirmOnExit` (the default), we show a confirmation
  /// dialog first; otherwise we close directly.
  Future<void> _quit() async {
    await _confirmExit(reason: 'quit');
  }

  /// Window-close interception — fires whenever the OS asks the
  /// window to close (× button, Alt+F4, OS shutdown). We check the
  /// `appearance.confirmOnExit` setting; if confirmation is enabled,
  /// show the dialog; otherwise call `destroy()` to force the close
  /// (the default `close()` is a no-op when `setPreventClose(true)`
  /// is in effect).
  @override
  void onWindowClose() async {
    await _confirmExit(reason: 'close');
  }

  /// Shared exit-confirmation logic used by both the keyboard
  /// shortcut path (`Ctrl+Shift+Q` → `_quit`) and the OS close
  /// path (`onWindowClose`). Reads `appearance.confirmOnExit` at
  /// invoke time, so a runtime setting change takes effect on the
  /// next quit attempt without any extra wiring.
  ///
  /// On confirm: `windowManager.destroy()` is a force-close that
  /// bypasses `setPreventClose(true)`, then the lifecycle observer
  /// picks up `AppLifecycleState.detached` and runs `exit(0)`.
  /// On cancel: do nothing — the window stays open.
  Future<void> _confirmExit({required String reason}) async {
    final catalog = SettingsRuntime.instance.catalog;
    final confirmEnabled = SettingsRuntime.instance.store
        .get<bool>(catalog.general.confirmOnExit);

    // If the user disabled confirmation in settings, just close.
    if (!confirmEnabled) {
      _forceClose();
      return;
    }

    final ctx = _shellContext;
    if (ctx == null || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    final palette = ctx.palette;
    final confirmed = await showDialog<bool>(
      context: ctx,
      barrierDismissible: true,
      builder: (dctx) => AlertDialog(
        backgroundColor: palette.dialogSurface,
        title: Text('Exit $kAppName?'),
        content: const Text(
          'All workspaces and shell sessions will be terminated.',
        ),
        actions: [
          // Same rule as the "Close workspace?" dialog: both buttons
          // are equal-weight TextButtons, so the focus wash from the
          // global textButtonTheme override is the *only* thing that
          // distinguishes "active" from "default". Cancel is
          // autofocused so Enter / Space dismisses safely.
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: palette.accentPink,
            ),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    // Null result means barrier-dismiss / Esc — treat as cancel.
    if (confirmed != true) return;
    _log.info('exit confirmed (reason=$reason); destroying window');
    _forceClose();
    // Tell the user the dialog will stop appearing — only after the
    // first time they hit the toggle (handled in the settings UI).
    messenger?.clearSnackBars();
  }

  /// Bypass `setPreventClose(true)` and actually destroy the window.
  /// After this, `window_manager` fires `AppLifecycleState.detached`,
  /// and the lifecycle observer's `exit(0)` finally terminates the
  /// process.
  void _forceClose() {
    try {
      windowManager.destroy();
    } catch (e, st) {
      _log.warning('windowManager.destroy failed: $e\n$st');
    }
    // Hard-kill immediately rather than waiting for the detached
    // lifecycle event — that's where the perceived close lag was
    // coming from (Win32 teardown + isolate drain before exit).
    exit(0);
  }

  /// Show a transient "feature coming soon" snackbar. Wired to the
  /// reserved bindings (search, vi mode) by `AppShellBindings.build`.
  /// Captured `ScaffoldMessengerState` avoids the `ScaffoldMessenger.of`
  /// lookup from inside a closure that may outlive the [BuildContext].
  void _showReservedHint(String message) {
    final messenger = _shellMessenger;
    if (messenger == null) return;
    showReservedHint(messenger, message);
  }

  @override
  void dispose() {
    _uninstallEarlyKeyHandler();
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _updateController.dispose();
    _updateModel.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────

  /// Cached [ScaffoldMessengerState], captured on each build. Used by
  /// the reserved-shortcut snackbar so the closure doesn't have to
  /// re-look-up the messenger every time (and so it keeps working if
  /// the build context is stale).
  ScaffoldMessengerState? _shellMessenger;

  @override
  Widget build(BuildContext context) {
    // First-frame placeholder while the off-isolate shell probe
    // resolves (see [_bootstrapAsync]). Without this the workspace
    // chrome would try to render with `_shells == null` and crash.
    if (_shells == null) {
      return MaterialApp(
        theme: buildAppTheme(palette: _activePalette()),
        home: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    _shellContext = context;
    _shellMessenger = ScaffoldMessenger.maybeOf(context);
    // Rebuild the merged binding map each build so the closures
    // re-capture the latest `_currentIndex` / workspace list / etc.
    // The early-key handler reads this field directly, so it always
    // sees the freshest dispatch table. We pass `context` so the
    // `openSettings` closure can capture it by value (rather than
    // reading `_shellContext` later and risking a stale context).
    _mergedShortcuts = _buildMergedShortcuts(context);
    return Scaffold(
      body: Focus(
        autofocus: true,
        child: Row(
          children: [
            // ── Workspace drawer ───────────────────────────────
            _WorkspaceDrawer(
              workspaces: _workspaces,
              currentIndex: _currentIndex,
              collapsed: _drawerCollapsed,
              onSelect: _selectWorkspace,
              onClose: _closeWorkspace,
              onRename: _renameWorkspace,
              onColorChange: _changeWorkspaceColor,
              onNew: _newWorkspace,
              onToggle: _toggleDrawer,
              onAcceptReorder: _reorderWorkspaceById,
              updateModel: _updateModel,
              updateController: _updateController,
            ),
            // ── Active workspace content ──────────────────────
            Expanded(
              child: IndexedStack(
                index: _currentIndex.clamp(0, _workspaces.length - 1),
                children: [
                  for (var i = 0; i < _workspaces.length; i++)
                    TerminalWorkspace(
                      key: _workspaces[i].key,
                      // Gate settings/theme setState on the focused
                      // workspace so an offstage one doesn't pay an
                      // O(M*K) rebuild on every setting change. The
                      // offstage workspace still captures the new
                      // value internally and re-applies on focus
                      // (see TerminalWorkspaceState.didUpdateWidget).
                      isFocused: i == _currentIndex,
                      name: _workspaces[i].name,
                      color: _workspaces[i].color,
                      availableShells: _shells ?? const <ShellProfile>[],
                      onEmpty: () => _closeWorkspace(_currentIndex),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Collapsible workspace drawer ─────────────────────────────────────

class _WorkspaceDrawer extends StatelessWidget {
  final List<_WorkspaceEntry> workspaces;
  final int currentIndex;
  final bool collapsed;
  final void Function(int) onSelect;
  final void Function(int) onClose;

  /// Called when the user double-clicks the workspace name and
  /// commits a non-empty, trimmed new name.
  final void Function(String id, String newName) onRename;

  /// Called when the user clicks the color indicator dot on a tile.
  /// The parent shows the color-picker dialog and applies the
  /// chosen color to the workspace identified by [id].
  final void Function(String id) onColorChange;

  final VoidCallback onNew;
  final VoidCallback onToggle;

  /// Called when a tile is dropped on another tile or onto the
  /// end-of-list zone. [sourceWorkspaceId] identifies the dragged
  /// tile; [_AppShellState] resolves its current index. [targetIndex]
  /// is the index of the drop target in [workspaces] BEFORE the
  /// move; [after] is true if the drop landed on the bottom half of
  /// the target (insert after it) vs. the top half (insert before).
  final void Function(
    String sourceWorkspaceId,
    int targetIndex,
    bool after,
  ) onAcceptReorder;

  final UpdateStateModel updateModel;
  final UpdateController updateController;

  const _WorkspaceDrawer({
    required this.workspaces,
    required this.currentIndex,
    required this.collapsed,
    required this.onSelect,
    required this.onClose,
    required this.onRename,
    required this.onColorChange,
    required this.onNew,
    required this.onToggle,
    required this.onAcceptReorder,
    required this.updateModel,
    required this.updateController,
  });

  static const double _expandedWidth = 200;
  static const double _collapsedWidth = 44;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      width: collapsed ? _collapsedWidth : _expandedWidth,
      color: palette.drawerSurface,
      child: Column(
        children: [
          // Full-width toggle button (collapsed → chevron_right,
          // expanded → chevron_left). The chevron is centered
          // horizontally; the entire strip is the click target so
          // the mouse lands on it reliably even near the edges,
          // and the brand mark from the old layout is gone.
          Container(
            height: collapsed ? 32 : 40,
            color: Colors.transparent,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggle,
                child: Tooltip(
                  message: collapsed
                      ? 'Expand (${describe(LogicalKeyboardKey.keyB, shift: true)})'
                      : 'Collapse (${describe(LogicalKeyboardKey.keyB, shift: true)})',
                  child: Center(
                    child: Icon(
                      collapsed
                          ? Icons.chevron_right
                          : Icons.chevron_left,
                      size: 18,
                      color: palette.brightness == Brightness.dark
                          ? palette.textMuted
                          : palette.textBody,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Workspace list.
          Expanded(
            child: collapsed
                // Collapsed mode: narrow icon strip — too cramped for
                // drag affordance, so no reorder.
                ? ListView.builder(
                    itemCount: workspaces.length,
                    itemBuilder: (context, index) {
                      final ws = workspaces[index];
                      return _CollapsedWorkspaceTile(
                        name: ws.name,
                        color: ws.color,
                        isActive: index == currentIndex,
                        onTap: () => onSelect(index),
                      );
                    },
                  )
                // Expanded mode: draggable tiles + trailing end zone.
                : _DraggableWorkspaceList(
                    workspaces: workspaces,
                    currentIndex: currentIndex,
                    onSelect: onSelect,
                    onClose: onClose,
                    onRename: onRename,
                    onColorChange: onColorChange,
                    onAccept: onAcceptReorder,
                  ),
          ),
          // New workspace button at the bottom.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onNew,
              child: Tooltip(
                message: 'New Workspace (${describe(LogicalKeyboardKey.keyN, shift: true)})',
                child: Container(
                  height: 36,
                  margin: const EdgeInsets.fromLTRB(4, 4, 4, 2),
                  decoration: BoxDecoration(
                    color: palette.surface2,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add,
                          size: 16,
                          color: palette.brightness == Brightness.dark
                              ? palette.textMuted
                              : palette.textBody),
                      if (!collapsed) ...[
                        const SizedBox(width: 6),
                        Text(
                          'New',
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Update pill above the Settings button. Renders as an
          // urgent badge when there's a check in flight, a detected
          // update, or a probe error; otherwise renders a subdued
          // "Octodo · 1.0.0+1" row so the same dialog stays
          // reachable as an About panel.
          UpdatePill(
            model: updateModel,
            controller: updateController,
            collapsed: collapsed,
            alwaysShow: true,
          ),
          // Settings button beneath the New Workspace button.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => showSettingsDialog(context),
              child: Tooltip(
                message: 'Settings',
                child: Container(
                  height: 28,
                  margin: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: palette.rowSurface,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.settings,
                          size: 14,
                          color: palette.brightness == Brightness.dark
                              ? palette.textMuted
                              : palette.textBody),
                      if (!collapsed) ...[
                        const SizedBox(width: 6),
                        Text(
                          'Settings',
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Workspace drawer tile (expanded mode). Shows a colored left bar,
/// a color dot, the workspace name (double-click to rename), and a
/// close button that's only revealed on hover or when this workspace
/// is active — matches the per-pane tab-chip hover-reveal pattern
/// at `lib/src/terminal/pane_tree.dart` `_ChipVisual`.
class _ExpandedWorkspaceTile extends StatefulWidget {
  final String name;
  final Color color;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final void Function(String newName) onRename;

  /// Click on the color indicator dot. The parent shows the color
  /// picker dialog and applies the chosen color.
  final VoidCallback onColorChange;

  const _ExpandedWorkspaceTile({
    required this.name,
    required this.color,
    required this.isActive,
    required this.onTap,
    required this.onClose,
    required this.onRename,
    required this.onColorChange,
  });

  @override
  State<_ExpandedWorkspaceTile> createState() => _ExpandedWorkspaceTileState();
}

class _ExpandedWorkspaceTileState extends State<_ExpandedWorkspaceTile> {
  static const _maxNameLength = 64;

  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _isEditing = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.name);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _ExpandedWorkspaceTile old) {
    super.didUpdateWidget(old);
    if (!_isEditing && old.name != widget.name) {
      _controller.text = widget.name;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    if (_isEditing) return;
    setState(() {
      _isEditing = true;
      _controller.text = widget.name;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.name.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _commitEdit() {
    if (!_isEditing) return;
    final newName = _controller.text.trim();
    setState(() => _isEditing = false);
    if (newName.isNotEmpty && newName != widget.name) {
      widget.onRename(newName);
    }
  }

  void _cancelEdit() {
    if (!_isEditing) return;
    setState(() {
      _isEditing = false;
      _controller.text = widget.name;
    });
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isActive;
    final showClose = isActive || _hovered;
    final palette = context.palette;
    // Light palettes define textMuted/textOverlay as very pale colors
    // (e.g. Latte textMuted #8C8FA1 on drawerSurface #E2E5EC ≈ 2.4:1
    // contrast — below WCAG AA). They read fine on dark surfaces but
    // the inactive tile text and close-X icon nearly disappear on the
    // light drawer background. Boost to textBody/textSecondary in
    // light mode only; dark stays as-is so the existing hierarchy is
    // preserved.
    final isDark = palette.brightness == Brightness.dark;
    final inactiveText = isDark ? palette.textMuted : palette.textBody;
    final subtleText = isDark ? palette.textOverlay : palette.textSecondary;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          padding:
              const EdgeInsets.only(left: 10, right: 4, top: 6, bottom: 6),
          decoration: BoxDecoration(
            // Three-state background:
            //   * active  → the workspace's own color at 15% (the
            //               "selected" cue, used everywhere in the
            //               drawer chrome).
            //   * hover   → a faint accentBlue tint. Subtler than the
            //               active tint so the active state always
            //               wins, but visible enough to advertise
            //               that the row is interactive. Skipped when
            //               the tile is already active — that state
            //               has its own dedicated tint and border.
            //   * rest    → transparent so the drawer's surface
            //               shows through.
            color: isActive
                ? widget.color.withValues(alpha: 0.15)
                : (_hovered
                    ? palette.accentBlue.withValues(alpha: 0.10)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
            border: Border(
              left: BorderSide(
                color: isActive ? widget.color : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: widget.onColorChange,
                  child: Tooltip(
                    message: 'Change color',
                    waitDuration: Duration.zero,
                    child: Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _isEditing ? null : _startEditing,
                  child: _isEditing
                      ? Focus(
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                event.logicalKey ==
                                    LogicalKeyboardKey.escape) {
                              _cancelEdit();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            onSubmitted: (_) => _commitEdit(),
                            onEditingComplete: _commitEdit,
                            onTapOutside: (_) {
                              if (_isEditing) _commitEdit();
                            },
                            style: TextStyle(
                              color: isActive
                                  ? palette.textPrimary
                                  : inactiveText,
                              fontSize: 13,
                              fontWeight: isActive
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                            ),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              hintText: 'Workspace',
                              counterText: '',
                              hintStyle: TextStyle(
                                color: subtleText,
                                fontSize: 13,
                              ),
                            ),
                            maxLength: _maxNameLength,
                            cursorColor: palette.accentBlue,
                            textInputAction: TextInputAction.done,
                          ),
                        )
                      : Text(
                          widget.name,
                          style: TextStyle(
                            color: isActive
                                ? palette.textPrimary
                                : inactiveText,
                            fontSize: 13,
                            fontWeight: isActive
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                ),
              ),
              AnimatedOpacity(
                opacity: showClose ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 120),
                child: IgnorePointer(
                  ignoring: !showClose,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onClose,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: subtleText,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Drag-and-drop reorder for the expanded workspace list ────────────
//
// Architecture mirrors the per-pane tab drag/drop in pane_tree.dart:
//   * Each tile is a [LongPressDraggable] (so a quick click still
//     selects the workspace) wrapped in a [DragTarget] (so other
//     tiles can be dropped onto either the top or bottom half).
//   * Pointer Y relative to the tile's centerline decides
//     before/after.
//   * A trailing [_WorkspaceEndDropZone] below the list handles
//     "drop past the end" (append to the end of the list).
//   * Only available in the expanded drawer (collapsed mode is
//     too narrow for a usable drag affordance).
//
// Reorder resolution: the drag payload carries only the source
// workspace ID. [_AppShellState._reorderWorkspaceById] looks up the
// current index of that ID in `_workspaces` at accept time, so
// reorder is robust to concurrent list mutations.

class _DraggableWorkspaceList extends StatelessWidget {
  final List<_WorkspaceEntry> workspaces;
  final int currentIndex;
  final void Function(int) onSelect;
  final void Function(int) onClose;

  /// Called when the user double-clicks the workspace name and
  /// commits a non-empty, trimmed new name. [id] identifies the
  /// renamed workspace so the parent can look it up by ID without
  /// trusting captured indices.
  final void Function(String id, String newName) onRename;

  /// Called when the user clicks the color indicator dot. The
  /// parent shows the color-picker dialog and applies the chosen
  /// color to the workspace identified by [id].
  final void Function(String id) onColorChange;

  /// Called when a tile is dropped on another tile (or the end
  /// zone). [sourceWorkspaceId] identifies the dragged tile; the
  /// parent resolves the current source index by ID. [targetIndex]
  /// is the position in `workspaces` BEFORE the move (Flutter's
  /// [ReorderableListView] convention). [after] tells whether the
  /// drop was on the bottom half of the target tile (vs top half).
  final void Function(
    String sourceWorkspaceId,
    int targetIndex,
    bool after,
  ) onAccept;

  const _DraggableWorkspaceList({
    required this.workspaces,
    required this.currentIndex,
    required this.onSelect,
    required this.onClose,
    required this.onRename,
    required this.onColorChange,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      physics: const ClampingScrollPhysics(),
      children: [
        for (var i = 0; i < workspaces.length; i++)
          _DraggableWorkspaceTile(
            key: ValueKey('ws-tile-${workspaces[i].id}'),
            workspace: workspaces[i],
            index: i,
            isActive: i == currentIndex,
            onTap: () => onSelect(i),
            onClose: () => onClose(i),
            onRename: onRename,
            onColorChange: onColorChange,
            onAccept: onAccept,
          ),
        _WorkspaceEndDropZone(
          height: 16,
          onAccept: (sourceId) {
            // Append to end. targetIndex = workspaces.length; the
            // adjust-down in _AppShellState._reorderWorkspaceById
            // only kicks in if the source was already past that
            // point (it can't be — max source index is length-1).
            onAccept(sourceId, workspaces.length, false);
          },
        ),
      ],
    );
  }
}

class _DraggableWorkspaceTile extends StatefulWidget {
  final _WorkspaceEntry workspace;
  final int index;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final void Function(String id, String newName) onRename;
  final void Function(String id) onColorChange;
  final void Function(
    String sourceWorkspaceId,
    int targetIndex,
    bool after,
  ) onAccept;

  const _DraggableWorkspaceTile({
    super.key,
    required this.workspace,
    required this.index,
    required this.isActive,
    required this.onTap,
    required this.onClose,
    required this.onRename,
    required this.onColorChange,
    required this.onAccept,
  });

  @override
  State<_DraggableWorkspaceTile> createState() =>
      _DraggableWorkspaceTileState();
}

class _DraggableWorkspaceTileState extends State<_DraggableWorkspaceTile> {
  /// True while this tile is the drag origin.
  bool _localDragActive = false;
  /// True if the current hover means "insert after me" (vs. before).
  bool _insertAfter = false;

  void _setLocalDragActive(bool v) {
    if (_localDragActive == v) return;
    setState(() => _localDragActive = v);
  }

  void _setHoverAfter(bool after) {
    if (_insertAfter == after) return;
    setState(() => _insertAfter = after);
  }

  /// Resolve a global pointer offset to "insert before" or "insert
  /// after" this tile, based on the pointer's Y position relative to
  /// the tile's centerline.
  bool _resolveAfter(Offset globalOffset) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return true;
    final local = renderObject.globalToLocal(globalOffset);
    return local.dy > renderObject.size.height / 2;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.workspace;
    final palette = context.palette;
    final tile = _ExpandedWorkspaceTile(
      name: w.name,
      color: w.color,
      isActive: widget.isActive,
      onTap: widget.onTap,
      onClose: widget.onClose,
      onRename: (newName) => widget.onRename(w.id, newName),
      onColorChange: () => widget.onColorChange(w.id),
    );

    final placeholder = Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      height: 32,
      decoration: BoxDecoration(
        color: w.color.withValues(alpha: 0.08),
        border: Border.all(
          color: w.color.withValues(alpha: 0.4),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
    );

    final feedback = Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _WorkspaceDrawer._expandedWidth - 8,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding:
              const EdgeInsets.only(left: 10, right: 4, top: 6, bottom: 6),
          decoration: BoxDecoration(
            color: palette.surface2,
            borderRadius: BorderRadius.circular(4),
            border: Border(
              left: BorderSide(color: w.color, width: 3),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: w.color,
                ),
              ),
              Expanded(
                child: Text(
                  w.name,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close,
                    size: 14, color: palette.textOverlay),
              ),
            ],
          ),
        ),
      ),
    );

    return LongPressDraggable<_WorkspaceDragData>(
      data: _WorkspaceDragData(w.id),
      delay: const Duration(milliseconds: 250),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: placeholder,
      onDragStarted: () => _setLocalDragActive(true),
      onDraggableCanceled: (_, _) => _setLocalDragActive(false),
      onDragCompleted: () => _setLocalDragActive(false),
      child: DragTarget<_WorkspaceDragData>(
        onWillAcceptWithDetails: (details) =>
            details.data.workspaceId != w.id,
        onMove: (details) => _setHoverAfter(_resolveAfter(details.offset)),
        onLeave: (_) => _setHoverAfter(false),
        onAcceptWithDetails: (details) {
          final after = _resolveAfter(details.offset);
          _setHoverAfter(after);
          widget.onAccept(
            details.data.workspaceId,
            widget.index,
            after,
          );
        },
        builder: (context, candidate, rejected) {
          final showAbove = _insertAfter == false && _localDragActive;
          final showBelow = _insertAfter && _localDragActive;
          final palette = context.palette;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              tile,
              if (showAbove) _InsertionLineIndicator(above: true, color: palette.accentBlue),
              if (showBelow) _InsertionLineIndicator(above: false, color: palette.accentBlue),
              if (candidate.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: palette.accentBlue.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: palette.accentBlue.withValues(alpha: 0.35),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A prominent full-width insertion line shown above or below a
/// workspace tile during drag. The line is 3px thick, has a soft
/// glow tinted with [color] (the palette's accent blue by default),
/// and small "handle" dots at each end so users can see at a glance
/// where the dragged workspace will land.
class _InsertionLineIndicator extends StatelessWidget {
  final bool above;
  final Color color;
  const _InsertionLineIndicator({required this.above, required this.color});

  @override
  Widget build(BuildContext context) {
    // The line itself: full drawer width (no horizontal inset),
    // 3px tall, with a soft outer glow. Two 4px handle dots at
    // each end give a clear "this is a drag target" affordance.
    final line = Positioned(
      left: 0,
      right: 0,
      top: above ? -1 : null,
      bottom: above ? null : -1,
      child: SizedBox(
        height: 3,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Glow halo (slightly larger, blurred).
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.35),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.7),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Solid line on top.
            Positioned.fill(
              child: ColoredBox(color: color),
            ),
            // Left handle dot.
            Positioned(
              left: -1,
              top: -1,
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            // Right handle dot.
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return line;
  }
}

/// Trailing drop zone below the workspace list. Accepts drops from
/// any tile to append the dragged workspace to the end of the list.
/// Shows a prominent insertion line at the bottom of the list while
/// a drag is in flight (matches the per-tile indicator style).
class _WorkspaceEndDropZone extends StatelessWidget {
  final double height;
  final void Function(String sourceWorkspaceId) onAccept;

  const _WorkspaceEndDropZone({
    required this.height,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DragTarget<_WorkspaceDragData>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onAccept(details.data.workspaceId),
      builder: (context, candidate, rejected) {
        return SizedBox(
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (candidate.isNotEmpty)
                // Tint the whole zone while a drag is over it.
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: palette.accentBlue
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              // Always-visible insertion line at the bottom of the
              // list (only shown when a drag is in flight, since
              // the [DragTarget.candidate] is the source of truth).
              if (candidate.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _InsertionLineIndicator(
                      above: false, color: palette.accentBlue),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CollapsedWorkspaceTile extends StatefulWidget {
  final String name;
  final Color color;
  final bool isActive;
  final VoidCallback onTap;

  const _CollapsedWorkspaceTile({
    required this.name,
    required this.color,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_CollapsedWorkspaceTile> createState() =>
      _CollapsedWorkspaceTileState();
}

class _CollapsedWorkspaceTileState extends State<_CollapsedWorkspaceTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: widget.name,
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 300),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 36,
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              // Same three-state background as the expanded tile:
              // active → workspace color tint, hover → accentBlue
              // hint, rest → transparent. The collapsed tile is
              // icon-only so the hover tint does most of the
              // "this is interactive" work (no close button to
              // reveal).
              color: widget.isActive
                  ? widget.color.withValues(alpha: 0.20)
                  : (_hovered
                      ? palette.accentBlue.withValues(alpha: 0.10)
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(4),
              border: Border(
                left: BorderSide(
                  color: widget.isActive ? widget.color : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Center(
              child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.isActive
                    ? widget.color
                    : widget.color.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}
