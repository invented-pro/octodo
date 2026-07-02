import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import '../shortcuts/app_shortcuts.dart';
import '../theme/palette_context.dart';
import '../theme/palettes.dart';
import 'terminal_view.dart';
import 'shell_profiles.dart';

// ── Surface model ────────────────────────────────────────────────────

/// A single terminal session (one shell instance).
///
/// Each [Surface] is owned by a [PaneContainer] and rendered as a
/// "tab" in that pane's section.  The same [Surface] object is never
/// shared between containers.
///
/// Extends [ChangeNotifier] so the tab bar's chip can subscribe
/// (via [ListenableBuilder]) and rebuild automatically when the
/// shell-set [title] or the OSC 7 [currentCwd] changes — without
/// the parent having to call setState on every shell output tick.
class Surface extends ChangeNotifier {
  /// Stable UUID. Survives tab reorder and cross-container moves so
  /// drag/drop payloads can identify a tab across tree mutations.
  /// Also serves as the widget key for the [TerminalView] so Flutter
  /// can track the element across rebuilds without needing a
  /// `GlobalKey` (which can collide with inherited focus scopes
  /// when the parent rebuilds — see v6.0.4 bug fix).
  final String id;
  /// Shell executable path (e.g. `C:\Program Files\PowerShell\7\pwsh.exe`).
  /// Set from the spawning [ShellProfile]; the spawn layer wraps it together
  /// with [args] in `cmd.exe /c …` — see `TerminalView._start`.
  String program = '';

  /// Arguments for [program], excluding `-NoProfile` (which the spawn layer
  /// appends itself for the PowerShell families). Mirrors `ShellProfile.args`.
  List<String> args = const [];

  /// The FocusNode the [TerminalView] uses for keyboard input. Owned
  /// by the Surface so the workspace can request focus without
  /// reaching into the view's State via a GlobalKey. Disposed when
  /// the Surface is disposed.
  final FocusNode focusNode = FocusNode(debugLabel: 'surface-focus');

  /// Stable [GlobalKey] used to preserve the [TerminalView] subtree
  /// across **container changes** — i.e. when a tab is dragged from
  /// one pane to another (or dropped onto an edge to create a new
  /// pane). The framework uses this key in the [KeyedSubtree] that
  /// wraps the view to find the existing element at its new tree
  /// position and retake it, so the [TerminalView]'s State (engine +
  /// PTY + scrollback signals) survives the move.
  ///
  /// Using `KeyedSubtree` (instead of putting the key directly on the
  /// [TerminalView]) avoids a [GlobalKey]-on-[StatefulWidget]
  /// collision that surfaces during workspace rebuilds (the IndexedStack's
  /// Visibility wrapping reassigns parent focus scopes in a way that
  /// breaks the key's uniqueness invariant).
  final GlobalKey viewKey = GlobalKey();

  /// Title set by the shell via OSC 0/2 escape sequences (e.g. ssh
  /// or opencode set it to "user@host" or "opencode ~/projects").
  /// Empty until the shell reports its own title.
  String _title = '';
  String get title => _title;
  set title(String value) {
    if (_title == value) return;
    _title = value;
    notifyListeners();
  }

  /// Set by the underlying shell process when it exits.
  bool _exited = false;
  bool get exited => _exited;
  set exited(bool value) {
    if (_exited == value) return;
    _exited = value;
    notifyListeners();
  }

  /// The shell profile this surface was spawned from. Used by the
  /// tab bar to render the shell's icon (in its accent color) and
  /// the shortName as the fallback title before the shell sets its
  /// own via OSC.
  ShellProfile? profile;

  /// Initial working directory. Used to compute the directory
  /// basename for the fallback title (e.g. `pwsh ~/projects`).
  String? initialCwd;

  /// Current working directory as reported by the shell via OSC
  /// 7/9/1337. Starts as the initial cwd and is updated whenever
  /// the shell emits a new value. Drives the fallback title when
  /// the shell-set title is empty.
  ///
  /// The OSC 7 value is the path extracted from the shell's
  /// `file://host/path` URI, which uses forward slashes per
  /// RFC 8089. We normalize Windows-style paths back to backslashes
  /// so they compare equal against the Windows-style [initialCwd]
  /// we stored at construction. POSIX paths (WSL, Git Bash) are
  /// already slash-only and pass through unchanged.
  String? _currentCwd;
  String? get currentCwd => _currentCwd;
  set currentCwd(String? value) {
    final normalized = normalizeShellCwd(value);
    if (_currentCwd == normalized) return;
    _currentCwd = normalized;
    notifyListeners();
  }

  /// `C:/Users/<user>` → `C:\Users\<user>`; POSIX paths and UNC paths pass
  /// through unchanged. Empty stays empty.
  ///
  /// `@visibleForTesting` so the unit test in `pane_tree_test.dart`
  /// (when added) can exercise the corner cases directly. The
  /// implementation is also a clean pure function, so it's safe to
  /// expose at this scope.
  @visibleForTesting
  static String? normalizeShellCwd(String? value) {
    if (value == null || value.isEmpty) return value;
    // A drive-rooted path (`X:/...`) is the unambiguous Windows-shape
    // signal: forward slashes there are URI artifacts, not POSIX.
    final drive = RegExp(r'^[A-Za-z]:');
    if (drive.hasMatch(value)) {
      return value.replaceAll('/', '\\');
    }
    return value;
  }

  Surface({String? id, this.profile, this.initialCwd})
      : id = id ?? _newId();

/// Title to display when the shell hasn't set its own yet.
/// Format: `[shortName] [basename(cwd)]`, e.g.
///   `pwsh ~`, `bash C:\Users\x\proj`.
///
/// Prefers [currentCwd] (updated by OSC 7) over the static
/// [initialCwd] so a `cd` in the shell is reflected even when the
/// shell doesn't set its own title via OSC 0/2.
///
/// If the cwd still equals [initialCwd] (the shell never `cd`'d
/// away from its start dir), render the path component as `~` to
/// match the shell-prompt shorthand the user is used to — most
/// notably WSL, where the distro starts in the user's home and
/// OSC 7 reports it as `/mnt/c/Users/<name>` instead of `~`.
///
/// When the shell's profile has `showCwdInTitle == false` (set for
/// PowerShell 7 / Windows PowerShell / CMD — see shell_profiles.dart
/// for the rationale: their OSC 7 paths are unreliable through
/// ConPTY), the title is just the shell's `shortName` — `pwsh`,
/// `powershell`, `cmd`. OSC 7 is still recorded on `_currentCwd`
/// (used by the IME caret reporting and any future cwd-aware
/// features), it just doesn't leak into the chip.
String get fallbackTitle {
  final name = profile?.shortName ?? 'shell';
  final showCwd = profile?.showCwdInTitle ?? false;
  if (!showCwd) return name;
  final cwd = _currentCwd ?? initialCwd;
  if (cwd == null || cwd.isEmpty) return name;
  if (cwd == initialCwd) return '$name ~';
  final base = p.basename(cwd);
  if (base.isEmpty) return name;
  return '$name $base';
}

  /// The full title to render in the tab chip. Tries the shell-set
  /// title first; if [_shortenTitle] reduces it to an empty string
  /// (e.g. ConPTY sent the raw process name `pwsh.exe` and the
  /// `.exe` filter stripped it), falls back to [fallbackTitle] so
  /// the chip never shows the literal "shell" placeholder.
  String get chipTitle {
    if (_title.isNotEmpty) {
      final shortened = _shortenTitle(_title);
      if (shortened.isNotEmpty) return shortened;
    }
    return fallbackTitle;
  }

  static String _newId() {
    final r = Random();
    final bytes = List<int>.generate(
        16, (_) => r.nextInt(256), growable: false);
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 's-$hex';
  }

  @override
  void dispose() {
    // Surface owns the FocusNode; the framework's TerminalView state
    // borrows it and must NOT dispose it from its own dispose().
    focusNode.dispose();
    super.dispose();
  }
}

// ── Pane tree model ──────────────────────────────────────────────────

/// Abstract base for nodes in the pane tree.
///
/// A pane layout is a binary tree: internal [PaneSplit] nodes have two
/// children; [PaneContainer] nodes are leaves that own a list of
/// [Surface]s (the tabs shown in that pane's section).
abstract class PaneNode {
  PaneNode? get focusedLeaf;
  /// True when [target] is reachable from this subtree (by `identical`).
  /// Used by the workspace to detect whether a previously-focused
  /// container is still in the tree after a mutation — the tree-level
  /// `removeSurface` can dispose a container while leaving the outer
  /// [PaneSplit] object unchanged (nested-collapse case), so an
  /// `identical(newRoot, oldRoot)` check is insufficient.
  bool containsContainer(PaneContainer target);
  void dispose();
}

