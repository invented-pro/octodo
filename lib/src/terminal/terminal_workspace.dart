import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../settings/settings_catalog.dart';
import '../settings/settings_runtime.dart';
import '../theme/palettes.dart';
import '../log.dart';
import '../shortcuts/app_shortcuts.dart';
import 'pane_tree.dart';
import 'shell_cwd.dart';
import 'shell_profiles.dart';
import 'terminal_settings_scope.dart';
import 'terminal_view.dart';

/// The user's home directory (%USERPROFILE%).
String get userHome {
  final env = Platform.environment;
  return env['USERPROFILE'] ?? env['HOME'] ?? '';
}

/// Return value of [TerminalWorkspaceState._applyCloseSurface]: the
/// new pane tree root + the pane container that should receive focus.
class _CloseResult {
  final PaneNode tree;
  final PaneContainer? focused;
  _CloseResult(this.tree, this.focused);
}

/// Public shim around [TerminalWorkspaceState._applyCloseSurface] for
/// unit tests in `pane_tree_test.dart`. The real workspace wires this
/// into a `setState` + postFrame focus request; tests just need the
/// pure tree-mutation result.
@visibleForTesting
class CloseSurfaceResult {
  final PaneNode tree;
  final PaneContainer? focused;
  CloseSurfaceResult._(this.tree, this.focused);
}

@visibleForTesting
CloseSurfaceResult? applyCloseSurfaceForTest(
  PaneSplit tree,
  PaneContainer owner,
  Surface surface,
) {
  final r = TerminalWorkspaceState._applyCloseSurface(tree, owner, surface);
  if (r == null) return null;
  return CloseSurfaceResult._(r.tree, r.focused);
}

/// Return value of [TerminalWorkspaceState._applyDropToSplitEdge]: the
/// new pane tree root + the new pane container that should receive focus.
class _DropResult {
  final PaneNode tree;
  final PaneContainer focused;
  _DropResult(this.tree, this.focused);
}

/// Public shim around [TerminalWorkspaceState._applyDropToSplitEdge] for
/// unit tests in `pane_tree_test.dart`. The real workspace wires this
/// into a `setState` + postFrame focus request; tests just need the
/// pure tree-mutation result.
@visibleForTesting
class DropToSplitEdgeResult {
  final PaneNode tree;
  final PaneContainer focused;
  DropToSplitEdgeResult._(this.tree, this.focused);
}

@visibleForTesting
DropToSplitEdgeResult? applyDropToSplitEdgeForTest({
  required PaneNode root,
  required PaneContainer fromContainer,
  required Surface surface,
  required PaneContainer target,
  required Axis direction,
  required bool isFirst,
}) {
  final r = TerminalWorkspaceState._applyDropToSplitEdge(
    root: root,
    fromContainer: fromContainer,
    surface: surface,
    target: target,
    direction: direction,
    isFirst: isFirst,
  );
  if (r == null) return null;
  return DropToSplitEdgeResult._(r.tree, r.focused);
}

final Logger _log = moduleLogger('terminal.terminal_workspace');

// ── Workspace widget ─────────────────────────────────────────────────

/// A single workspace — owns its own pane tree, surfaces (tabs), and
/// shell state.  Multiple instances can be composed in an app shell to
/// create a multi-workspace terminal app.
///
/// Each workspace has a single [PaneNode] tree (root may be a
/// [PaneContainer] or a [PaneSplit]).  Every [PaneContainer] leaf
/// owns a list of [Surface]s rendered as horizontal tabs over an
/// [IndexedStack] of [TerminalView]s.
///
/// Keyboard shortcuts (active when this workspace is focused):
///   See `lib/src/shortcuts/app_shortcuts.dart` for the full scheme.
///   This widget installs the workspace-level bindings via
///   [WorkspaceBindings.build] in its [build] method. Highlights:
///
///   Ctrl+Shift+T   — new tab in focused pane
///   Ctrl+Shift+K   — close focused tab
///   Ctrl+Tab       — next tab in focused pane
///   Ctrl+Shift+Tab — previous tab in focused pane
///   Ctrl+1..9      — jump to tab N in focused pane
///   Ctrl+Shift+D   — split focused pane right
///   Ctrl+Shift+E   — split focused pane down
///   Ctrl+Shift+arrows — focus pane in direction (Cmd+Shift+arrows on macOS)
///   Ctrl+Shift+M   — toggle maximize focused pane
class TerminalWorkspace extends StatefulWidget {
  final String name;
  final Color color;
  final List<ShellProfile> availableShells;
  final VoidCallback? onClose;
  final void Function(String name)? onNameChanged;
  final void Function(bool active)? onActiveChanged;

  /// Called when the user attempts to close the last surface in the
  /// last container — the action that would empty the workspace.
  /// The parent (e.g. AppShell) must show a workspace-close
  /// confirmation dialog and return the user's answer. The terminal
  /// tree is NOT torn down until this returns `true`; if the user
  /// cancels, the workspace is left intact. Required.
  ///
  /// Separated from [onEmpty] so the prompt can run BEFORE any
  /// state mutation: the previous design (tear down first, prompt
  /// after) left the workspace in a rootless state if the user
  /// cancelled, with no UI affordance to recover.
  final Future<bool> Function() confirmCloseWorkspace;

  /// Called AFTER the user has confirmed closing an empty workspace
  /// (i.e. after [confirmCloseWorkspace] returned `true` and the
  /// terminal tree has been disposed). The parent is expected to
  /// remove the workspace entry — no further user prompt. Required.
  final VoidCallback? onEmpty;

  /// Whether this workspace is the one currently displayed by the
  /// parent's [IndexedStack]. The settings/theme `setState` listeners
  /// gate on this flag so an offstage workspace doesn't pay an O(M*K)
  /// rebuild on every setting change — only the focused workspace
  /// does. Offstage workspaces still capture the new value internally
  /// and re-apply on focus (see `TerminalWorkspaceState.didUpdateWidget`).
  ///
  /// Defaults to `true` so existing call sites (tests, docs examples)
  /// behave as before. The AppShell always passes an explicit value.
  final bool isFocused;

  const TerminalWorkspace({
    super.key,
    this.name = 'Workspace',
    this.color = const Color(0xFF89B4FA),
    required this.availableShells,
    this.onClose,
    this.onNameChanged,
    this.onActiveChanged,
    required this.confirmCloseWorkspace,
    this.onEmpty,
    this.isFocused = true,
  });

  @override
  State<TerminalWorkspace> createState() => TerminalWorkspaceState();
}

