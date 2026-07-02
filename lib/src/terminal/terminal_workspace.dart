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
  /// Called when the last surface in the last container is closed —
  /// the workspace becomes empty.  The parent (e.g. AppShell) is
  /// expected to remove the workspace.  If null, the workspace is
  /// left in an empty state.
  final VoidCallback? onEmpty;

  const TerminalWorkspace({
    super.key,
    this.name = 'Workspace',
    this.color = const Color(0xFF89B4FA),
    required this.availableShells,
    this.onClose,
    this.onNameChanged,
    this.onActiveChanged,
    this.onEmpty,
  });

  @override
  State<TerminalWorkspace> createState() => TerminalWorkspaceState();
}

class TerminalWorkspaceState extends State<TerminalWorkspace>
    with WidgetsBindingObserver {
  PaneNode? _rootPane;
  PaneContainer? _focusedContainer;
  int _defaultShellIndex = 0;

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

  /// Subscribe to every user-facing terminal setting and rebuild
  /// `_terminalSettings` on change. One `setState` per change is fine
  /// — the inner `TerminalView` instances compare snapshots in
  /// `didUpdateWidget` and only call `_engine.reconfigure(...)` when
  /// the snapshot actually differs.
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
      cursorBlink: runtime.store.get<bool>(t.cursorBlink),
      scrollbackLines: runtime.store.get<int>(t.scrollbackLines),
      copyOnSelect: runtime.store.get<bool>(t.copyOnSelect),
      bellMode: runtime.store.get<BellMode>(t.bellMode),
      terminalForeground: palette.terminalForeground,
      terminalSelection: palette.terminalSelection,
      terminalAnsiColors: palette.terminalAnsiColors,
    );

    void bump() {
      if (mounted) setState(() {});
    }

    _settingsSubs.add(runtime.store.watch<String>(t.fontFamily).listen((_) => bump()));
    _settingsSubs.add(runtime.store.watch<double>(t.fontSize).listen((v) {
      if (mounted) {
        setState(() {
          _terminalSettings = _terminalSettings.copyWith(fontSize: v);
        });
      }
    }));
    _settingsSubs.add(runtime.store.watch<CursorStyle>(t.cursorStyle).listen((v) {
      if (mounted) {
        setState(() {
          _terminalSettings = _terminalSettings.copyWith(cursorStyle: v);
        });
      }
    }));
    _settingsSubs.add(runtime.store.watch<bool>(t.cursorBlink).listen((v) {
      if (mounted) {
        setState(() {
          _terminalSettings = _terminalSettings.copyWith(cursorBlink: v);
        });
      }
    }));
    _settingsSubs.add(runtime.store.watch<int>(t.scrollbackLines).listen((v) {
      if (mounted) {
        setState(() {
          _terminalSettings = _terminalSettings.copyWith(scrollbackLines: v);
        });
      }
    }));
    _settingsSubs.add(runtime.store.watch<bool>(t.copyOnSelect).listen((v) {
      if (mounted) {
        setState(() {
          _terminalSettings = _terminalSettings.copyWith(copyOnSelect: v);
        });
      }
    }));
    _settingsSubs.add(runtime.store.watch<BellMode>(t.bellMode).listen((v) {
      if (mounted) {
        setState(() {
          _terminalSettings = _terminalSettings.copyWith(bellMode: v);
        });
      }
    }));

    // Theme (palette) change → swap terminal foreground, selection,
    // background, and the 16 ANSI colors from the new palette. The
    // background always tracks `palette.surface0` (the previous
    // `terminal.backgroundColor` user override was removed because
    // it defeated the "theme change retints the terminal" goal —
    // an explicit override always won over the palette).
    _settingsSubs.add(runtime.store
        .watch<String>(catalog.general.themeName)
        .listen((_) {
      if (mounted) {
        final p = _resolvePalette(runtime);
        setState(() {
          _terminalSettings = _terminalSettings.copyWith(
            backgroundColor: p.surface0,
            terminalForeground: p.terminalForeground,
            terminalSelection: p.terminalSelection,
            terminalAnsiColors: p.terminalAnsiColors,
          );
        });
      }
    }));
  }

  /// Resolve the palette currently selected by the user. Cheap —
  /// `AppPalettes.byId` walks the registry's 9-entry list.
  static ThemePalette _resolvePalette(SettingsRuntime runtime) =>
      AppPalettes.byId(
          runtime.store.get(runtime.catalog.general.themeName));

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

  ShellProfile get _defaultShell =>
      widget.availableShells[_defaultShellIndex];

  /// Build a [Surface] for [profile], starting in [workingDirectory].
  /// The profile is carried so the tab bar can render the shell's
  /// icon + shortName as the fallback title before the shell sets
  /// its own via OSC.
  ///
  /// [workingDirectory] is always a Windows path. We translate it to
  /// the shell-native form so `Surface.initialCwd == currentCwd`
  /// holds when the user has not `cd`'d (and the `~` shortcut in
  /// the tab chip can fire). For WSL specifically we additionally
  /// query the distro's actual `$HOME` (often `/home/<user>`, NOT
  /// the mount-point we translated to) — WSL's `cd ~` lands the
  /// shell in the WSL home, and the OSC 7 it then emits would not
  /// match a `/mnt/c/Users/<user>` initialCwd. The query is awaited
  /// once per surface creation; if it fails or times out we fall
  /// back to the translated mount path.
  Future<Surface> _makeSurface(
    ShellProfile profile,
    String workingDirectory,
  ) async {
    final initialCwd = await _resolveInitialCwd(profile, workingDirectory);
    return Surface(profile: profile, initialCwd: initialCwd)
      ..program = profile.program
      ..args = profile.args;
  }

  Future<String> _resolveInitialCwd(
    ShellProfile profile,
    String workingDirectory,
  ) async {
    if (profile.isWsl) {
      final home = await _queryWslHome(profile);
      if (home != null) return home;
    }
    return translateCwdForShell(
      cwd: workingDirectory,
      program: profile.program,
    );
  }

  /// Query a WSL distro's actual `$HOME` (e.g. `/home/<user>`), via
  /// `wsl.exe -d <distro> wslpath -w ~`. Capped at 1 s so a misbehaving
  /// distro can't block tab creation.
  ///
  /// The distro comes from [ShellProfile.wslDistro], so a non-default
  /// distro resolves its OWN home rather than the default distro's — the
  /// OSC 7 a tab emits after `cd ~` then matches this initial cwd, and the
  /// tab chip's `~` shortcut fires correctly. Returns null on timeout /
  /// failure; callers fall back to the translated mount path.
  Future<String?> _queryWslHome(ShellProfile profile) async {
    if (profile.program.isEmpty) return null;
    final args = profile.wslDistro != null
        ? ['-d', profile.wslDistro!, 'wslpath', '-w', '~']
        : const ['wslpath', '-w', '~'];
    try {
      final result = await Process.run(
        profile.program,
        args,
      ).timeout(const Duration(seconds: 1));
      if (result.exitCode != 0) {
        _log.log(Level.WARNING, 'wslpath -w ~ failed (exitCode=${result.exitCode}, stderr=${result.stderr}) for ${profile.program} ${args.join(' ')}');
        return null;
      }
      final home = (result.stdout as String).trim();
      return home.isEmpty ? null : home;
    } on TimeoutException {
      _log.warning('wslpath -w ~ timed out after 1s for ${profile.program} ${args.join(' ')}');
      return null;
    } catch (e, st) {
      _log.log(Level.WARNING, 'wslpath -w ~ threw for ${profile.program} ${args.join(' ')}', e, st);
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
    final fromCenter = fromBox.localToGlobal(Offset.zero) +
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
      final center = box.localToGlobal(Offset.zero) +
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
        // Close the workspace.
        _rootPane!.dispose();
        _rootPane = null;
        _focusedContainer = null;
        setState(() {});
        widget.onEmpty?.call();
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
      return _CloseResult(
        tree,
        tree.focusedLeaf as PaneContainer?,
      );
    }
    if (newRoot is PaneContainer) {
      // Container collapsed — its sibling (the returned subtree) is
      // now the root.  If the root itself is a PaneContainer, the
      // whole tree became a single pane.
      if (newRoot.surfaces.isNotEmpty) {
        newRoot.focusedIndex =
            newRoot.focusedIndex.clamp(0, newRoot.surfaces.length - 1);
      }
      return _CloseResult(newRoot, newRoot);
    }
    // newRoot is PaneSplit (only happens when removeSurface returns
    // a new split; current implementation never does, but keep the
    // branch for forward-compat).
    return _CloseResult(
      newRoot,
      newRoot.focusedLeaf as PaneContainer?,
    );
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusCurrentPane();
    });
  }

  void _selectSurfaceByIndex(int index) {
    final c = _focusedContainer;
    if (c == null || index < 0 || index >= c.surfaces.length) return;
    setState(() => c.focusedIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusCurrentPane();
    });
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
          parent.first as PaneSplit, target, newContainer, direction);
    }
    if (parent.second is PaneSplit) {
      _splitContainerInTree(
          parent.second as PaneSplit, target, newContainer, direction);
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
      PaneContainer container, int oldIndex, int newIndex) {
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
      container.focusedIndex =
          container.surfaces.indexOf(s).clamp(0, container.surfaces.length - 1);
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

    final clampedTarget =
        targetIndex.clamp(0, toContainer.surfaces.length);

    setState(() {
      // 1) Remove from source list.
      fromContainer.surfaces.remove(surface);
      // Fix focused index if it landed out of range.
      if (fromContainer.focusedIndex >= fromContainer.surfaces.length) {
        fromContainer.focusedIndex =
            fromContainer.surfaces.isEmpty
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
    if (identical(fromContainer, target) &&
        fromContainer.surfaces.length == 1) {
      // Can't split the only surface off into a new pane and leave
      // the source empty — it's a no-op.
      return;
    }

    final direction = edge.splitDirection;
    final isFirst = edge.newContainerIsFirst;

    setState(() {
      // 1) Remove from source.
      fromContainer.surfaces.remove(surface);
      if (fromContainer.focusedIndex >= fromContainer.surfaces.length) {
        fromContainer.focusedIndex =
            fromContainer.surfaces.isEmpty
                ? 0
                : fromContainer.surfaces.length - 1;
      }

      // 2) Collapse source if it became empty.
      if (fromContainer.surfaces.isEmpty &&
          root is PaneSplit &&
          !identical(fromContainer, target)) {
        final newRoot = root.removeContainer(fromContainer);
        if (newRoot != null) {
          _rootPane = newRoot;
        }
      }

      // 3) Build the new container holding the dragged tab.
      final newContainer = PaneContainer()
        ..surfaces.add(surface)
        ..focusedIndex = 0;

      // 4) Replace `target` in the tree with a Split.
      final updatedRoot = _rootPane!;
      if (identical(updatedRoot, target) && root is PaneContainer) {
        // Single-pane workspace: wrap the root in a new split.
        _rootPane = PaneSplit(
          direction: direction,
          first: isFirst ? newContainer : target,
          second: isFirst ? target : newContainer,
          ratio: 0.5,
        );
      } else if (updatedRoot is PaneSplit) {
        final r = updatedRoot.replaceContainerWithSplit(
          target,
          newContainer,
          direction,
          isFirst,
        );
        if (r == null) {
          // Target not found — shouldn't happen because we rendered
          // an overlay for it. Defensive: revert the surface insert.
          target.surfaces.add(surface);
          return;
        }
      }

      // 5) Focus the new container.
      _focusedContainer = newContainer;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      surface.focusNode.requestFocus();
    });
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
                onMoveSurfaceBetweenContainers:
                    _moveSurfaceBetweenContainers,
                onDropToSplitEdge: _dropToSplitEdge,
                isAnyTabDragActive: _isAnyTabDragActive,
                onAnyDragActiveChanged: _setAnyDragActive,
                workingDirectory: userHome,
                terminalSettings: _terminalSettings,
                availableShells: widget.availableShells,
                defaultShellIndex: _defaultShellIndex,
                onDefaultShellChanged: _openShellFromSelector,
                isMaximized: _isMaximized,
                onToggleMaximize: _toggleMaximize,
              ),
      ),
    );
  }
}

/// USB-HID logical keys for Ctrl+1..9 surface switching live in
/// `lib/src/shortcuts/app_shortcuts.dart` (`_digitKeys`); the
/// workspace factory reads them directly so this file doesn't need
/// its own copy.