/// Payload carried by a tab drag. The drag source always populates
/// all four fields; the drop target uses [targetContainerId] to find
/// the destination and [targetIndex] for the insertion point.
class SurfaceDragData {
  final String surfaceId;
  final String sourceContainerId;
  final int sourceIndex;
  // Optional target hint set by onMove; the final accept uses the
  // index the target actually wants to insert at.
  const SurfaceDragData({
    required this.surfaceId,
    required this.sourceContainerId,
    required this.sourceIndex,
  });
}

/// Which edge of a pane the user dropped a tab onto, signalling
/// "create a new split with the dragged tab on this side".
enum PaneEdge { left, right, top, bottom }

extension PaneEdgeX on PaneEdge {
  /// Split direction: left/right edges split horizontally (two
  /// columns), top/bottom edges split vertically (two rows).
  Axis get splitDirection =>
      (this == PaneEdge.left || this == PaneEdge.right)
          ? Axis.horizontal
          : Axis.vertical;

  /// True if the new pane should be on the "first" side of the
  /// split (left/top). False for right/bottom.
  bool get newContainerIsFirst =>
      (this == PaneEdge.left || this == PaneEdge.top);
}

/// Leaf node: a single pane section that owns a list of [Surface]s.
class PaneContainer extends PaneNode {
  /// Stable UUID. Survives tree mutations so drag/drop + animations
  /// can key off it.
  final String id;

  /// Stable [GlobalKey] used to preserve the pane's subtree (the
  /// [IndexedStack] and every [TerminalView] inside it) across
  /// widget-tree mutations that change the parent's runtime type —
  /// most importantly **pane split**, which swaps the parent from a
  /// single-pane Listener path to a LayoutBuilder → Stack → Positioned
  /// path. With a [ValueKey] on the [TerminalView] alone, the
  /// framework can match the element by position only and walks
  /// deactivating each layer whose type changed; a GlobalKey lets
  /// the framework FIND the existing subtree at its new position and
  /// reactivate it in place, so the TerminalView's State (and thus
  /// the engine + PTY) survives the split.
  ///
  /// The key is on the [_PaneDropOverlay] — one level above the
  /// [TerminalView] — so we don't risk the GlobalKey collision that
  /// happens when the key is directly on the [TerminalView] (the
  /// IndexedStack's Visibility wrapping reassigns parent focus scope
  /// in a way that breaks the key's uniqueness invariant).
  final GlobalKey _dropOverlayKey = GlobalKey();
  GlobalKey get dropOverlayKey => _dropOverlayKey;
  /// The surfaces (tabs) shown in this pane.  A "live" container
  /// always has at least one surface; an empty list means the
  /// container is being torn down.
  final List<Surface> surfaces = [];
  int _focusedIndex = 0;

  /// The surface currently shown in this pane. Auto-clamps to the
  /// current `surfaces` range on write — so callers can drop the
  /// post-mutation `if (focusedIndex >= length) focusedIndex = length-1`
  /// dance. Reading [focusedSurface] is still safe even if the
  /// container is briefly empty (returns `null`).
  int get focusedIndex => _focusedIndex;
  set focusedIndex(int value) {
    if (surfaces.isEmpty) {
      _focusedIndex = 0;
      return;
    }
    _focusedIndex = value.clamp(0, surfaces.length - 1);
  }

  /// The surface currently shown in this pane.
  ///
  /// Returns `null` if [focusedIndex] is out of range — which can
  /// happen transiently during tree mutations (e.g. a container
  /// collapses before [focusedIndex] is re-clamped, or a drop / move
  /// briefly leaves the index stale). Callers must handle `null`; the
  /// index is auto-clamped by [set focusedIndex] (which we expose as
  /// a clamped setter below), so the `null` return should only fire
  /// in narrow async windows during `setState` rebuilds.
  Surface? get focusedSurface {
    if (focusedIndex < 0 || focusedIndex >= surfaces.length) return null;
    return surfaces[focusedIndex];
  }

  PaneContainer({String? id}) : id = id ?? _newContainerId();

  static String _newContainerId() {
    final r = Random();
    final bytes = List<int>.generate(
        16, (_) => r.nextInt(256), growable: false);
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'c-$hex';
  }

  @override
  PaneNode? get focusedLeaf => this;

  @override
  bool containsContainer(PaneContainer target) => identical(this, target);

  @override
  void dispose() {
    for (final s in surfaces) {
      // Release the chip-side ChangeNotifier listeners (also disposes
      // the FocusNode that TerminalView borrows). The framework's
      // TerminalView state is disposed automatically when its widget
      // is removed from the tree — no manual `currentState.dispose()`
      // needed (and historically caused `setState after dispose` races).
      s.dispose();
    }
    surfaces.clear();
  }
}

/// Split node: divides area into two children along [direction].
class PaneSplit extends PaneNode {
  Axis direction; // Axis.horizontal = left/right, Axis.vertical = top/bottom
  double ratio; // 0.0..1.0 — fraction of the first child
  PaneNode first;
  PaneNode second;

  PaneSplit({
    required this.direction,
    required this.first,
    required this.second,
    this.ratio = 0.5,
  });

  @override
  PaneNode? get focusedLeaf {
    return first.focusedLeaf ?? second.focusedLeaf;
  }

  @override
  bool containsContainer(PaneContainer target) =>
      first.containsContainer(target) || second.containsContainer(target);

  @override
  void dispose() {
    first.dispose();
    second.dispose();
  }

  /// Walk the tree, calling [visit] on every [PaneContainer] leaf.
  void forEachLeaf(void Function(PaneContainer leaf) visit) {
    if (first is PaneContainer) {
      visit(first as PaneContainer);
    } else if (first is PaneSplit) {
      (first as PaneSplit).forEachLeaf(visit);
    }
    if (second is PaneContainer) {
      visit(second as PaneContainer);
    } else if (second is PaneSplit) {
      (second as PaneSplit).forEachLeaf(visit);
    }
  }

  /// Find the [PaneContainer] that contains [target].
  PaneContainer? findContainer(Surface target) {
    if (first is PaneContainer) {
      final leaf = first as PaneContainer;
      if (leaf.surfaces.contains(target)) return leaf;
    } else if (first is PaneSplit) {
      final r = (first as PaneSplit).findContainer(target);
      if (r != null) return r;
    }
    if (second is PaneContainer) {
      final leaf = second as PaneContainer;
      if (leaf.surfaces.contains(target)) return leaf;
    } else if (second is PaneSplit) {
      final r = (second as PaneSplit).findContainer(target);
      if (r != null) return r;
    }
    return null;
  }

  /// Remove [target] from the tree.
  ///
  /// Returns the new root of this subtree:
  ///   * `this`                — surface removed, container still has
  ///                             other surfaces.
  ///   * `first` or `second`   — the container that held [target] was
  ///                             collapsed (it had no other surfaces),
  ///                             so the sibling takes its place.
  ///   * `null`                — [target] was not in this subtree.
  PaneNode? removeSurface(Surface target) {
    // Check first child.
    if (first is PaneContainer) {
      final leaf = first as PaneContainer;
      if (leaf.surfaces.remove(target)) {
        if (leaf.surfaces.isEmpty) {
          leaf.dispose();
          return second;
        }
        if (leaf.focusedIndex >= leaf.surfaces.length) {
          leaf.focusedIndex = leaf.surfaces.length - 1;
        }
        return this;
      }
    } else if (first is PaneSplit) {
      final r = (first as PaneSplit).removeSurface(target);
      if (r != null) {
        if (identical(r, second)) {
          // first subtree collapsed to `second` — splice second in.
          first.dispose();
          return second;
        }
        first = r;
        return this;
      }
    }
    // Check second child.
    if (second is PaneContainer) {
      final leaf = second as PaneContainer;
      if (leaf.surfaces.remove(target)) {
        if (leaf.surfaces.isEmpty) {
          leaf.dispose();
          return first;
        }
        if (leaf.focusedIndex >= leaf.surfaces.length) {
          leaf.focusedIndex = leaf.surfaces.length - 1;
        }
        return this;
      }
    } else if (second is PaneSplit) {
      final r = (second as PaneSplit).removeSurface(target);
      if (r != null) {
        if (identical(r, first)) {
          second.dispose();
          return first;
        }
        second = r;
        return this;
      }
    }
    return null;
  }