class TerminalWorkspaceState extends State<TerminalWorkspace>
    with WidgetsBindingObserver {
  PaneNode? _rootPane;
  PaneContainer? _focusedContainer;
  int _defaultShellIndex = 0;

  /// Last-known cwd per shell type, keyed by `ShellProfile.shortName`.
  /// Updated whenever a Surface reports a new cwd via OSC 7 (for shells
  /// with reliable OSC 7 — `showCwdInTitle == true`). Consumed by
  /// [_makeSurface] so a new tab of the same shell starts where the last
  /// one left off. Session-scoped — not persisted to disk.
  final Map<String, String> _lastCwdByShell = {};

  /// Workspace-level "any tab drag in flight" signal. Owned here so
  /// every [PaneContainer] in the tree rebuilds its `_PaneDropOverlay`
  /// (and the tab bar's `_localDragActive`-derived feedback) the moment
  /// any tab drag starts or ends — including cross-pane drags where the
  /// source pane needs the destination pane to light up its drop
  /// targets immediately. Also gates the four `_EdgeSplitZone` overlays
  /// (their always-present translucent `DragTarget` `MetaData` would
  /// otherwise interfere with the terminal's cursor + text selection
  /// at the outer ~25% band on every side at rest).
  final ValueNotifier<bool> _isAnyTabDragActive = ValueNotifier(false);

  /// When true, only the [focusedContainer] is rendered full-window; the
  /// rest of the tree is hidden. The tree itself is never mutated by
  /// this flag — toggling it off restores the original layout as-is.
  bool _isMaximized = false;

  /// Live settings values (mirrored from the [SettingsRuntime]).
  /// They are re-resolved on init and reactively updated via the
  /// store's `watch` streams.
  late TerminalSettings _terminalSettings;

  /// Notifier that propagates settings/theme changes to descendant
  /// [TerminalView]s via a [TerminalSettingsScope]. The workspace no
  /// longer calls `setState` on a settings change — instead it
  /// updates this notifier's `.value`, which triggers
  /// `didChangeDependencies` on every listening [TerminalView] and
  /// calls `_engine.reconfigure(...)` directly. This skips the
  /// M-panes × K-tabs widget allocation + layout pass that the old
  /// `setState` cascade used to cost on every settings toggle.
  late TerminalSettingsNotifier _settingsNotifier;

  /// `true` when a settings/theme change arrived while we were
  /// offstage (so we skipped the notifier update to avoid the
  /// `didChangeDependencies` cascade across tabs the user can't see).
  /// On the next focus transition (`didUpdateWidget` with `isFocused`
  /// flipping false→true) we flush the deferred value with one
  /// notifier update.
  bool _settingsDirty = false;

  /// Subscriptions to settings hot-reload streams. Cancelled on
  /// [dispose] to prevent memory leaks.
  final List<StreamSubscription<dynamic>> _settingsSubs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // _initRootPane is async (it awaits the WSL `$HOME` query for
    // WSL surfaces); fire-and-forget from initState. The setState
    // inside it triggers a rebuild once the root pane is ready.
    unawaited(_initRootPane());
    _initSettings();
  }

  @override
  void didUpdateWidget(covariant TerminalWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If we were offstage when settings/theme last changed, push the
    // deferred value down now so the alacritty engines see the new
    // font / palette on the frame we become focused. Without this,
    // the offstage workspace would render with stale settings until
    // the user happens to switch away and back. Just nudge the
    // notifier — `didChangeDependencies` on the TerminalViews will
    // pick it up and call `_engine.reconfigure(...)`.
    if (!oldWidget.isFocused && widget.isFocused && _settingsDirty) {
      _settingsDirty = false;
      _settingsNotifier.value = _terminalSettings;
    }
  }

  /// Subscribe to every user-facing terminal setting and rebuild
  /// `_terminalSettings` on change. The workspace no longer calls
  /// `setState` on settings changes — instead it updates
  /// [_settingsNotifier], which propagates to every [TerminalView]
  /// via the [TerminalSettingsScope] inherited widget and triggers
  /// `didChangeDependencies` → `_engine.reconfigure(...)` directly,
  /// skipping the M-panes × K-tabs widget rebuild that used to cost
  /// on every settings toggle.
  ///
  /// For OFFSTAGE workspaces we still update the in-memory
  /// `_terminalSettings` (so the value isn't lost) but skip the
  /// notifier update to avoid the `didChangeDependencies` cascade
  /// across tabs the user can't see. `didUpdateWidget` flushes the
  /// deferred value when the workspace becomes focused again.
  void _initSettings() {
    final runtime = SettingsRuntime.instance;
    final catalog = runtime.catalog;
    final t = catalog.terminal;
    final palette = _resolvePalette(runtime);
    _terminalSettings = TerminalSettings(
      fontFamily: runtime.store.get<String>(t.fontFamily),
      fontSize: runtime.store.get<double>(t.fontSize),
      backgroundColor: palette.surface0,
      cursorStyle: runtime.store.get<CursorStyle>(t.cursorStyle),
      cursorColor: runtime.store.get<Color>(t.cursorColor),
      cursorBlink: runtime.store.get<bool>(t.cursorBlink),
      scrollbackLines: runtime.store.get<int>(t.scrollbackLines),
      copyOnSelect: runtime.store.get<bool>(t.copyOnSelect),
      bellMode: runtime.store.get<BellMode>(t.bellMode),
      linkClickModifier: runtime.store.get<LinkClickModifier>(
        t.linkClickModifier,
      ),
      notifyOnOsc9: runtime.store.get<bool>(t.notifyOnOsc9),
      terminalForeground: palette.terminalForeground,
      terminalSelection: palette.terminalSelection,
      terminalAnsiColors: palette.terminalAnsiColors,
    );
    _settingsNotifier = TerminalSettingsNotifier(_terminalSettings);

    /// Apply [next] to `_terminalSettings` and propagate via the
    /// notifier when this workspace is focused. Offstage: capture
    /// the value and mark dirty; flush on the next focus transition.
    void applyAndMaybeNotify(TerminalSettings Function(TerminalSettings) next) {
      if (!mounted) return;
      final updated = next(_terminalSettings);
      if (updated == _terminalSettings) return;
      _terminalSettings = updated;
      if (widget.isFocused) {
        // Setting `.value` on the notifier fires
        // `didChangeDependencies` on every descendant TerminalView,
        // which calls `_engine.reconfigure(...)` itself — no widget
        // rebuild, no layout, no paint cascade.
        _settingsNotifier.value = updated;
      } else {
        _settingsDirty = true;
      }
    }

    _settingsSubs.add(
      runtime.store.watch<String>(t.fontFamily).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(fontFamily: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<double>(t.fontSize).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(fontSize: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<CursorStyle>(t.cursorStyle).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(cursorStyle: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<Color>(t.cursorColor).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(cursorColor: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<bool>(t.cursorBlink).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(cursorBlink: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<int>(t.scrollbackLines).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(scrollbackLines: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<bool>(t.copyOnSelect).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(copyOnSelect: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<BellMode>(t.bellMode).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(bellMode: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<LinkClickModifier>(t.linkClickModifier).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(linkClickModifier: v));
      }),
    );
    _settingsSubs.add(
      runtime.store.watch<bool>(t.notifyOnOsc9).listen((v) {
        applyAndMaybeNotify((s) => s.copyWith(notifyOnOsc9: v));
      }),
    );

    // Theme (palette) change → swap terminal foreground, selection,
    // background, and the 16 ANSI colors from the new palette. The
    // background always tracks `palette.surface0` (the previous
    // `terminal.backgroundColor` user override was removed because
    // it defeated the "theme change retints the terminal" goal —
    // an explicit override always won over the palette).
    _settingsSubs.add(
      runtime.store.watch<String>(catalog.general.themeName).listen((_) {
        if (!mounted) return;
        final p = _resolvePalette(runtime);
        applyAndMaybeNotify(
          (s) => s.copyWith(
            backgroundColor: p.surface0,
            terminalForeground: p.terminalForeground,
            terminalSelection: p.terminalSelection,
            terminalAnsiColors: p.terminalAnsiColors,
          ),
        );
      }),
    );
  }

  /// Resolve the palette currently selected by the user. Cheap —
  /// `AppPalettes.byId` walks the registry's 9-entry list.
  static ThemePalette _resolvePalette(SettingsRuntime runtime) =>
      AppPalettes.byId(runtime.store.get(runtime.catalog.general.themeName));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusCurrentPane();
      });
    }
  }

  Future<void> _initRootPane() async {
    final root = PaneContainer();
    root.surfaces.add(await _makeSurface(_defaultShell, userHome));
    _rootPane = root;
    _focusedContainer = root;
    // Without setState the field assignment above doesn't trigger a
    // rebuild — the build keeps seeing `_rootPane == null` and
    // renders `SizedBox.shrink()`, leaving the pane black. The
    // commented-out line below was the original intent (see the
    // `unawaited(_initRootPane())` note in initState); it was
    // accidentally dropped, so users had to click the workspace
    // drawer to force an unrelated rebuild before the terminal would
    // appear. Wrap the assignments in setState so the first frame
    // after _makeSurface resolves re-renders with the real PaneLayout.
    _log.fine('_initRootPane complete; calling setState');
    if (mounted) {
      setState(() {});
      // Auto-focus the freshly-created surface now that it's mounted.
      //
      // Why here, not in AppShell._newWorkspace's postFrameCallback:
      // that callback fires immediately after the next frame, but
      // `_initRootPane` is still awaiting `_makeSurface` (which
      // awaits the WSL `$HOME` query — up to 1 s). At that point
      // `_focusedContainer` is still null and `focusCurrentPane`
      // silently no-ops; the new TerminalView then mounts without
      // its focus node ever being claimed, so the user has to click
      // before typing. By the time we reach this `await`, the
      // surface exists, the rebuild has run, and
      // `surface.focusNode` is attached — a `postFrameCallback`
      // guarantees we ask for focus after the rebuild flushes.
      //
      // Also covers the very first workspace on app startup
      // (where `TerminalView.autofocus` would fire too — redundant
      // but harmless).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusCurrentPane();
      });
    }
  }

  /// Public — called by the app shell when switching workspaces or
  /// resuming from background.
  void focusCurrentPane() {
    final surface = _focusedContainer?.focusedSurface;
    surface?.focusNode.requestFocus();
  }

  ShellProfile get _defaultShell {
    if (widget.availableShells.isEmpty) {
      // Defensive: a working host always detects at least one shell, but
      // a misconfigured box or a future platform with no detector yet
      // could surface an empty list here. Returning a synthesized profile
      // with an empty `program` lets flutter_alacritty fall back to
      // `$SHELL` (documented at `TerminalView._buildPtyLaunchArgs`,
      // lines 1014–1016, 1051) instead of throwing a RangeError on the
      // `[_defaultShellIndex]` access below. Once `detectShellsPosixFrom`
      // is in place the list should never be empty on a working macOS
      // install — this guard is purely a crash-backstop.
      return const ShellProfile(
        label: 'Shell',
        program: '',
        // Empty program triggers flutter_alacritty's $SHELL fallback (see
        // `TerminalView._buildPtyLaunchArgs`); with no args, that fallback
        // spawns the user's $SHELL as an interactive (not login) shell.
        // Interactive is the right call here because the fallback path
        // can't tell what OS we're on — login-shell semantics (-l) are
        // applied per-profile by `detectShellsPosixFrom` instead.
        args: [],
        icon: Icons.terminal,
        color: Colors.grey,
        shortName: 'shell',
        showCwdInTitle: true,
      );
    }
    return widget.availableShells[_defaultShellIndex];
  }

  /// Build a [Surface] for [profile], starting in [workingDirectory].
  /// The profile is carried so the tab bar can render the shell's
  /// icon + shortName as the fallback title before the shell sets its
  /// own via OSC.
  ///
  /// [workingDirectory] is always a Windows path. We translate it to
  /// the shell-native form so `Surface.initialCwd == currentCwd`
  /// holds when the user has not `cd`'d (and the `~` shortcut in
  /// the tab chip can fire). For WSL we instead query the distro's
  /// `$HOME` directly as a Linux path (e.g. `/home/<user>`) — bash's
  /// startup cwd IS the distro's `$HOME`, and OSC 7 emits the same
  /// Linux string, so the `~` shortcut fires. The translated mount
  /// path (`/mnt/c/Users/<user>`) does NOT match OSC 7's Linux form
  /// and is used only as the timeout/failure fallback. The query is
  /// awaited once per surface creation.
  ///
  /// When a workspace-remembered cwd exists for this shell type
  /// ([_lastCwdByShell]), the surface starts there instead:
  ///   - WSL: the `--cd` arg is overridden with the remembered Linux
  ///     path (the PTY `workingDirectory` is ignored by WSL when
  ///     `--cd` is present).
  ///   - Git Bash: the remembered MSYS path is reverse-translated to
  ///     a Windows path and set as [Surface.spawnCwd].
  ///   - Nushell: the remembered Windows path is passed through
  ///     unchanged as [Surface.spawnCwd].
  /// Only shells with reliable OSC 7 (`showCwdInTitle == true`)
  /// contribute to the remembered map, so this is a no-op for
  /// PowerShell / CMD.
  ///
  /// For bash-based shells with `showCwdInTitle == true` (WSL, Git Bash), a
  /// `PROMPT_COMMAND` that emits OSC 7 is injected via [Surface.env] (gated
  /// on [ShellProfile.needsPromptCommandForOsc7]). Most bash-based shells
  /// (Debian WSL, plain Git Bash) don't emit OSC 7 by default; the env var
  /// is picked up by bash unless the user's `.bashrc` sets its own
  /// `PROMPT_COMMAND` (which is the correct behaviour — oh-my-posh,
  /// starship, etc. emit OSC 7 themselves). For WSL the var is forwarded
  /// via `WSLENV`.
  ///
  /// Nushell (`nu.exe`) defaults `shell_integration.osc7` to `false` on
  /// Windows, and ConPTY additionally eats OSC 7 from `nu.exe` regardless
  /// of terminator. Cwd persistence instead works by parsing the cwd from
  /// Nushell's OSC 2 title (which ConPTY passes through reliably). See
  /// `TerminalView._extractCwdFromNuTitle`.
  Future<Surface> _makeSurface(
    ShellProfile profile,
    String workingDirectory,
  ) async {
    final remembered = _lastCwdByShell[profile.shortName];

    String spawnCwd = workingDirectory;
    List<String> args = profile.args;
    String? initialCwdOverride;
    String? homePath;
    final Map<String, String> env = {};

    // Resolve the home path (used by Surface._isAtHome) and, for WSL,
    // reuse the $HOME query for initialCwd to avoid a second call.
    if (profile.isWsl) {
      final wslHome = await _queryWslHome(profile);
      homePath = wslHome;
    } else {
      homePath = translateCwdForShell(
        cwd: workingDirectory,
        program: profile.program,
      );
    }

    if (remembered != null && profile.remembersCwd) {
      if (profile.isWsl) {
        args = _wslArgsWithCd(profile, remembered);
        initialCwdOverride = remembered;
      } else if (!Platform.isWindows) {
        // POSIX host: the remembered cwd came from this shell's own OSC 7
        // (zsh / bash / fish native paths) — it IS the spawn-cwd format
        // already. `reverseTranslateCwd` would return null (it only maps
        // WSL `/mnt/<drive>` and MSYS `/<drive>` shapes back to Windows
        // drive paths), silently dropping the persistence.
        spawnCwd = remembered;
      } else {
        final winPath = reverseTranslateCwd(
          cwd: remembered,
          program: profile.program,
        );
        if (winPath != null) {
          spawnCwd = winPath;
        }
      }
    }

    // Inject our self-contained OSC 7 PROMPT_COMMAND where the shell family
    // uses one (WSL, Git Bash, POSIX bash — see
    // `ShellProfile.needsPromptCommandForOsc7`). Stock POSIX bash emits no
    // OSC 7 on its own (hosts without /etc/profile.d/vte.sh, every macOS
    // install), so the injection is what makes the cwd-reporting channel
    // work there at all.
    final injectOsc7PromptCommand =
        profile.showCwdInTitle && profile.needsPromptCommandForOsc7;
    if (injectOsc7PromptCommand) {
      env['PROMPT_COMMAND'] = _osc7PromptCommand;
      if (profile.isWsl) {
        final existing = Platform.environment['WSLENV'] ?? '';
        env['WSLENV'] = existing.contains('PROMPT_COMMAND')
            ? existing
            : (existing.isEmpty
                  ? 'PROMPT_COMMAND/u'
                  : '$existing:PROMPT_COMMAND/u');
      }
    } else if (!Platform.isWindows &&
        Platform.environment.containsKey('PROMPT_COMMAND')) {
      // Suppress any inherited PROMPT_COMMAND on POSIX (macOS / Linux)
      // hosts BEFORE we hand the env to flutter_alacritty — but only for
      // shells we did NOT inject for above. flutter_alacritty's
      // `resolveShellSpec` (in flutter_alacritty's lib/pty/
      // flutter_pty_backend.dart) passes the *entire* `Platform.environment`
      // to the spawned shell, so any PROMPT_COMMAND set in the parent process
      // (e.g. by the terminal app that launched octodo, such as cmux) is
      // inherited verbatim. On POSIX hosts we don't want that — see below.
      //
      // Why suppress rather than pass through:
      //
      // 1. PROMPT_COMMAND is *session-level* state, not a system default.
      //    It refers to functions defined in the parent's interactive
      //    shell (e.g. `_cmux_prompt_command` defined by the cmux app's
      //    bash-integration). When octodo spawns a new bash, those
      //    function definitions do NOT survive the process boundary — env
      //    vars do, but bash functions don't. The result is a chain that
      //    bash executes on every prompt, hitting undefined names and
      //    printing `bash: command not found: _cmux_prompt_command` (or
      //    similar) on every prompt. This is what the user sees here.
      //    (When we DID inject above, our value replaces the inherited
      //    chain entirely — same cure, plus working OSC 7.)
      //
      // 2. The shells this branch still covers (zsh, fish, …) don't read
      //    PROMPT_COMMAND at all — they get their OSC 7 integration via
      //    the ZDOTDIR shim / `--init-command` injections below — so
      //    dropping the inherited value costs nothing and stops the
      //    broken-chain noise from leaking into any bash the user later
      //    launches inside the tab.
      //
      // 3. macOS Terminal.app, iTerm2, and Alacritty all do NOT inherit
      //    PROMPT_COMMAND from the parent process. Each spawned shell
      //    starts fresh, and the user's `.bashrc` / `.zshrc` (where
      //    `starship init bash` etc. correctly register their
      //    PROMPT_COMMAND contributors) is the single source of truth.
      //    We follow the same convention.
      //
      // On Windows, the injection above has already set PROMPT_COMMAND
      // for OSC 7 cwd reporting (the Windows code path needs it for WSL /
      // Git Bash), and this POSIX-only branch never runs there.
      //
      // Implementation: the `Env` map is merged on top of
      // `Platform.environment` by `resolveShellSpec`, so an empty-string
      // override is the only way to drop the inherited value without
      // changing the platform layer. (`flutter_pty`'s own whitelist-and-merge
      // would never carry PROMPT_COMMAND over, but `flutter_alacritty`'s
      // `resolveShellSpec` does — that's the seam we patch here.)
      env['PROMPT_COMMAND'] = '';
    }
    // Resync `SHELL` to the program we're actually about to launch. The
    // user's login shell (per `chsh` / `/etc/passwd`) is propagated through
    // the parent env, so `echo $SHELL` inside a tab reflects the LOGIN
    // shell of whoever launched octodo — not the shell currently running
    // in the tab. That's correct per POSIX convention but surprising in
    // practice: a user who picked zsh from the dropdown expects `echo
    // $SHELL` to say zsh. Overriding it here makes the tab's `$SHELL`
    // match the spawned program, which is what tools like `chsh`,
    // `script(1)`, and shell-aware wrappers (e.g. `git`'s pager) expect.
    //
    // Windows shells use the program's own naming convention (pwsh.exe
    // / powershell.exe / cmd.exe), not $SHELL, so we leave it alone.
    // The empty-program guard matters on the `_defaultShell` fallback
    // path (detection found nothing): exporting `SHELL=''` there would
    // break anything in the child that execs `$SHELL` (tmux
    // default-shell, `script`, editors spawning subshells).
    if (!Platform.isWindows && profile.program.isNotEmpty) {
      env['SHELL'] = profile.program;
    }

    // POSIX zsh: stock zsh emits no OSC 7 and reads no PROMPT_COMMAND —
    // cwd reporting is injected via a `ZDOTDIR` shim whose `.zshenv`
    // registers an OSC 7 `precmd` hook and restores the user's real
    // ZDOTDIR so the rest of their startup chain (.zprofile / .zshrc /
    // .zlogin) loads exactly as before. See `_ensureZshOsc7Integration`.
    if (!Platform.isWindows && profile.isPosixZsh && profile.showCwdInTitle) {
      env['ZDOTDIR'] = await _ensureZshOsc7Integration();
    }

    // POSIX fish: stock fish emits no OSC 7 on any platform and reads no
    // env-var hooks — cwd reporting is injected via `--init-command`,
    // which fish runs AFTER reading config.fish (so user config loads
    // untouched) and BEFORE the first interactive prompt. See
    // `_fishOsc7Init`.
    if (!Platform.isWindows && profile.isPosixFish && profile.showCwdInTitle) {
      args = [...args, '-C', _fishOsc7Init];
    }

    // PowerShell: inject a `prompt` override that emits OSC 2 with the
    // cwd (ConPTY eats OSC 7 from PowerShell, same restriction as
    // Nushell — see `_extractCwdFromPwshTitle`). The override is
    // delivered as a temp-file script loaded via `-File` so the
    // `cmd.exe /c` quoting layer doesn't mangle the script body (the
    // historical failure mode for `-Command "..."` injection).
    if (profile.needsPowerShellPromptOverride) {
      final initPath = await _writePwshInitScript();
      args = [...args, '-NoExit', '-File', initPath];
    }

    final initialCwd =
        initialCwdOverride ??
        await _resolveInitialCwd(
          profile,
          spawnCwd,
          preresolvedWslHome: homePath,
        );
    return Surface(profile: profile, initialCwd: initialCwd)
      ..program = profile.program
      ..args = args
      ..spawnCwd = spawnCwd
      ..env = env
      ..homePath = homePath;
  }

  /// Bash snippet that emits an OSC 7 sequence (`ESC ] 7 ; file://host/path
  /// ST`) before each prompt. Used as `PROMPT_COMMAND` so the terminal engine
  /// can track the shell's working directory. The `%s` format specifiers are
  /// filled by `printf` from `"$(hostname)"` and `"$PWD"` (double-quoted so
  /// bash expands them at prompt time).
  static const String _osc7PromptCommand =
      r'''printf '\033]7;file://%s%s\033\\' "$(hostname)" "$PWD"''';

  /// fish snippet handed to `fish --init-command` (`-C`) so cwd reporting
  /// works in stock fish (which emits no OSC 7 on its own, on any platform).
  ///
  /// fish evaluates `-C` commands AFTER reading `config.fish` and BEFORE
  /// the first interactive prompt, so the user's config loads untouched
  /// and the handler we register here survives it. The `fish_prompt`
  /// event fires every time fish displays a prompt — exactly when the
  /// cwd needs to be (re)reported.
  ///
  /// Single-quoted on purpose: fish single quotes pass `\033` through
  /// literally so the `printf` builtin (not the shell's string parser)
  /// expands it to ESC — symmetric with [_osc7PromptCommand] on bash.
  /// BEL (`\a`) terminator instead of ST to sidestep fish's own
  /// backslash collapsing inside quotes; the Alacritty engine accepts
  /// both terminators.
  static const String _fishOsc7Init =
      r"""function __octodo_osc7 --on-event fish_prompt; printf '\033]7;file://%s%s\a' (hostname) "$PWD"; end""";

  /// zsh `.zshenv` shim written into a temp `ZDOTDIR` by
  /// [_ensureZshOsc7Integration]. zsh reads `$ZDOTDIR/.zshenv` before any
  /// other startup file (login or not), which makes ZDOTDIR the one
  /// env-var-reachable seam for injecting into zsh — zsh itself reads no
  /// PROMPT_COMMAND-style hooks from the environment.
  ///
  /// The shim must do three things, in order:
  ///
  /// 1. Restore the user's real ZDOTDIR (baked in by Dart at write time)
  ///    so every later startup file — `.zprofile`, `.zshrc`, `.zlogin` —
  ///    loads from its normal location, and so nested zsh processes
  ///    inherit the real value instead of re-running this shim.
  /// 2. Register the OSC 7 `precmd` hook by appending to
  ///    `precmd_functions` (no `add-zsh-hook` autoload needed — the
  ///    array append is what add-zsh-hook does internally, and works
  ///    this early in .zshenv where fpath-based autoloads are risky).
  ///    `$HOST` is zsh-native (no `$(hostname)` subprocess per prompt).
  ///    Registered in .zshenv, the hook runs before the user's `.zshrc`
  ///    and survives it — even a `.zshrc` that replaces the prompt.
  /// 3. Chain to the user's real `.zshenv`, which zsh skipped because it
  ///    read ours (ZDOTDIR was already pointing here).
  ///
  /// Emission duplicates (user already has OSC 7 integration, e.g.
  /// ghostty/kitty hooks) are harmless: the engine just re-parses the
  /// same `file://` URI.
  static String _zshEnvShim(String realZdotdir) =>
      '''
# octodo shell integration (OSC 7 cwd reporting)
export ZDOTDIR='${_shellSingleQuote(realZdotdir)}'
_octodo_osc7() { printf '\\033]7;file://%s%s\\033\\\\' "\$HOST" "\$PWD" }
typeset -ga precmd_functions
[[ " \${precmd_functions[@]} " == *" _octodo_osc7 "* ]] || precmd_functions+=(_octodo_osc7)
[[ -f "\$ZDOTDIR/.zshenv" ]] && source "\$ZDOTDIR/.zshenv"
''';

  /// POSIX-shell single-quote escaping for embedding a path in a
  /// shell script ('…' + `\'` + '…' concatenation).
  static String _shellSingleQuote(String s) => s.replaceAll("'", r"'\''");

  /// Cached absolute path of the temp ZDOTDIR written by
  /// [_ensureZshOsc7Integration]. Cleared between app runs; reused across
  /// every zsh tab within a single run (the shim is idempotent and
  /// content-identical).
  static String? _zshIntegrationDirPath;

  /// Write the zsh OSC 7 shim (see [_zshEnvShim]) into a temp directory
  /// as `.zshenv` and return the directory path, which `_makeSurface`
  /// exports as `ZDOTDIR` for zsh tabs. Called once per zsh spawn but
  /// cached so subsequent spawns reuse the same directory.
  static Future<String> _ensureZshOsc7Integration() async {
    final cached = _zshIntegrationDirPath;
    if (cached != null) return cached;
    // The user's real ZDOTDIR: normally unset (zsh then uses $HOME); when
    // set (oh-my-zsh custom ZDOTDIR layouts, Nix etc.) restore THAT.
    final realZdotdir =
        Platform.environment['ZDOTDIR'] ?? Platform.environment['HOME'] ?? '/';
    final dir = Directory(
      '${Directory.systemTemp.path}/octodo_zsh_integration',
    );
    await dir.create(recursive: true);
    await File(
      '${dir.path}/.zshenv',
    ).writeAsString(_zshEnvShim(realZdotdir), flush: true);
    _zshIntegrationDirPath = dir.path;
    return dir.path;
  }

  /// Test-only accessors mirroring [pwshInitScriptForTest] /
  /// [writePwshInitScriptForTest]: let tests pin the shim body, the
  /// fish snippet, and the temp-dir writer without spinning up real
  /// zsh / fish processes.
  @visibleForTesting
  static String zshEnvShimForTest(String realZdotdir) =>
      _zshEnvShim(realZdotdir);

  @visibleForTesting
  static String get fishOsc7InitForTest => _fishOsc7Init;

  @visibleForTesting
  static Future<String> writeZshIntegrationForTest() =>
      _ensureZshOsc7Integration();

  /// PowerShell init script that overrides `prompt` to emit OSC 2 with
  /// the cwd after each prompt, then chains to whatever the user's
  /// `$PROFILE` (or the built-in default) installed as `prompt`.
  ///
  /// Why OSC 2 (not OSC 7): ConPTY intercepts OSC 7 from PowerShell on
  /// Windows, so the Alacritty engine never sees the cwd that way.
  /// ConPTY passes OSC 2 through, so we emit `PowerShell - <cwd>` as
  /// the window title after every prompt and parse it back in
  /// `TerminalView._extractCwdFromPwshTitle`.
  ///
  /// Why emit AFTER the user's prompt (not before): oh-my-posh /
  /// starship / `$Host.UI.RawUI.WindowTitle` all emit their own OSC 2
  /// during the prompt. Emitting ours last means our cwd signal wins,
  /// and the title the engine sees is always parseable as long as the
  /// user hasn't manually redefined `prompt` mid-session.
  ///
  /// Chaining pattern: save the existing `prompt` scriptblock under a
  /// reserved name (`__octodo_original_prompt`) on first run, then
  /// invoke it from the wrapper. If `prompt` is somehow missing (e.g.
  /// the user's $PROFILE failed and PowerShell fell back to nothing),
  /// we install a minimal fallback so the wrapper never crashes.
  ///
  /// Works for both `pwsh.exe` (PowerShell 7+) and `powershell.exe`
  /// (Windows PowerShell 5.1) — both implement the `prompt` function
  /// and `${function:prompt}` scriptblock access identically.
  static const String _pwshInitScript = r'''
$__Esc = [char]27
$__Bel = [char]7
if (-not (Test-Path Function:__octodo_original_prompt)) {
    if (Test-Path Function:prompt) {
        Set-Item -Path Function:__octodo_original_prompt -Value (Get-Item Function:prompt).ScriptBlock
    } else {
        Set-Item -Path Function:__octodo_original_prompt -Value { "PS> " }
    }
}
function prompt {
    $__path = $ExecutionContext.SessionState.Path.CurrentLocation.ProviderPath
    $__result = & (Get-Item Function:__octodo_original_prompt)
    Write-Host -NoNewline "${__Esc}]2;PowerShell - ${__path}${__Bel}"
    return $__result
}
''';

  /// Cached absolute path of the temp file written by
  /// [_writePwshInitScript]. Cleared between app runs; reused across
  /// every PowerShell tab within a single run.
  static String? _pwshInitScriptPath;

  /// Write [_pwshInitScript] to `%TEMP%\octodo_pwsh_init.ps1` and
  /// return its absolute path. Called once per PowerShell spawn but
  /// cached so subsequent spawns reuse the same file (the script is
  /// idempotent and content-identical). Using a temp file (rather
  /// than `-Command "..."`) avoids `cmd.exe /c` quote-mangling of the
  /// script body and dodges the Windows ~32K arg-length limit.
  static Future<String> _writePwshInitScript() async {
    final cached = _pwshInitScriptPath;
    if (cached != null) return cached;
    final tempDir = Directory.systemTemp;
    final scriptFile = File(
      '${tempDir.path}${Platform.pathSeparator}octodo_pwsh_init.ps1',
    );
    await scriptFile.writeAsString(_pwshInitScript, flush: true);
    _pwshInitScriptPath = scriptFile.path;
    return _pwshInitScriptPath!;
  }

  /// Test-only accessor for [_pwshInitScript]. Exposed so the script
  /// body can be pinned in a golden-style test without spinning up a
  /// real PowerShell process.
  @visibleForTesting
  static String get pwshInitScriptForTest => _pwshInitScript;

  /// Test-only accessor for [_writePwshInitScript]. The production
  /// path is `static` and called from [_makeSurface]; tests need the
  /// same entry point to verify file creation and caching.
  @visibleForTesting
  static Future<String> writePwshInitScriptForTest() => _writePwshInitScript();

  /// Replace (or append) the `--cd` argument in [profile]'s args with
  /// [linuxPath], so a new WSL tab starts in the remembered directory
  /// instead of the default `~`.
  static List<String> _wslArgsWithCd(ShellProfile profile, String linuxPath) {
    final args = List<String>.of(profile.args);
    final cdIdx = args.indexWhere((a) => a == '--cd' || a.startsWith('--cd='));
    if (cdIdx >= 0) {
      if (args[cdIdx] == '--cd' && cdIdx + 1 < args.length) {
        args[cdIdx + 1] = linuxPath;
      } else {
        args[cdIdx] = '--cd=$linuxPath';
      }
    } else {
      args.addAll(['--cd', linuxPath]);
    }
    return args;
  }

  /// Record a shell's last-known cwd (from OSC 7) so the next tab of
  /// the same type starts there. Only stores for shells with reliable
  /// OSC 7 reporting (`showCwdInTitle == true`).
  void _rememberShellCwd(ShellProfile profile, String cwd) {
    if (!profile.remembersCwd || cwd.isEmpty) return;
    _lastCwdByShell[profile.shortName] = cwd;
  }

  /// Marker sentinel used as `initialCwd` when a WSL distro's `$HOME` could
  /// not be resolved in time. The shell still starts in `$HOME` thanks to
  /// the `--cd ~` arg on the WSL profile, so the tab chip's `~` shortcut
  /// should fire on this path; [Surface.fallbackTitle] matches this
  /// sentinel specially.
  static const String _wslHomeUnknownMarker = '~';

  Future<String> _resolveInitialCwd(
    ShellProfile profile,
    String workingDirectory, {
    String? preresolvedWslHome,
  }) async {
    if (profile.isWsl) {
      final home = preresolvedWslHome ?? await _queryWslHome(profile);
      if (home != null) return home;
      // Query failed / timed out — bash still starts in $HOME via
      // `--cd ~`, so we don't translate the Windows cwd down to a
      // mount path that OSC 7 will never emit. Use a marker and let
      // `fallbackTitle` recognise it.
      return _wslHomeUnknownMarker;
    }
    return translateCwdForShell(
      cwd: workingDirectory,
      program: profile.program,
    );
  }

  /// Query a WSL distro's `$HOME` as a Linux path (e.g. `/home/<user>`),
  /// via `wsl.exe -d <distro> wslpath -u ~`. Capped at 1 s so a misbehaving
  /// distro can't block tab creation.
  ///
  /// Linux-form is intentional: bash's startup cwd is the distro's
  /// `$HOME` (forced by the `--cd ~` arg on the WSL profile), and its
  /// OSC 7 emits the same `/home/<user>` string. Using the translated
  /// mount path (`/mnt/c/Users/<user>`) would never compare equal to
  /// that, so the tab chip's `~` shortcut would never fire.
  ///
  /// The distro comes from [ShellProfile.wslDistro], so a non-default
  /// distro resolves its OWN home rather than the default distro's.
  /// Returns null on timeout / failure; callers fall back to the
  /// translated mount path.
  Future<String?> _queryWslHome(ShellProfile profile) async {
    if (profile.program.isEmpty) return null;
    final args = profile.wslDistro != null
        ? ['-d', profile.wslDistro!, 'wslpath', '-u', '~']
        : const ['wslpath', '-u', '~'];
    try {
      final result = await Process.run(
        profile.program,
        args,
      ).timeout(const Duration(seconds: 1));
      if (result.exitCode != 0) {
        _log.log(
          Level.WARNING,
          'wslpath -u ~ failed (exitCode=${result.exitCode}, stderr=${result.stderr}) for ${profile.program} ${args.join(' ')}',
        );
        return null;
      }
      final home = (result.stdout as String).trim();
      return home.isEmpty ? null : home;
    } on TimeoutException {
      _log.warning(
        'wslpath -u ~ timed out after 1s for ${profile.program} ${args.join(' ')}',
      );
      return null;
    } catch (e, st) {
      _log.log(
        Level.WARNING,
        'wslpath -u ~ threw for ${profile.program} ${args.join(' ')}',
        e,
        st,
      );
      return null;
    }
  }

  // ── Surface operations ───────────────────────────────────────────

  void _newSurfaceInFocusedContainer() {
    final container = _focusedContainer;
    if (container == null) return;
    // _makeSurface awaits the WSL $HOME query (or no-op for non-WSL);
    // fire and rebuild once the new surface is ready.
    unawaited(_newSurfaceInFocusedContainerAsync(container));
  }

  Future<void> _newSurfaceInFocusedContainerAsync(
    PaneContainer container,
  ) async {
    final s = await _makeSurface(_defaultShell, userHome);
    if (!mounted) return;
    setState(() {
      container.surfaces.add(s);
      container.focusedIndex = container.surfaces.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      s.focusNode.requestFocus();
    });
  }

  void _closeFocusedSurface() {
    final container = _focusedContainer;
    if (container == null || _rootPane == null) return;
    final surface = container.focusedSurface;
    if (surface == null) return;

    // Find the container that owns this surface (it should be the
    // focused one, but verify in case focus is stale).
    final owner = _findContainerOf(surface);
    if (owner == null) return;

    _closeSurfaceInContainer(owner, surface);
  }

  /// Move input focus to the next pane in [direction]. Picked by
  /// centre-of-pane vector: a candidate must lie in the requested
  /// quadrant of the focused pane's centre, and among those the one
  /// with the smallest primary-axis distance wins (ties broken by
  /// secondary-axis distance). This is the standard i3 / sway /
  /// vimium pane-focus algorithm — direction matters more than
  /// straight-line distance, so a pane 200px directly above wins
  /// over a pane 100px diagonally up-right.
  ///
  /// Render positions are read via each [PaneContainer.dropOverlayKey]
  /// GlobalKey. In maximized mode the hidden tree's containers don't
  /// paint, but they ARE laid out and mounted (see `PaneLayout`),
  /// so their RenderBoxes still report sensible positions.
  void _focusPaneInDirection(PaneDirection direction) {
    final root = _rootPane;
    final focused = _focusedContainer;
    if (root == null || focused == null) return;

    final fromBox =
        focused.dropOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (fromBox == null) return;
    final fromCenter =
        fromBox.localToGlobal(Offset.zero) +
        Offset(fromBox.size.width / 2, fromBox.size.height / 2);

    // Collect every leaf in the tree. forEachLeaf lives on PaneSplit
    // and recurses; a single-container tree (the common v1 case)
    // is handled by checking the root directly.
    final leaves = <PaneContainer>[];
    if (root is PaneContainer) {
      leaves.add(root);
    } else if (root is PaneSplit) {
      root.forEachLeaf(leaves.add);
    }
    if (leaves.length <= 1) return;

    PaneContainer? best;
    double bestPrimary = double.infinity;
    double bestSecondary = double.infinity;

    for (final c in leaves) {
      if (identical(c, focused)) continue;
      final box =
          c.dropOverlayKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final center =
          box.localToGlobal(Offset.zero) +
          Offset(box.size.width / 2, box.size.height / 2);
      final dx = center.dx - fromCenter.dx;
      final dy = center.dy - fromCenter.dy;

      // Each direction yields (primary-distance, secondary-distance,
      // valid). Valid is true only when the candidate lies in the
      // requested half-plane along the primary axis.
      double primary;
      double secondary;
      bool valid;
      switch (direction) {
        case PaneDirection.right:
          primary = dx;
          secondary = dy.abs();
          valid = dx > 0;
          break;
        case PaneDirection.left:
          primary = -dx;
          secondary = dy.abs();
          valid = dx < 0;
          break;
        case PaneDirection.down:
          primary = dy;
          secondary = dx.abs();
          valid = dy > 0;
          break;
        case PaneDirection.up:
          primary = -dy;
          secondary = dx.abs();
          valid = dy < 0;
          break;
      }
      if (!valid) continue;
      if (primary < bestPrimary ||
          (primary == bestPrimary && secondary < bestSecondary)) {
        bestPrimary = primary;
        bestSecondary = secondary;
        best = c;
      }
    }

    if (best != null) _focusContainer(best);
  }

  void _closeSurfaceInContainer(PaneContainer owner, Surface surface) {
    if (_rootPane is PaneContainer) {
      // Single-pane workspace: the container holds only this surface.
      if ((_rootPane as PaneContainer).surfaces.length == 1) {
        // Closing the last terminal would empty the workspace. Ask
        // the parent to confirm BEFORE mutating any state — if the
        // user cancels, the workspace stays exactly as it was, with
        // the terminal still alive. Without this gate, the previous
        // behavior tore down the pane tree first, then prompted,
        // and a cancelled prompt left the workspace in a rootless
        // state with no way to spawn a new terminal.
        _requestCloseEmptyWorkspace();
        return;
      }
      // Multiple surfaces in the single container: just remove this one.
      setState(() {
        owner.surfaces.remove(surface);
        // The container stays alive (it still has other surfaces),
        // so the per-surface dispose must happen here — not inside
        // PaneContainer.dispose().
        surface.dispose();
        if (owner.focusedIndex >= owner.surfaces.length) {
          owner.focusedIndex = owner.surfaces.length - 1;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusCurrentPane();
      });
      return;
    }

    // Multi-pane workspace: try to remove via the split tree.
    final split = _rootPane as PaneSplit;
    final result = _applyCloseSurface(split, owner, surface);
    if (result == null) return; // surface not found (shouldn't happen)

    setState(() {
      _rootPane = result.tree;
      _focusedContainer = result.focused;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusCurrentPane();
    });
  }

  /// Ask the parent to confirm closing the workspace whose last
  /// terminal is being closed, then — if the user agrees — dispose
  /// the (still-alive) tree and notify the parent via [onEmpty] so
  /// it can drop the workspace entry. If the user cancels, the
  /// state is untouched and the terminal keeps running.
  ///
  /// Note: a workspace with a multi-pane split tree always has at
  /// least two terminal surfaces (one per leaf), so a "last
  /// surface" case can only arise when the root is a single
  /// [PaneContainer] with one tab. We don't need to recheck that
  /// here — the caller already detected it.
  Future<void> _requestCloseEmptyWorkspace() async {
    final confirmed = await widget.confirmCloseWorkspace();
    if (!confirmed || !mounted) return;
    // Tree shape cannot have changed between the click and the
    // dialog dismissal (no other code path mutates the root), but
    // guard anyway so a disposed widget doesn't dereference null.
    final root = _rootPane;
    if (root is! PaneContainer || root.surfaces.length != 1) return;
    root.dispose();
    _rootPane = null;
    _focusedContainer = null;
    setState(() {});
    widget.onEmpty?.call();
  }

  /// Pure helper: close [surface] in [owner] inside a multi-pane
  /// tree, returning the new tree and focused container.
  ///
  /// Handles three cases:
  ///   * [owner] still has other surfaces → focused = [owner].
  ///   * [owner] collapsed and the sibling is now the root → focused =
  ///     sibling.
  ///   * [owner] collapsed via a *nested* split (the outer split
  ///     object is unchanged but its `first`/`second` slot was
  ///     reassigned to the surviving sibling) → focused = first
  ///     reachable leaf.
  ///
  /// Returns null if [surface] is not found in [tree].
  ///
  /// Package-private; exercised by `pane_tree_test.dart` via the
  /// `@visibleForTesting` `applyCloseSurfaceForTest` shim below to
  /// lock down the nested-collapse behaviour without spinning up a
  /// full workspace widget.
  static _CloseResult? _applyCloseSurface(
    PaneSplit tree,
    PaneContainer owner,
    Surface surface,
  ) {
    final newRoot = tree.removeSurface(surface);
    if (newRoot == null) return null;

    if (identical(newRoot, tree)) {
      // Two distinct cases fall under "newRoot is the same split
      // object":
      //   (a) [owner] still has other surfaces after removing
      //       [surface] — refresh focus on it (existing behaviour).
      //   (b) [owner] was disposed by a *nested* split collapsing in
      //       turn (the outer split's `first`/`second` slot got
      //       reassigned, but the outer split object itself is
      //       unchanged). In this case `tree.containsContainer(owner)`
      //       is false — [owner] is no longer in the tree — and
      //       re-pointing `_focusedContainer` at it would leave the
      //       field dangling on a disposed PaneContainer. Pick the
      //       first reachable leaf instead.
      if (tree.containsContainer(owner)) {
        if (owner.focusedIndex >= owner.surfaces.length) {
          owner.focusedIndex = owner.surfaces.length - 1;
        }
        return _CloseResult(tree, owner);
      }
      return _CloseResult(tree, tree.focusedLeaf as PaneContainer?);
    }
    if (newRoot is PaneContainer) {
      // Container collapsed — its sibling (the returned subtree) is
      // now the root.  If the root itself is a PaneContainer, the
      // whole tree became a single pane.
      if (newRoot.surfaces.isNotEmpty) {
        newRoot.focusedIndex = newRoot.focusedIndex.clamp(
          0,
          newRoot.surfaces.length - 1,
        );
      }
      return _CloseResult(newRoot, newRoot);
    }
    // newRoot is PaneSplit (only happens when removeSurface returns
    // a new split; current implementation never does, but keep the
    // branch for forward-compat).
    return _CloseResult(newRoot, newRoot.focusedLeaf as PaneContainer?);
  }

  PaneContainer? _findContainerOf(Surface surface) {
    final root = _rootPane;
    if (root == null) return null;
    if (root is PaneContainer) {
      return root.surfaces.contains(surface) ? root : null;
    }
    if (root is PaneSplit) {
      return root.findContainer(surface);
    }
    return null;
  }

  void _selectSurfaceInContainer(PaneContainer container, Surface surface) {
    final idx = container.surfaces.indexOf(surface);
    if (idx < 0) return;
    setState(() {
      container.focusedIndex = idx;
      _focusedContainer = container;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      surface.focusNode.requestFocus();
    });
  }

  void _focusContainer(PaneContainer container) {
    setState(() => _focusedContainer = container);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final surface = container.focusedSurface;
      if (surface != null) surface.focusNode.requestFocus();
    });
  }

  void _nextSurface() {
    final c = _focusedContainer;
    if (c == null || c.surfaces.length <= 1) return;
    setState(() {
      c.focusedIndex = (c.focusedIndex + 1) % c.surfaces.length;
    });
    _scrollActiveChipIntoView(c);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusCurrentPane();
    });
  }

  void _previousSurface() {
    final c = _focusedContainer;
    if (c == null || c.surfaces.length <= 1) return;
    setState(() {
      c.focusedIndex =
          (c.focusedIndex - 1 + c.surfaces.length) % c.surfaces.length;
    });
    _scrollActiveChipIntoView(c);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusCurrentPane();
    });
  }

  void _selectSurfaceByIndex(int index) {
    final c = _focusedContainer;
    if (c == null || index < 0 || index >= c.surfaces.length) return;
    setState(() => c.focusedIndex = index);
    _scrollActiveChipIntoView(c);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusCurrentPane();
    });
  }

  /// Ask the tab bar of [container] to scroll its newly-focused
  /// chip into view. Called from the three keyboard navigation
  /// paths (Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+1..9) so that
  /// navigating past the visible edge of the tab bar reveals the
  /// activated tab — matching what the mouse-click path already
  /// does via [_ContainerTabBarState._maybeAutoScroll]. Safe to
  /// call when the tab bar isn't mounted yet (e.g. during the
  /// first frame after a new tab is created and immediately
  /// focused) — the call is a no-op in that case.
  void _scrollActiveChipIntoView(PaneContainer container) {
    container.tabBarKey.currentState?.ensureIndexVisible(
      container.focusedIndex,
    );
  }

  // ── Split operations ─────────────────────────────────────────────

  void _splitFocusedContainer(Axis direction) {
    final container = _focusedContainer;
    final root = _rootPane;
    if (container == null || root == null) return;
    // _makeSurface awaits the WSL $HOME query; do it async.
    unawaited(_splitFocusedContainerAsync(container, root, direction));
  }

  Future<void> _splitFocusedContainerAsync(
    PaneContainer container,
    PaneNode root,
    Axis direction,
  ) async {
    final newSurface = await _makeSurface(_defaultShell, userHome);
    if (!mounted) return;
    final newContainer = PaneContainer()
      ..surfaces.add(newSurface)
      ..focusedIndex = 0;

    setState(() {
      if (root is PaneContainer) {
        // First split: wrap the root in a split.
        final newSplit = PaneSplit(
          direction: direction,
          first: root,
          second: newContainer,
          ratio: 0.5,
        );
        _rootPane = newSplit;
      } else if (root is PaneSplit) {
        _splitContainerInTree(root, container, newContainer, direction);
      }
      _focusedContainer = newContainer;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      newSurface.focusNode.requestFocus();
    });
  }

  /// Split the [target] container inside [parent], inserting
  /// [newContainer] in the given [direction].  Replaces the target
  /// node with a new PaneSplit.
  void _splitContainerInTree(
    PaneSplit parent,
    PaneContainer target,
    PaneContainer newContainer,
    Axis direction,
  ) {
    if (identical(parent.first, target)) {
      parent.first = PaneSplit(
        direction: direction,
        first: target,
        second: newContainer,
        ratio: 0.5,
      );
      return;
    }
    if (identical(parent.second, target)) {
      parent.second = PaneSplit(
        direction: direction,
        first: target,
        second: newContainer,
        ratio: 0.5,
      );
      return;
    }
    if (parent.first is PaneSplit) {
      _splitContainerInTree(
        parent.first as PaneSplit,
        target,
        newContainer,
        direction,
      );
    }
    if (parent.second is PaneSplit) {
      _splitContainerInTree(
        parent.second as PaneSplit,
        target,
        newContainer,
        direction,
      );
    }
  }

  void _onPaneResize(PaneSplit parent, double newRatio) {
    setState(() {
      parent.ratio = newRatio;
    });
  }

  /// Called when the user picks a shell from the per-pane dropdown.
  /// Sets it as the new default and immediately opens a tab in the
  /// focused container running that shell.
  void _openShellFromSelector(int index) {
    setState(() => _defaultShellIndex = index);
    _newSurfaceInFocusedContainer();
  }

  void _toggleMaximize() {
    setState(() => _isMaximized = !_isMaximized);
  }

  // ── Public action API ────────────────────────────────────────────
  //
  // These public mirrors of the private methods above are the
  // dispatch targets for the app-level `HardwareKeyboard` handler
  // installed by `_AppShellState` (see lib/main.dart). Same reason
  // as the TerminalViewState public API: flutter_alacritty's
  // bottom-up `Focus.onKeyEvent` consumes every keystroke before it
  // reaches our `CallbackShortcuts`, so we route everything through
  // a hardware-level handler instead. See
  // `lib/src/shortcuts/app_shortcuts.dart` for the full reasoning.

  void newTabPublic() => _newSurfaceInFocusedContainer();
  void closeTabPublic() => _closeFocusedSurface();
  void nextTabPublic() => _nextSurface();
  void previousTabPublic() => _previousSurface();
  void jumpToTabPublic(int index) => _selectSurfaceByIndex(index);
  void splitRightPublic() => _splitFocusedContainer(Axis.horizontal);
  void splitDownPublic() => _splitFocusedContainer(Axis.vertical);
  void focusPaneInDirectionPublic(PaneDirection direction) =>
      _focusPaneInDirection(direction);
  void toggleMaximizePanePublic() => _toggleMaximize();

  /// The currently-focused container, or null if the workspace has
  /// no root pane yet (early in `initState`).
  PaneContainer? get focusedContainer => _focusedContainer;

  /// Resolve the [TerminalViewState] currently receiving keyboard
  /// input — the focused surface in the focused container. Returns
  /// null when the workspace has no focused terminal yet (e.g. during
  /// the brief window between `_initRootPane` and the first paint).
  ///
  /// Used by the app-level shortcut handler to dispatch terminal-level
  /// actions (copy / paste / zoom / scroll) without each `TerminalView`
  /// having to register its own `HardwareKeyboard` listener.
  TerminalViewState? getFocusedTerminalViewState() {
    final container = _focusedContainer;
    if (container == null) return null;
    if (container.focusedIndex < 0 ||
        container.focusedIndex >= container.surfaces.length) {
      return null;
    }
    final surface = container.focusedSurface;
    if (surface == null) return null;
    return surface.viewKey.currentState as TerminalViewState?;
  }

  // ── Drag/drop mutations ──────────────────────────────────────────
  //
  // Two operations: same-list reorder and cross-list move.
  //
  // Index semantics match Flutter's [ReorderableListView]:
  // [oldIndex] and [newIndex] are positions in [container.surfaces]
  // BEFORE the move. If [newIndex] > [oldIndex], the implementation
  // must decrement by 1 after removal (Flutter already does this
  // internally for the chip widgets; here we do it ourselves).

  /// Same-container reorder. Called by [_ContainerTabBar] when the
  /// user drops a tab onto another tab in the same pane (or onto the
  /// end-of-list zone of the same pane).
  void _reorderSurfaceInContainer(
    PaneContainer container,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex < 0 ||
        oldIndex >= container.surfaces.length ||
        newIndex < 0 ||
        newIndex > container.surfaces.length) {
      return;
    }
    // Flutter's ReorderableListView contract: if newIndex > oldIndex
    // we decrement after removal. We've already done this in the
    // caller (_DraggableChip) — but defend here in case the end zone
    // path is used. Treat as "append past end" if oldIndex ==
    // surfaces.length - 1 and newIndex == surfaces.length.
    if (oldIndex == newIndex) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
      if (oldIndex == newIndex) return;
    }

    setState(() {
      final s = container.surfaces.removeAt(oldIndex);
      container.surfaces.insert(newIndex, s);
      // Keep the focused tab focused after reorder, if possible.
      container.focusedIndex = container.surfaces
          .indexOf(s)
          .clamp(0, container.surfaces.length - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusCurrentPane();
    });
  }

  /// Cross-container move. Called by [_ContainerTabBar] when a tab
  /// is dropped onto a different pane's tab bar, or onto another
  /// pane's terminal body (which appends to the end of that pane).
  ///
  /// Algorithm (avoids the "find surface anywhere in the tree"
  /// hazard of [PaneSplit.removeSurface], which would wipe the
  /// surface from the destination after we insert it):
  ///
  ///   1. Remove the surface from the source container's list.
  ///   2. If the source container is now empty AND we have a split
  ///      tree, detach it via [PaneSplit.removeContainer] (operates
  ///      by container reference — no surface lookup). The
  ///      destination is unaffected because we never touched it.
  ///   3. Insert the surface into the destination container at
  ///      [targetIndex].
  ///   4. Focus the destination on the moved surface.
  void _moveSurfaceBetweenContainers(
    SurfaceDragData drag,
    PaneContainer toContainer,
    int targetIndex,
  ) {
    final root = _rootPane;
    if (root == null) return;
    final fromContainer = _findContainerById(drag.sourceContainerId);
    final surface = _findSurfaceById(drag.surfaceId);
    if (fromContainer == null || surface == null) return;

    if (identical(fromContainer, toContainer)) return;
    if (root is! PaneSplit) return;

    final clampedTarget = targetIndex.clamp(0, toContainer.surfaces.length);

    setState(() {
      // 1) Remove from source list.
      fromContainer.surfaces.remove(surface);
      // Fix focused index if it landed out of range.
      if (fromContainer.focusedIndex >= fromContainer.surfaces.length) {
        fromContainer.focusedIndex = fromContainer.surfaces.isEmpty
            ? 0
            : fromContainer.surfaces.length - 1;
      }

      // 2) Collapse source if it became empty (tree is a split,
      //    and source != destination so source's slot is no longer
      //    needed).
      if (fromContainer.surfaces.isEmpty) {
        final newRoot = root.removeContainer(fromContainer);
        if (newRoot != null) {
          _rootPane = newRoot;
        }
      }

      // 3) Insert into destination.
      toContainer.surfaces.insert(clampedTarget, surface);
      toContainer.focusedIndex = toContainer.surfaces
          .indexOf(surface)
          .clamp(0, toContainer.surfaces.length - 1);
      _focusedContainer = toContainer;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      surface.focusNode.requestFocus();
    });
  }

  /// Drag-to-edge split. Called when a tab is dropped onto one of
  /// the four edges of a pane (left/right/top/bottom). The pane at
  /// [target] is replaced in the tree by a split with the dragged
  /// tab in a new container on the indicated side.
  ///
  /// Source container collapses if it becomes empty (same as
  /// [_moveSurfaceBetweenContainers]).
  ///
  /// Special case: dragging a tab from its own pane to one of its
  /// own edges with only one surface is a no-op (would create an
  /// empty pane). Dragging the only surface to a different pane's
  /// edge still works.
  void _dropToSplitEdge(
    SurfaceDragData drag,
    PaneContainer target,
    PaneEdge edge,
  ) {
    final root = _rootPane;
    if (root == null) return;
    final fromContainer = _findContainerById(drag.sourceContainerId);
    final surface = _findSurfaceById(drag.surfaceId);
    if (fromContainer == null || surface == null) return;

    final result = _applyDropToSplitEdge(
      root: root,
      fromContainer: fromContainer,
      surface: surface,
      target: target,
      direction: edge.splitDirection,
      isFirst: edge.newContainerIsFirst,
    );
    if (result == null) return;

    setState(() {
      _rootPane = result.tree;
      _focusedContainer = result.focused;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      surface.focusNode.requestFocus();
    });
  }

  /// Pure helper behind [_dropToSplitEdge]: removes [surface] from
  /// [fromContainer], collapses [fromContainer] if it emptied, builds
  /// a new container holding [surface], and replaces [target] in the
  /// tree with a split pairing [target] + the new container.
  ///
  /// Returns null for the no-op case (dragging the only surface of a
  /// container onto one of its own edges).
  ///
  /// CRITICAL: the "wrap the root in a new split" branch must test the
  /// **post-collapse** root ([updatedRoot]), not [root] captured at
  /// entry. When [fromContainer] collapses and its sibling becomes the
  /// new root, that sibling is a [PaneContainer] identical to [target]
  /// — testing the stale entry-time [root] (a [PaneSplit]) skips the
  /// branch and the new container is never attached, so the dragged
  /// terminal vanishes. Exercised by `pane_tree_test.dart`'s
  /// "applyDropToSplitEdgeForTest" group.
  static _DropResult? _applyDropToSplitEdge({
    required PaneNode root,
    required PaneContainer fromContainer,
    required Surface surface,
    required PaneContainer target,
    required Axis direction,
    required bool isFirst,
  }) {
    // No-op: dragging the only surface of a pane onto one of its own
    // edges would just empty the source and immediately re-wrap it.
    if (identical(fromContainer, target) &&
        fromContainer.surfaces.length == 1) {
      return null;
    }

    // 1) Remove from source.
    fromContainer.surfaces.remove(surface);
    if (fromContainer.focusedIndex >= fromContainer.surfaces.length) {
      fromContainer.focusedIndex = fromContainer.surfaces.isEmpty
          ? 0
          : fromContainer.surfaces.length - 1;
    }

    // 2) Collapse source if it became empty. Only a split root has a
    //    sibling to splice in; the guard against [target] is belt-and-
    //    braces (the no-op check above already handled same-container).
    var updatedRoot = root;
    if (fromContainer.surfaces.isEmpty &&
        root is PaneSplit &&
        !identical(fromContainer, target)) {
      final newRoot = root.removeContainer(fromContainer);
      if (newRoot != null) {
        updatedRoot = newRoot;
      }
    }

    // 3) Build the new container holding the dragged tab.
    final newContainer = PaneContainer()
      ..surfaces.add(surface)
      ..focusedIndex = 0;

    // 4) Replace `target` in the tree with a Split.
    if (identical(updatedRoot, target) && updatedRoot is PaneContainer) {
      // Single-pane workspace (or post-collapse single container that
      // IS the target): wrap the root in a new split.
      return _DropResult(
        PaneSplit(
          direction: direction,
          first: isFirst ? newContainer : target,
          second: isFirst ? target : newContainer,
          ratio: 0.5,
        ),
        newContainer,
      );
    }
    if (updatedRoot is PaneSplit) {
      final r = updatedRoot.replaceContainerWithSplit(
        target,
        newContainer,
        direction,
        isFirst,
      );
      if (r == null) {
        // Target not found in the tree — shouldn't happen because we
        // rendered an overlay for it. Defensive: revert the surface
        // insert and leave the tree as the post-collapse root.
        target.surfaces.add(surface);
        return _DropResult(updatedRoot, target);
      }
      return _DropResult(r, newContainer);
    }

    // updatedRoot is a PaneContainer != target: target isn't reachable.
    // Defensive revert (same as above).
    target.surfaces.add(surface);
    return _DropResult(updatedRoot, target);
  }

  PaneContainer? _findContainerById(String id) {
    final root = _rootPane;
    if (root == null) return null;
    if (root is PaneContainer) {
      return root.id == id ? root : null;
    }
    if (root is PaneSplit) {
      PaneContainer? visit(PaneNode node) {
        if (node is PaneContainer) {
          return node.id == id ? node : null;
        }
        if (node is PaneSplit) {
          return visit(node.first) ?? visit(node.second);
        }
        return null;
      }

      return visit(root);
    }
    return null;
  }

  Surface? _findSurfaceById(String id) {
    final root = _rootPane;
    if (root == null) return null;
    Surface? visit(PaneNode node) {
      if (node is PaneContainer) {
        for (final s in node.surfaces) {
          if (s.id == id) return s;
        }
        return null;
      }
      if (node is PaneSplit) {
        return visit(node.first) ?? visit(node.second);
      }
      return null;
    }

    return visit(root);
  }

  @override
  void dispose() {
    for (final sub in _settingsSubs) {
      sub.cancel();
    }
    _settingsSubs.clear();
    _isAnyTabDragActive.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _rootPane?.dispose();
    super.dispose();
  }

  /// Toggle the workspace-level drag-active flag. Called by every
  /// `_ContainerTabBarState` via [PaneLayout.onAnyDragActiveChanged] on
  /// `LongPressDraggable.onDragStarted` / `onDragCompleted` /
  /// `onDraggableCanceled`. Idempotent — multiple starts/ends from
  /// interleaved drags collapse to the right boolean.
  void _setAnyDragActive(bool active) {
    if (_isAnyTabDragActive.value == active) return;
    _isAnyTabDragActive.value = active;
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: WorkspaceBindings.build(
        newTab: _newSurfaceInFocusedContainer,
        closeTab: _closeFocusedSurface,
        nextTab: _nextSurface,
        previousTab: _previousSurface,
        jumpToTab: _selectSurfaceByIndex,
        splitRight: () => _splitFocusedContainer(Axis.horizontal),
        splitDown: () => _splitFocusedContainer(Axis.vertical),
        focusPaneInDirection: _focusPaneInDirection,
        toggleMaximizePane: _toggleMaximize,
      ),
      child: Focus(
        autofocus: true,
        child: TerminalSettingsScope(
          // Owning notifier — every settings/theme change in
          // [_initSettings] updates `_settingsNotifier.value`, which
          // triggers `didChangeDependencies` on each TerminalView
          // (which calls `_engine.reconfigure(...)` directly) without
          // walking the workspace subtree.
          notifier: _settingsNotifier,
          child: _rootPane == null
              ? const SizedBox.shrink()
              : PaneLayout(
                  root: _rootPane!,
                  focusedContainer: _focusedContainer,
                  onFocusContainer: _focusContainer,
                  onFocusSurface: _selectSurfaceInContainer,
                  onNewSurface: (container) {
                    _focusContainer(container);
                    _newSurfaceInFocusedContainer();
                  },
                  onCloseSurface: _closeSurfaceInContainer,
                  onSplit: (container, surface, direction) {
                    _focusContainer(container);
                    _splitFocusedContainer(direction);
                  },
                  onResize: _onPaneResize,
                  onReorderSurface: _reorderSurfaceInContainer,
                  onMoveSurfaceBetweenContainers: _moveSurfaceBetweenContainers,
                  onDropToSplitEdge: _dropToSplitEdge,
                  isAnyTabDragActive: _isAnyTabDragActive,
                  onAnyDragActiveChanged: _setAnyDragActive,
                  workingDirectory: userHome,
                  onShellCwdChanged: _rememberShellCwd,
                  availableShells: widget.availableShells,
                  defaultShellIndex: _defaultShellIndex,
                  onDefaultShellChanged: _openShellFromSelector,
                  isMaximized: _isMaximized,
                  onToggleMaximize: _toggleMaximize,
                ),
        ),
      ),
    );
  }
}

/// USB-HID logical keys for Ctrl+1..9 surface switching live in
/// `lib/src/shortcuts/app_shortcuts.dart` (`_digitKeys`); the
/// workspace factory reads them directly so this file doesn't need
/// its own copy.