  /// Remove the [PaneContainer] node [target] from the tree by
  /// collapsing any [PaneSplit] that has it as a child — the
  /// surviving sibling takes its place.
  ///
  /// Unlike [removeSurface], this operates on a **container
  /// reference**, not a surface lookup. Use this when you've
  /// already removed a surface from a container's `surfaces` list
  /// and need to detach the now-empty container from the tree
  /// without `removeSurface` accidentally finding the surface
  /// elsewhere (e.g. in the destination after a cross-container
  /// insert-then-remove sequence).
  ///
  /// Returns the new subtree root:
  ///   * `this`              — [target] was somewhere in the
  ///                           subtree, and we've spliced the
  ///                           surviving sibling in its place.
  ///   * `first` or `second` — the **immediate parent** of [target]
  ///                           was this node; the other child is
  ///                           returned so the caller can splice it
  ///                           into the grandparent.
  ///   * `null`              — [target] is not in this subtree.
  PaneNode? removeContainer(PaneContainer target) {
    if (identical(first, target)) {
      first.dispose();
      return second;
    }
    if (identical(second, target)) {
      second.dispose();
      return first;
    }
    if (first is PaneSplit) {
      final r = (first as PaneSplit).removeContainer(target);
      if (r != null) {
        if (identical(r, second)) {
          // first subtree collapsed to `second` — splice second in.
          first.dispose();
          return second;
        }
        first = r;
        return this;
      }
    }
    if (second is PaneSplit) {
      final r = (second as PaneSplit).removeContainer(target);
      if (r != null) {
        if (identical(r, first)) {
          second.dispose();
          return first;
        }
        second = r;
        return this;
      }
    }
    return null;
  }

  /// Replace [target] in the tree with a new [PaneSplit] wrapping
  /// [newContainer] and [target]. [direction] and [isFirst] decide
  /// which side [newContainer] lands on.
  ///
  /// Returns the new subtree root:
  ///   * A new [PaneSplit] — if [target] was the immediate child of
  ///                         `this`; the original [PaneSplit] is
  ///                         mutated in place.
  ///   * `this`             — [target] was deeper in the tree; we
  ///                         recursed and mutated in place.
  ///   * `null`             — [target] is not in this subtree.
  PaneNode? replaceContainerWithSplit(
    PaneContainer target,
    PaneContainer newContainer,
    Axis direction,
    bool isFirst, {
    double ratio = 0.5,
  }) {
    if (identical(first, target)) {
      first = PaneSplit(
        direction: direction,
        first: isFirst ? newContainer : target,
        second: isFirst ? target : newContainer,
        ratio: ratio,
      );
      return this;
    }
    if (identical(second, target)) {
      second = PaneSplit(
        direction: direction,
        first: isFirst ? newContainer : target,
        second: isFirst ? target : newContainer,
        ratio: ratio,
      );
      return this;
    }
    if (first is PaneSplit) {
      final r = (first as PaneSplit).replaceContainerWithSplit(
        target,
        newContainer,
        direction,
        isFirst,
        ratio: ratio,
      );
      if (r != null) return this;
    }
    if (second is PaneSplit) {
      final r = (second as PaneSplit).replaceContainerWithSplit(
        target,
        newContainer,
        direction,
        isFirst,
        ratio: ratio,
      );
      if (r != null) return this;
    }
    return null;
  }
}

// ── Pane layout widget ───────────────────────────────────────────────

/// Visual layout for a [PaneNode] tree (each split section has its
/// own horizontal tab bar).
///
/// The root is always a [PaneContainer] (single pane) or a
/// [PaneSplit] (multiple panes).  Each [PaneContainer] renders a
/// horizontal tab bar over an [IndexedStack] of its [Surface]s so
/// scrollback is preserved across tab switches.
class PaneLayout extends StatelessWidget {
  final PaneNode root;
  final PaneContainer? focusedContainer;
  final void Function(PaneContainer container) onFocusContainer;
  final void Function(PaneContainer container, Surface surface)
      onFocusSurface;
  final void Function(PaneContainer container) onNewSurface;
  final void Function(PaneContainer container, Surface surface)
      onCloseSurface;
  final void Function(
          PaneContainer container, Surface surface, Axis direction)
      onSplit;
  final void Function(PaneSplit parent, double newRatio) onResize;

  /// Called when a tab is reordered within the same container.
  /// [oldIndex] and [newIndex] are indices into [container.surfaces]
  /// BEFORE the move; the implementation should clamp/adjust as
  /// needed (matching Flutter's [ReorderableListView] semantics:
  /// if [newIndex] > [oldIndex] it decrements by 1 after removal).
  final void Function(PaneContainer container, int oldIndex, int newIndex)
      onReorderSurface;

  /// Called when a tab is dragged from one container to another.
  /// [targetIndex] is the insertion position inside [toContainer];
  /// if [toContainer] is the same as the source the function will
  /// not be invoked (use [onReorderSurface] instead).
  final void Function(
    SurfaceDragData drag,
    PaneContainer toContainer,
    int targetIndex,
  ) onMoveSurfaceBetweenContainers;

  /// Called when a tab is dropped onto one of the four edges of
  /// [targetContainer]. The pane at [targetContainer] is replaced
  /// in the tree by a split with the dragged tab in a new container
  /// on the indicated [edge].
  final void Function(
    SurfaceDragData drag,
    PaneContainer targetContainer,
    PaneEdge edge,
  ) onDropToSplitEdge;

  /// True while a tab drag is in flight anywhere in this workspace
  /// (any pane). The four edge drop zones of each pane are only
  /// rendered while this is true — otherwise their always-present
  /// translucent `DragTarget` `MetaData` interferes with the
  /// terminal's cursor + text selection at the outer ~25% of every
  /// pane (the `_EdgeSplitZone` band).
  final ValueListenable<bool> isAnyTabDragActive;

  /// Notified when a tab drag starts (`true`) or ends (`false`).
  /// The workspace feeds this into [isAnyTabDragActive].
  final ValueChanged<bool> onAnyDragActiveChanged;

  /// Working directory passed to each [TerminalView] (typically user home).
  final String workingDirectory;

  /// Snapshot of every user-facing terminal setting (font, cursor,
  /// scrollback, bell, copy-on-select). Workspace rebuilds this whenever
  /// any setting changes; `TerminalView.didUpdateWidget` re-applies via
  /// `_engine.reconfigure(_buildConfig())` so changes are live without
  /// re-spawning the shell.
  final TerminalSettings terminalSettings;

  /// Available shell profiles for the new-tab/shell-selector menu.
  final List<ShellProfile> availableShells;
  final int defaultShellIndex;
  final void Function(int) onDefaultShellChanged;

  /// When true, render the [focusedContainer] full-window in front and
/// keep every non-focused container mounted invisibly behind it. The
/// pane tree is left unchanged — toggling this flag back to false
/// restores the original layout. Every pane's widget subtree (and
/// therefore the [TerminalView] State, engine, PTY, scrollback) stays
/// alive across maximize/restore because we never remove a subtree
/// from the tree.
  final bool isMaximized;
  final VoidCallback? onToggleMaximize;

  const PaneLayout({
    super.key,
    required this.root,
    required this.focusedContainer,
    required this.onFocusContainer,
    required this.onFocusSurface,
    required this.onNewSurface,
    required this.onCloseSurface,
    required this.onSplit,
    required this.onResize,
    required this.onReorderSurface,
    required this.onMoveSurfaceBetweenContainers,
    required this.onDropToSplitEdge,
    required this.workingDirectory,
    required this.terminalSettings,
    required this.availableShells,
    required this.defaultShellIndex,
    required this.onDefaultShellChanged,
    required this.isAnyTabDragActive,
    required this.onAnyDragActiveChanged,
    this.isMaximized = false,
    this.onToggleMaximize,
  });

  @override
  Widget build(BuildContext context) {
    // When maximized, render the full tree (so every pane's widget
    // subtree stays alive across maximize/restore) and overlay the
    // focused container on top via a Stack. The hidden tree uses
    // `Offstage` so non-focused containers are laid out (keeping
    // their elements mounted) but never painted and never receive
    // input.
    //
    // The outer `SizedBox.expand` is critical: without it the Stack
    // sizes itself from its non-positioned children, and the hidden
    // tree returns `SizedBox.shrink()` for the single-pane case
    // (focused == root), making the Stack 0×0 and the focused overlay
    // get 0×0 constraints — which then crashes the `clamp(40.0, w/2)`
    // inside `_PaneDropOverlay` when `w == 0`. Forcing the Stack to
    // fill its parent keeps both the hidden tree and the focused
    // overlay at the full window size.
    if (isMaximized && focusedContainer != null) {
      return SizedBox.expand(
        child: Stack(
          children: [
            Positioned.fill(
              child: Offstage(
                child: _buildHiddenTree(context, root, focusedContainer!),
              ),
            ),
            Positioned.fill(
              child: _buildContainer(context, focusedContainer!),
            ),
          ],
        ),
      );
    }
    return _buildNode(context, root);
  }

  /// Build the full tree but skip the focused container (it's
  /// rendered separately as the visible overlay above). Every other
  /// container is laid out + mounted normally — just not painted.
  Widget _buildHiddenTree(
      BuildContext context, PaneNode node, PaneContainer focused) {
    if (node is PaneContainer) {
      if (identical(node, focused)) {
        return const SizedBox.shrink();
      }
      return _buildContainer(context, node);
    }
    if (node is PaneSplit) {
      // Walk the split tree; recursively skip the focused subtree.
      final first = identical(node.first, focused)
          ? const SizedBox.shrink()
          : _buildHiddenTree(context, node.first, focused);
      final second = identical(node.second, focused)
          ? const SizedBox.shrink()
          : _buildHiddenTree(context, node.second, focused);
      return _buildSplitWithChildren(context, node, first, second);
    }
    return const SizedBox.shrink();
  }

  Widget _buildNode(BuildContext context, PaneNode node) {
    if (node is PaneContainer) return _buildContainer(context, node);
    if (node is PaneSplit) return _buildSplit(context, node);
    return const SizedBox.shrink();
  }

Widget _buildContainer(BuildContext context, PaneContainer container) {
    assert(container.surfaces.isNotEmpty,
        'PaneContainer ${container.id} rendered with no surfaces — tree mutation left an empty container in place.');
    final palette = context.palette;
    final isFocused = focusedContainer == container;
    // `_PaneDropOverlay` carries a GlobalKey (per-container) so the
    // entire subtree (IndexedStack + TerminalView) is preserved across
    // pane-tree mutations that change the parent's runtime type
    // (notably the single-pane → split transition: Listener → LayoutBuilder
    // → Stack → Positioned). Without the GlobalKey the framework can
    // only match by position, and every layer whose type changes gets
    // deactivated — taking the TerminalView's State with it and
    // wiping the shell. See `PaneContainer.dropOverlayKey`.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onFocusContainer(container),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: isFocused
                ? palette.accentBlue
                : palette.outline,
            width: 1,
          ),
        ),
        child: Column(
          children: [
            _ContainerTabBar(
              container: container,
              isFocused: isFocused,
              isMaximized: isMaximized,
              availableShells: availableShells,
              defaultShellIndex: defaultShellIndex,
              onFocusSurface: (s) => onFocusSurface(container, s),
              onNewSurface: () => onNewSurface(container),
              onCloseSurface: (s) => onCloseSurface(container, s),
              onSplit: (s, dir) => onSplit(container, s, dir),
              onDefaultShellChanged: onDefaultShellChanged,
              onToggleMaximize: onToggleMaximize,
              onReorderSurface: (oldIndex, newIndex) =>
                  onReorderSurface(container, oldIndex, newIndex),
              onMoveSurfaceBetweenContainers:
                  (drag, targetIndex) => onMoveSurfaceBetweenContainers(
                drag,
                container,
                targetIndex,
              ),
              isAnyTabDragActive: isAnyTabDragActive,
              onAnyDragActiveChanged: onAnyDragActiveChanged,
            ),
            Expanded(
              child: _PaneDropOverlay(
                key: container.dropOverlayKey,
                container: container,
                onMoveSurfaceBetweenContainers:
                    onMoveSurfaceBetweenContainers,
                onDropToSplitEdge: onDropToSplitEdge,
                isAnyTabDragActive: isAnyTabDragActive,
                child: IndexedStack(
                  index: container.focusedIndex
                      .clamp(0, container.surfaces.length - 1),
                  children: [
                    for (final surface in container.surfaces)
                      // Wrap the TerminalView in a KeyedSubtree carrying
                      // a stable GlobalKey tied to the Surface. When a
                      // tab is dragged between containers (or dropped on
                      // an edge to create a new pane), the framework's
                      // `updateChildren` rejects the canUpdate path
                      // because IndexedStack rebuilds the Visibility
                      // wrapper with a different child slot; the new
                      // KeyedSubtree's GlobalKey then routes through
                      // `_retakeInactiveElement` and pulls the old
                      // subtree (IndexedStack → Visibility →
                      // KeyedSubtree → TerminalView + State + engine +
                      // PTY) into the new container — preserving the
                      // shell content.
                      KeyedSubtree(
                        key: surface.viewKey,
                        child: TerminalView(
                          // Keep a local ValueKey on the TerminalView
                          // itself for normal rebuild matching within
                          // the same container — GlobalKey on a
                          // StatefulWidget can collide during
                          // settings-driven rebuilds (see Surface
                          // viewKey comment).
                          key: ValueKey<String>(surface.id),
                          surface: surface,
                          workingDirectory: workingDirectory,
                          settings: terminalSettings,
                          onTitleChanged: (title) {
                            surface.title = title;
                          },
                          onPwdChanged: (pwd) {
                            // OSC 7/9/1337 — update the tracked cwd so
                            // the fallback title (and chip) reflect the
                            // new directory even when the shell doesn't
                            // set its own OSC 0/2 title.
                            surface.currentCwd = pwd.isEmpty ? null : pwd;
                          },
                          onExited: () {
                            surface.exited = true;
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplit(BuildContext context, PaneSplit split) {
    return _buildSplitWithChildren(
      context,
      split,
      _buildNode(context, split.first),
      _buildNode(context, split.second),
    );
  }

  /// Build a [PaneSplit] with pre-resolved first/second pane children.
  /// Used both by [_buildSplit] (which calls [_buildNode] for each side)
  /// and by [_buildHiddenTree] (which substitutes a [SizedBox.shrink]
  /// for the focused subtree during maximize).
  Widget _buildSplitWithChildren(
    BuildContext context,
    PaneSplit split,
    Widget first,
    Widget second,
  ) {
    final isHorizontal = split.direction == Axis.horizontal;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalSize =
            isHorizontal ? constraints.maxWidth : constraints.maxHeight;
        final firstSize = totalSize * split.ratio;
        final secondSize = totalSize - firstSize;

        final divider = _Divider(
          isHorizontal: isHorizontal,
          onDrag: (delta, _) {
            final newRatio =
                (split.ratio + delta / totalSize).clamp(0.1, 0.9);
            onResize(split, newRatio.toDouble());
          },
        );

        // Stack + Positioned so the two panes sit flush against each
        // other (no gutter). The divider is a zero-width widget whose
        // hit area is a Positioned rectangle straddling the boundary.
        if (isHorizontal) {
          return Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: firstSize,
                height: constraints.maxHeight,
                child: first,
              ),
              Positioned(
                left: firstSize,
                top: 0,
                width: secondSize,
                height: constraints.maxHeight,
                child: second,
              ),
              Positioned(
                left: firstSize - _Divider.hitSize / 2,
                top: 0,
                width: _Divider.hitSize,
                height: constraints.maxHeight,
                child: divider,
              ),
            ],
          );
        }
        return Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: constraints.maxWidth,
              height: firstSize,
              child: first,
            ),
            Positioned(
              left: 0,
              top: firstSize,
              width: constraints.maxWidth,
              height: secondSize,
              child: second,
            ),
            Positioned(
              left: 0,
              top: firstSize - _Divider.hitSize / 2,
              width: constraints.maxWidth,
              height: _Divider.hitSize,
              child: divider,
            ),
          ],
        );
      },
    );
  }
}

// ── Per-container tab bar ────────────────────────────────────────────

class _ContainerTabBar extends StatefulWidget {
  final PaneContainer container;
  final bool isFocused;
  final bool isMaximized;
  final List<ShellProfile> availableShells;
  final int defaultShellIndex;
  final void Function(Surface) onFocusSurface;
  final VoidCallback onNewSurface;
  final void Function(Surface) onCloseSurface;
  final void Function(Surface, Axis) onSplit;
  final void Function(int) onDefaultShellChanged;
  final VoidCallback? onToggleMaximize;

  /// Same-container reorder: indexes refer to [container.surfaces]
  /// BEFORE removal (matches Flutter's ReorderableListView contract).
  final void Function(int oldIndex, int newIndex) onReorderSurface;

  /// Cross-container move: drop a tab from elsewhere into this
  /// container at [targetIndex].
  final void Function(SurfaceDragData drag, int targetIndex)
      onMoveSurfaceBetweenContainers;

  /// Workspace-level "any tab drag active" listenable. The chip's
  /// insertion-line + end-zone highlight also rebuild against this so
  /// a drag from any pane visually ripples everywhere.
  final ValueListenable<bool> isAnyTabDragActive;

  /// Called when this container starts/ends a local tab drag.
  /// The workspace feeds it into [isAnyTabDragActive].
  final ValueChanged<bool> onAnyDragActiveChanged;

  const _ContainerTabBar({
    required this.container,
    required this.isFocused,
    required this.isMaximized,
    required this.availableShells,
    required this.defaultShellIndex,
    required this.onFocusSurface,
    required this.onNewSurface,
    required this.onCloseSurface,
    required this.onSplit,
    required this.onDefaultShellChanged,
    required this.onReorderSurface,
    required this.onMoveSurfaceBetweenContainers,
    required this.isAnyTabDragActive,
    required this.onAnyDragActiveChanged,
    this.onToggleMaximize,
  });

  @override
  State<_ContainerTabBar> createState() => _ContainerTabBarState();
}

class _ContainerTabBarState extends State<_ContainerTabBar> {
  /// Controls the horizontal scroll of the tab list. Owned by the
  /// state so wheel events can advance it manually (Flutter's
  /// default horizontal [ListView] does not respond to vertical
  /// wheel deltas, which is the only kind a regular mouse emits).
  final ScrollController _scrollController = ScrollController();

  /// Key on the [ListView] so [_maybeAutoScroll] can read its
  /// visible viewport width when comparing a clicked chip's
  /// position to the visible area.
  final GlobalKey _listViewKey = GlobalKey();

  /// Surface count from the previous build. Used in [didUpdateWidget]
  /// to detect when a new tab was added and animate the scroll to
  /// reveal it. New tabs are always appended at the end of
  /// [widget.container.surfaces], so scrolling to
  /// `maxScrollExtent` brings the new chip into view.
  int _lastSurfaceCount = 0;

  /// Track which chip the pointer is hovering and on which side.
  /// `null` = no hover. Otherwise: `(_index, _after)` where _after
  /// means "insert after index" (i.e., the line shows to the right).
  int? _hoverIndex;
  bool _hoverAfter = false;
  bool _endZoneHover = false;

  @override
  void initState() {
    super.initState();
    _lastSurfaceCount = widget.container.surfaces.length;
  }

  @override
  void didUpdateWidget(covariant _ContainerTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newCount = widget.container.surfaces.length;
    if (newCount > _lastSurfaceCount) {
      // A new tab was added (new-tab button, split, or surface
      // moved in from another container). The new chip is always
      // appended at the end of the list, so scroll to the end to
      // reveal it. Defer to post-frame so the ListView has its
      // new size + max scroll extent computed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
    _lastSurfaceCount = newCount;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _setHover(int? index, bool after) {
    if (_hoverIndex == index && _hoverAfter == after) return;
    setState(() {
      _hoverIndex = index;
      _hoverAfter = after;
    });
  }

  void _setEndZoneHover(bool v) {
    if (_endZoneHover == v) return;
    setState(() => _endZoneHover = v);
  }

  /// Convert a vertical mouse-wheel delta into horizontal scroll on
  /// [_scrollController]. Shift+wheel uses a faster step; a flat
  /// trackpad scroll emits `scrollDelta.dy` too. One notch on a
  /// standard mouse wheel is ~100 logical pixels; we divide by 4
  /// to keep the motion comfortable for a 30px-tall bar.
  void _handlePointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.maxScrollExtent <= 0) return; // nothing to scroll
    final step = signal.scrollDelta.dy;
    if (step == 0) return;
    // Negative deltas (wheel up) → scroll left; positive → right.
    final target = (_scrollController.offset + step / 4)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _scrollController.jumpTo(target);
  }

  /// When the user clicks a chip at the visible edge of the tab bar,
  /// page the scroll in that direction to reveal the next/previous
  /// batch of hidden chips. Mirrors the "click an edge tab to
  /// scroll" behavior of IDE tab bars that overflow.
  ///
  /// Scale: ~85% of the viewport width per click. This is large
  /// enough to reveal a meaningful batch of hidden tabs in one
  /// motion (typically 3-5 chips, depending on chip width), but
  /// small enough that the clicked chip remains visible at the
  /// opposite edge so the user doesn't lose context.
  ///
  /// No-op if the clicked chip is in the interior of the visible
  /// range, or if there's nothing to scroll on that side.
  void _maybeAutoScroll(BuildContext chipContext, int index) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.maxScrollExtent <= 0) return; // everything fits

    final chipBox = chipContext.findRenderObject();
    final listViewContext = _listViewKey.currentContext;
    final listViewBox = listViewContext?.findRenderObject();
    if (chipBox is! RenderBox || listViewBox is! RenderBox) return;

    // Both `localToGlobal(Offset.zero)` values include any scroll
    // offset applied by the [Scrollable]; their difference is the
    // chip's on-screen offset within the ListView's viewport.
    final chipLeft =
        chipBox.localToGlobal(Offset.zero).dx -
            listViewBox.localToGlobal(Offset.zero).dx;
    final chipWidth = chipBox.size.width;
    final listViewWidth = listViewBox.size.width;

    const edgeThreshold = 8.0; // px of slack at each edge
    const pageFraction = 0.85; // scroll ~85% of viewport per click

    // Chip sits at the LEFT edge AND there's content hidden on the
    // left → page left to reveal the previous batch of tabs.
    if (chipLeft <= edgeThreshold &&
        _scrollController.offset > pos.minScrollExtent) {
      // Scroll left by ~85% of viewport, leaving the clicked chip
      // near the right edge of the new viewport.
      final delta = -(listViewWidth - chipWidth) * pageFraction;
      final target = (_scrollController.offset + delta)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }

    // Chip sits at the RIGHT edge AND there's content hidden on
    // the right → page right to reveal the next batch of tabs.
    if (chipLeft + chipWidth >= listViewWidth - edgeThreshold &&
        _scrollController.offset < pos.maxScrollExtent) {
      final delta = (listViewWidth - chipWidth) * pageFraction;
      final target = (_scrollController.offset + delta)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final c = widget.container;
    final anyDrag = widget.isAnyTabDragActive.value;
    final children = <Widget>[];

    for (var i = 0; i < c.surfaces.length; i++) {
      final surface = c.surfaces[i];
      final isActive = i == c.focusedIndex;
      // Show the insertion indicator on whichever side of this chip
      // the pointer is over (only when some tab is being dragged —
      // local or from another pane).
      final showBefore = _hoverIndex == i && !_hoverAfter && anyDrag;
      final showAfter = _hoverIndex == i && _hoverAfter && anyDrag;

      children.add(_DraggableChip(
        key: ValueKey('chip-${surface.id}'),
        surface: surface,
        isActive: isActive,
        containerId: c.id,
        indexInContainer: i,
        onTap: (chipContext) {
          widget.onFocusSurface(surface);
          _maybeAutoScroll(chipContext, i);
        },
        onClose: () => widget.onCloseSurface(surface),
        onLocalDragChanged: widget.onAnyDragActiveChanged,
        onHoverChanged: (after) => _setHover(i, after),
        onReorderInContainer: (oldIndex, newIndex) =>
            widget.onReorderSurface(oldIndex, newIndex),
        onAcceptForeign: (drag, after) {
          _setHover(i, after);
          widget.onMoveSurfaceBetweenContainers(
              drag, after ? i + 1 : i);
        },
        showInsertBefore: showBefore,
        showInsertAfter: showAfter,
      ));
    }

    // End-of-list drop zone (between last chip and the controls).
    children.add(_EndDropZone(
      width: 24,
      hovered: _endZoneHover && anyDrag,
      onHoverChanged: _setEndZoneHover,
      onAccept: (drag) {
        if (drag.sourceContainerId == c.id) {
          // Same-container reorder, append to end.
          // Flutter convention: if oldIndex == newIndex → no-op.
          if (drag.sourceIndex == c.surfaces.length) return;
          widget.onReorderSurface(drag.sourceIndex, c.surfaces.length);
        } else {
          widget.onMoveSurfaceBetweenContainers(
              drag, c.surfaces.length);
        }
      },
    ));

    return Container(
      height: 30,
      color: palette.surface2,
      child: Row(
        children: [
          Expanded(
            child: Listener(
              // Capture wheel events before the inner ListView's
              // ClampingScrollPhysics decides to ignore them (the
              // default physics on a horizontal list does not
              // translate vertical wheel deltas into horizontal
              // scroll, so a regular mouse wheel is a no-op without
              // this hook).
              onPointerSignal: _handlePointerSignal,
              child: ListView(
                key: _listViewKey,
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.zero,
                children: children,
              ),
            ),
          ),
          // Visual separator between the tab strip and the action
          // buttons (new tab / shell picker / split / maximize).
          // 1px wide + a small inset so it doesn't touch the
          // tab strip's right edge or the first button's left edge,
          // giving the action group its own "this is the toolbar"
          // visual identity. Color matches the inactive-chip text
          // dim (`grey.shade800`) — visible but not loud.
          Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: palette.outline,
          ),
          _buildControls(palette),
        ],
      ),
    );
  }

  Widget _buildControls(ThemePalette palette) {
    final iconColor = palette.brightness == Brightness.dark
        ? palette.textMuted
        : palette.textBody;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.add, size: 16),
          color: iconColor,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          tooltip: 'New Tab (${describe(LogicalKeyboardKey.keyT, shift: true)})',
          onPressed: widget.onNewSurface,
        ),
        PopupMenuButton<int>(
          icon: const Icon(Icons.arrow_drop_down, size: 16),
          iconColor: iconColor,
          color: palette.popupSurface,
          tooltip: 'Open new tab with shell…',
          padding: EdgeInsets.zero,
          onSelected: widget.onDefaultShellChanged,
          itemBuilder: (context) => [
            for (var i = 0; i < widget.availableShells.length; i++)
              PopupMenuItem<int>(
                value: i,
                child: Row(
                  children: [
                    _ShellIcon(
                      iconData: widget.availableShells[i].icon,
                      iconAsset: widget.availableShells[i].iconAsset,
                      color: widget.availableShells[i].color,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(widget.availableShells[i].label,
                        style: const TextStyle(fontSize: 13)),
                    if (i == widget.defaultShellIndex) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check,
                          size: 14, color: palette.accentBlue),
                    ],
                  ],
                ),
              ),
          ],
        ),
        Container(
          width: 1,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          color: palette.rowSurface,
        ),
        if (!widget.isMaximized) ...[
          IconButton(
            icon: Transform.rotate(
              angle: 1.5708, // 90° CW — turns splitscreen (horizontal divider)
              child: const Icon(Icons.splitscreen, size: 18), // into a left/right split
            ),
            color: iconColor,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            tooltip: 'Split Right (${describe(LogicalKeyboardKey.keyD, shift: true)})',
            onPressed: () => widget.onSplit(
                widget.container.surfaces[widget.container.focusedIndex],
                Axis.horizontal),
          ),
          IconButton(
            icon: const Icon(Icons.splitscreen, size: 18),
            color: iconColor,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            tooltip: 'Split Down (${describe(LogicalKeyboardKey.keyE, shift: true)})',
            onPressed: () => widget.onSplit(
                widget.container.surfaces[widget.container.focusedIndex],
                Axis.vertical),
          ),
        ],
        IconButton(
          icon: Icon(
            widget.isMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
            size: 20,
          ),
          color: iconColor,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          tooltip: widget.isMaximized
              ? 'Restore Layout (${describe(LogicalKeyboardKey.keyM, shift: true)})'
              : 'Maximize Pane — ${describe(LogicalKeyboardKey.keyM, shift: true)}',
          onPressed: widget.onToggleMaximize,
        ),
        const SizedBox(width: 2),
      ],
    );
  }
}

// ── Surface chip (tab) with drag/drop ───────────────────────────────

/// A single tab chip wrapped in a [LongPressDraggable] (so a quick
/// tap still focuses the tab) and a [DragTarget] (so other chips can
/// be dropped onto either side of this one).
///
/// On hover, the chip divides its hit area in half: dropping on the
/// left half means "insert before me", on the right half means
/// "insert after me".
class _DraggableChip extends StatelessWidget {
  final Surface surface;
  final bool isActive;
  final String containerId;
  final int indexInContainer;
  /// Called when the user taps the chip. Receives the chip's
  /// [BuildContext] so the parent can locate the chip's
  /// [RenderBox] (used by the edge-click auto-scroll).
  final void Function(BuildContext) onTap;
  final VoidCallback onClose;
  final ValueChanged<bool> onLocalDragChanged;
  final ValueChanged<bool> onHoverChanged;
  final void Function(int oldIndex, int newIndex) onReorderInContainer;
  final void Function(SurfaceDragData drag, bool after) onAcceptForeign;
  final bool showInsertBefore;
  final bool showInsertAfter;

  const _DraggableChip({
    super.key,
    required this.surface,
    required this.isActive,
    required this.containerId,
    required this.indexInContainer,
    required this.onTap,
    required this.onClose,
    required this.onLocalDragChanged,
    required this.onHoverChanged,
    required this.onReorderInContainer,
    required this.onAcceptForeign,
    required this.showInsertBefore,
    required this.showInsertAfter,
  });

  SurfaceDragData get _dragData => SurfaceDragData(
        surfaceId: surface.id,
        sourceContainerId: containerId,
        sourceIndex: indexInContainer,
      );

  @override
  Widget build(BuildContext context) {
    // Subscribe to the surface's ChangeNotifier so the chip
    // rebuilds automatically when the shell-set title (OSC 0/2),
    // the OSC 7 cwd, or the exited flag changes. Without this, a
    // `cd` in WSL/bash would update `surface.title`/`currentCwd`
    // but the chip would only redraw on the next unrelated
    // setState (e.g. a tab-bar hover) — clicking another tab.
    return ListenableBuilder(
      listenable: surface,
      builder: (context, _) => _buildChip(context),
    );
  }

  Widget _buildChip(BuildContext context) {
    final palette = context.palette;
    // `chipTitle` handles the full chain: prefer the shell-set
    // title, fall back to the derived `[shortName] [basename(cwd)]`
    // when OSC hasn't reported yet, and fall back again when the
    // shell-set title is something unhelpful like `pwsh.exe` (which
    // the `_shortenTitle` `.exe` filter would reduce to empty).
    final title = surface.chipTitle;
    final profile = surface.profile;
    final chip = _ChipVisual(
      title: title,
      icon: profile?.icon,
      iconAsset: profile?.iconAsset,
      iconColor: profile?.color,
      isActive: isActive,
      exited: surface.exited,
      onTap: () => onTap(context),
      onClose: onClose,
    );

    // childWhenDragging: hollow outline at the original position so
    // the layout doesn't shift while the chip floats under the cursor.
    final placeholder = SizedBox(
      width: 100, // visual; ListView clips to actual chip width anyway
      height: 30,
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface1.withValues(alpha: 0.4),
          border: Border.all(
            color: palette.accentBlue.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
      ),
    );

    // feedback: floating ghost with elevation, follows the pointer.
    final feedback = Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Container(
          padding: const EdgeInsets.only(left: 10, right: 4),
          height: 30,
          decoration: BoxDecoration(
            color: palette.surface1,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: palette.accentBlue,
              width: 1,
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
            mainAxisSize: MainAxisSize.min,
            children: [
              if (profile != null) ...[
                _ShellIcon(
                  iconData: profile.icon,
                  iconAsset: profile.iconAsset,
                  color: profile.color,
                  size: 12,
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isActive ? palette.textPrimary : palette.textBody,
                    fontSize: 12,
                    decoration: surface.exited
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 2),
              Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close,
                    size: 12, color: palette.textMuted),
              ),
            ],
          ),
        ),
      ),
    );

    return LongPressDraggable<SurfaceDragData>(
      data: _dragData,
      delay: const Duration(milliseconds: 250),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: placeholder,
      onDragStarted: () => onLocalDragChanged(true),
      onDraggableCanceled: (_, _) => onLocalDragChanged(false),
      onDragCompleted: () => onLocalDragChanged(false),
      child: DragTarget<SurfaceDragData>(
        onWillAcceptWithDetails: (details) {
          // Reject drops onto the same chip at the same position —
          // that's a no-op and would just cause a flicker.
          final d = details.data;
          if (d.sourceContainerId == containerId &&
              d.sourceIndex == indexInContainer) {
            return false;
          }
          return true;
        },
        onMove: (details) {
          // Decide left vs right of this chip based on pointer X
          // relative to the chip's center.
          final renderObject = context.findRenderObject();
          if (renderObject is! RenderBox) return;
          final local = renderObject.globalToLocal(details.offset);
          onHoverChanged(local.dx > renderObject.size.width / 2);
        },
        onLeave: (_) => onHoverChanged(false),
        onAcceptWithDetails: (details) {
          final renderObject = context.findRenderObject();
          if (renderObject is! RenderBox) {
            onAcceptForeign(details.data, true);
            return;
          }
          final local = renderObject.globalToLocal(details.offset);
          final after = local.dx > renderObject.size.width / 2;
          final d = details.data;
          if (d.sourceContainerId == containerId) {
            // Same-container reorder.
            // Flutter's ReorderableListView convention: newIndex is
            // the position AFTER removal, so if newIndex > oldIndex
            // the caller should treat it as the "after" slot minus 1.
            final oldIndex = d.sourceIndex;
            var newIndex = after ? indexInContainer + 1 : indexInContainer;
            if (newIndex > oldIndex) newIndex -= 1;
            if (oldIndex == newIndex) return; // no-op
            onReorderInContainer(oldIndex, newIndex);
          } else {
            onAcceptForeign(d, after);
          }
        },
        builder: (context, candidate, rejected) {
          // Stack the insertion line on top of the chip.
          return Stack(
            clipBehavior: Clip.none,
            children: [
              chip,
              // Insertion indicator BEFORE the chip.
              if (showInsertBefore)
                const Positioned(
                  left: -1,
                  top: 0,
                  bottom: 0,
                  child: _InsertionLine(),
                ),
              // Insertion indicator AFTER the chip.
              if (showInsertAfter)
                const Positioned(
                  right: -1,
                  top: 0,
                  bottom: 0,
                  child: _InsertionLine(),
                ),
              // Soft highlight when something is hovering anywhere on
              // the chip's drop zone.
              if (candidate.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: palette.accentBlue.withValues(alpha: 0.06),
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

/// Pure visual chip — extracted so [_DraggableChip] can swap it for
/// a placeholder during drag without rebuilding the gesture tree.
///
/// Stateful because the hover background tint + auto-hide of the
/// close button need a hover listener with setState.
class _ChipVisual extends StatefulWidget {
  final String title;
  final IconData? icon;
  final String? iconAsset;
  final Color? iconColor;
  final bool isActive;
  final bool exited;
  final VoidCallback onTap;
  final VoidCallback onClose;
  const _ChipVisual({
    required this.title,
    required this.isActive,
    required this.exited,
    required this.onTap,
    required this.onClose,
    this.icon,
    this.iconAsset,
    this.iconColor,
  });

  @override
  State<_ChipVisual> createState() => _ChipVisualState();
}

class _ChipVisualState extends State<_ChipVisual> {
  /// True while the pointer is over the chip. Drives:
  ///   * the hover background tint (intermediate between inactive
  ///     and active — gives a clear "this is a clickable tab" cue
  ///     even when the chip is unfocused),
  ///   * the visibility of the close button (auto-hides on inactive
  ///     tabs to keep the bar tidy; shows on hover OR active).
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isActive = widget.isActive;
    final exited = widget.exited;
    final showClose = isActive || _hovered;
    final Color bg;
    if (isActive) {
      bg = palette.surface1;
    } else if (_hovered) {
      bg = palette.accentBlue.withValues(alpha: 0.24);
    } else {
      bg = Colors.transparent;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          // Fixed width (rather than `MainAxisSize.min` + maxWidth)
          // so the close button can be right-aligned to the chip's
          // edge via `MainAxisAlignment.spaceBetween`. Title text
          // ellipsizes when overflowed; close button stays pinned
          // to the right edge of the chip.
          width: 160,
          height: 30,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              bottom: BorderSide(
                color: isActive ? palette.accentBlue : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Left: icon + title (truncated). The Expanded lets
              // the title ellipsize instead of pushing the close
              // button off-screen.
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null || widget.iconAsset != null) ...[
                      _ShellIcon(
                        iconData: widget.icon,
                        iconAsset: widget.iconAsset,
                        color: widget.iconColor ?? palette.textMuted,
                        size: 12,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          color: isActive
                              ? palette.textPrimary
                              : (exited ? palette.textMuted : palette.textBody),
                          fontSize: 12,
                          decoration: exited
                              ? TextDecoration.lineThrough
                              : null,
                          height: 1.2,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
              // Right: close button, auto-hides on inactive tabs.
              // AnimatedOpacity gives a smooth 120ms fade-in / out
              // instead of a jarring pop when hovering the bar.
              AnimatedOpacity(
                opacity: showClose ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 120),
                child: IgnorePointer(
                  ignoring: !showClose,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onClose,
                      child: Container(
                        // Hit area is a bit larger than the icon so
                        // the close button is easy to click even at
                        // 12px icon size.
                        padding: const EdgeInsets.all(3),
                        child: Icon(
                          Icons.close,
                          size: 12,
                          color: isActive
                              ? palette.textOverlay
                              : palette.textMuted,
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

/// 2px vertical accent bar shown between chips while a drag is in
/// flight and the pointer is hovering the chip.
class _InsertionLine extends StatelessWidget {
  const _InsertionLine();
  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: 2,
      child: Container(color: palette.accentBlue),
    );
  }
}

/// Trailing drop zone used when the user drags a chip past the end of
/// the tab list. The [_ContainerTabBarState] decides whether it's a
/// same-container reorder (oldIndex → length) or a cross-container
/// move (append to length) — the zone just dispatches.
class _EndDropZone extends StatelessWidget {
  final double width;
  final bool hovered;
  final ValueChanged<bool> onHoverChanged;
  final void Function(SurfaceDragData drag) onAccept;

  const _EndDropZone({
    required this.width,
    required this.hovered,
    required this.onHoverChanged,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DragTarget<SurfaceDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (_) => onHoverChanged(true),
      onLeave: (_) => onHoverChanged(false),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidate, rejected) {
        return SizedBox(
          width: width,
          height: 30,
          child: Stack(
            children: [
              if (hovered || candidate.isNotEmpty)
                Positioned(
                  left: 0,
                  top: 4,
                  bottom: 4,
                  child: SizedBox(
                    width: 2,
                    child: ColoredBox(color: palette.accentBlue),
                  ),
                ),
              if (candidate.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: palette.accentBlue.withValues(alpha: 0.05),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Wraps a pane's terminal body with three drop zones:
///   1. **Central body zone** — accepts drops from *other* panes and
///      appends the dragged tab to this container's list (rejects
///      same-pane drops, since those should go through the chip or
///      edge paths).
///   2. **Four edge zones** (left/right/top/bottom) — accepting drops
///      creates a new split with the dragged tab in a new container
///      on the indicated side. Accepts both same-pane and cross-pane
///      drags. Each edge occupies the outer 25% of the pane on its
///      axis (clamped to [24px, half-size]).
///
/// Visual feedback: hovered edge gets a tinted overlay; hovered body
/// gets a 2px blue border; hovered tab chips get their insertion line
/// (handled by [_DraggableChip], not here).
class _PaneDropOverlay extends StatefulWidget {
  final PaneContainer container;
  final void Function(
    SurfaceDragData drag,
    PaneContainer toContainer,
    int targetIndex,
  ) onMoveSurfaceBetweenContainers;
  final void Function(
    SurfaceDragData drag,
    PaneContainer targetContainer,
    PaneEdge edge,
  ) onDropToSplitEdge;
  final ValueListenable<bool> isAnyTabDragActive;
  final Widget child;

  const _PaneDropOverlay({
    super.key,
    required this.container,
    required this.onMoveSurfaceBetweenContainers,
    required this.onDropToSplitEdge,
    required this.isAnyTabDragActive,
    required this.child,
  });

  @override
  State<_PaneDropOverlay> createState() => _PaneDropOverlayState();
}

class _PaneDropOverlayState extends State<_PaneDropOverlay> {
  /// Which edge is currently being hovered (null = none / body).
  PaneEdge? _hoveredEdge;

  void _setHoveredEdge(PaneEdge? edge) {
    if (_hoveredEdge == edge) return;
    setState(() => _hoveredEdge = edge);
  }

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder sits OUTSIDE the Stack so the Positioned children
    // are direct children of the Stack (Positioned only works as a
    // direct Stack descendant — using StackParentData). The builder
    // gets the constraints from the parent (Expanded in the pane
    // Column) and computes band sizes for the four edge zones.
    //
    // ValueListenableBuilder listens to the workspace-level
    // `isAnyTabDragActive` signal and conditionally renders the four
    // edge `_EdgeSplitZone`s. When no drag is in flight the Stack
    // contains only the central body DragTarget (which is transparent
    // and does not block the terminal at rest).
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        // `clamp` throws when min > max. Defensive: if the pane is
        // narrower than the 40px floor (e.g. during the very first
        // frame, or in pathological parent constraints), collapse to
        // a 0-width band rather than crashing the whole tree.
        final bandW = (w * 0.25).clamp(40.0, w <= 80.0 ? 40.0 : w / 2);
        final bandH = (h * 0.25).clamp(40.0, h <= 80.0 ? 40.0 : h / 2);

        return ValueListenableBuilder<bool>(
          valueListenable: widget.isAnyTabDragActive,
          builder: (context, anyDrag, _) {
            return Stack(
              children: [
                // 1) Central body zone — cross-pane moves only.
                // Always rendered (transparent when no drag is in
                // flight); the candidate overlay paints a blue border
                // to advertise the drop target.
                DragTarget<SurfaceDragData>(
                  onWillAcceptWithDetails: (details) =>
                      details.data.sourceContainerId != widget.container.id,
                  onAcceptWithDetails: (details) {
                    widget.onMoveSurfaceBetweenContainers(
                      details.data,
                      widget.container,
                      widget.container.surfaces.length,
                    );
                  },
                  builder: (context, candidate, rejected) {
                    final palette = context.palette;
                    return Stack(
                      children: [
                        widget.child,
                        if (candidate.isNotEmpty)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: palette.accentBlue,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),

                // 2) Four edge zones for drag-to-split. Only rendered
                //    while a tab drag is in flight — otherwise their
                //    always-present translucent `DragTarget` `MetaData`
                //    blocks the terminal's cursor + text selection in
                //    the outer ~25% band on every side
                //    (`bandW = (w*0.25).clamp(40, w/2)`, `bandH` likewise).
                //    The `if` removes the entire subtree at rest, so the
                //    hit-test path through the pane at rest is identical
                //    to a layout with no overlay at all (verified —
                //    cursor + selection work everywhere when overlay is
                //    disabled).
                if (anyDrag) ...[
                  Positioned(
                    left: 0,
                    top: 0,
                    width: bandW,
                    height: h,
                    child: _EdgeSplitZone(
                      edge: PaneEdge.left,
                      hovered: _hoveredEdge == PaneEdge.left,
                      onHoverChanged: (h) =>
                          _setHoveredEdge(h ? PaneEdge.left : null),
                      onAccept: (drag) => widget.onDropToSplitEdge(
                        drag,
                        widget.container,
                        PaneEdge.left,
                      ),
                    ),
                  ),
                  Positioned(
                    left: w - bandW,
                    top: 0,
                    width: bandW,
                    height: h,
                    child: _EdgeSplitZone(
                      edge: PaneEdge.right,
                      hovered: _hoveredEdge == PaneEdge.right,
                      onHoverChanged: (h) =>
                          _setHoveredEdge(h ? PaneEdge.right : null),
                      onAccept: (drag) => widget.onDropToSplitEdge(
                        drag,
                        widget.container,
                        PaneEdge.right,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    width: w,
                    height: bandH,
                    child: _EdgeSplitZone(
                      edge: PaneEdge.top,
                      hovered: _hoveredEdge == PaneEdge.top,
                      onHoverChanged: (h) =>
                          _setHoveredEdge(h ? PaneEdge.top : null),
                      onAccept: (drag) => widget.onDropToSplitEdge(
                        drag,
                        widget.container,
                        PaneEdge.top,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: h - bandH,
                    width: w,
                    height: bandH,
                    child: _EdgeSplitZone(
                      edge: PaneEdge.bottom,
                      hovered: _hoveredEdge == PaneEdge.bottom,
                      onHoverChanged: (h) =>
                          _setHoveredEdge(h ? PaneEdge.bottom : null),
                      onAccept: (drag) => widget.onDropToSplitEdge(
                        drag,
                        widget.container,
                        PaneEdge.bottom,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

/// One edge of the pane's drop overlay. Sized and positioned by
/// the parent [Positioned] (see [_PaneDropOverlay]). The widget
/// itself is just a [DragTarget] wrapped around an animated
/// visual — a tinted strip with a thick inner line on the side
/// that becomes the new split boundary.
class _EdgeSplitZone extends StatelessWidget {
  final PaneEdge edge;
  final bool hovered;
  final ValueChanged<bool> onHoverChanged;
  final void Function(SurfaceDragData drag) onAccept;

  const _EdgeSplitZone({
    required this.edge,
    required this.hovered,
    required this.onHoverChanged,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<SurfaceDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (_) => onHoverChanged(true),
      onLeave: (_) => onHoverChanged(false),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidate, rejected) {
        final palette = context.palette;
        final active = hovered || candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: active
                ? palette.accentBlue.withValues(alpha: 0.15)
                : Colors.transparent,
          ),
          child: Align(
            alignment: _alignmentFor(edge),
            child: Container(
              width: edge == PaneEdge.left || edge == PaneEdge.right
                  ? 3
                  : null,
              height: edge == PaneEdge.top || edge == PaneEdge.bottom
                  ? 3
                  : null,
              color:
                  active ? palette.accentBlue : Colors.transparent,
            ),
          ),
        );
      },
    );
  }

  Alignment _alignmentFor(PaneEdge e) {
    switch (e) {
      case PaneEdge.left:
        return Alignment.centerLeft;
      case PaneEdge.right:
        return Alignment.centerRight;
      case PaneEdge.top:
        return Alignment.topCenter;
      case PaneEdge.bottom:
        return Alignment.bottomCenter;
    }
  }
}

String _shortenTitle(String raw) {
  if (raw.isEmpty) return '';
  if (raw.toLowerCase().endsWith('.exe')) return '';
  final stripped = raw.replaceAll('/', '\\');
  if (stripped.contains('\\')) {
    final parts = stripped.split('\\').where((s) => s.isNotEmpty).toList();
    if (parts.isNotEmpty) {
      final last = parts.last;
      if (last.length == 2 && last.endsWith(':')) return raw;
      return last;
    }
  }
  return raw;
}

// ── Draggable divider between split panes ────────────────────────────

class _Divider extends StatelessWidget {
  final bool isHorizontal;
  final void Function(double delta, double totalSize) onDrag;
  const _Divider({required this.isHorizontal, required this.onDrag});

  // Hit area only — no visible ridge. The cursor changes on hover so
  // users can find the grab zone, but the divider itself is invisible.
  // The panes sit flush against each other (see _buildSplit), so the
  // only "gutter" is this transparent hit rectangle straddling the
  // boundary. 4px is the sweet spot — small enough to feel like a
  // hairline, wide enough to grab reliably.
  static const double hitSize = 4;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: isHorizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: isHorizontal
            ? (d) => onDrag(d.delta.dx, d.globalPosition.dx)
            : null,
        onVerticalDragUpdate: !isHorizontal
            ? (d) => onDrag(d.delta.dy, d.globalPosition.dy)
            : null,
        child: SizedBox(
          width: isHorizontal ? hitSize : double.infinity,
          height: isHorizontal ? double.infinity : hitSize,
        ),
      ),
    );
  }
}

/// Renders a shell/distro glyph from either a bundled SVG asset
/// ([iconAsset]) or, when the profile has no asset (CMD), a fallback
/// Material [iconData]. Keeps every render site in this file free of
/// the SVG-vs-Icon branching.
///
/// The SVG path intentionally does NOT apply [color] as a tint: each
/// bundled asset already carries its own brand colours (Debian red,
/// Ubuntu orange, Fedora blue, …), and tinting everything with the
/// profile's per-shell `color` (which is a single green for every WSL
/// distro) would collapse them all to the same shade. The Material
/// fallback path still uses [color] since the glyph has no brand
/// palette of its own.
class _ShellIcon extends StatelessWidget {
  final IconData? iconData;
  final String? iconAsset;
  final Color color;
  final double size;

  const _ShellIcon({
    required this.color,
    required this.size,
    this.iconData,
    this.iconAsset,
  });

  @override
  Widget build(BuildContext context) {
    if (iconAsset != null) {
      // Brand-coloured SVG. flutter_svg keeps the drawing crisp at
      // any scale factor (HiDPI included).
      return SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(iconAsset!, fit: BoxFit.contain),
      );
    }
    return Icon(iconData, size: size, color: color);
  }
}
