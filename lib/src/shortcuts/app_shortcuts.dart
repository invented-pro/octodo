// Cross-platform keyboard shortcuts.
//
// Three binding scopes, three widget-tree levels (App > Workspace >
// Terminal). The activator builders in this file pick the right primary
// modifier (Cmd on macOS, Ctrl on Windows/Linux) so the same call site
// produces platform-correct bindings without `if (Platform.isMacOS)`
// sprinkled through the UI.
//
// Dispatch pipeline:
//
//   1. `_AppShellState` builds a merged map of every scope's bindings
//      in its `build` and stores it on `_mergedShortcuts`.
//   2. The state registers a `FocusManager.addEarlyKeyEventHandler`
//      in `initState` (removed in `dispose`).
//   3. The early handler walks the merged map and invokes the
//      first matching callback; on a match it returns
//      `KeyEventResult.handled` so the rest of the focus tree
//      walk — including `flutter_alacritty`'s `_onKeyFallback`
//      — is skipped entirely.
//
// Why early-key-event and not `CallbackShortcuts` or
// `HardwareKeyboard.addHandler`? Because:
//   * `CallbackShortcuts` widgets participate in the focus tree
//     walk, which is bottom-up — `flutter_alacritty`'s
//     `Focus.onKeyEvent` (inside `TerminalView`) is deeper in the
//     tree, so it fires first, consumes every key event (either
//     matching its own default shortcuts or encoding the chord
//     into PTY bytes), and propagation stops before our
//     `CallbackShortcuts` ancestors ever get the event.
//   * `HardwareKeyboard.addHandler` runs **in parallel** with the
//     focus tree dispatch (`_HardwareKeyboardState._dispatchKeyEvent`
//     iterates all handlers and OR-s their results, never breaking
//     early; `RawKeyboard.handleRawKeyEvent` always invokes both
//     `handleKeyEvent` and `_dispatchKeyMessage`). So returning
//     `true` from a `HardwareKeyboard` handler does NOT prevent
//     `flutter_alacritty`'s `_onKeyFallback` from encoding the
//     chord into PTY bytes — that was the ^B / ^N leak we hit when
//     first switching to `HardwareKeyboard`.
//   * `FocusManager.addEarlyKeyEventHandler` is the only API that
//     runs **before** the focus tree walk in
//     `FocusManager.handleKeyMessage`. Returning `handled` from
//     there returns `true` from `handleKeyMessage`, which makes
//     the binding layer skip the rest of the dispatch chain
//     (including `_onKeyFallback`).
//
// Clipboard passthrough: when an `EditableText` has focus (the
// workspace rename `TextField`, or any future inline editor), the
// handler skips clipboard activators (Ctrl+V, Ctrl+Shift+C,
// Ctrl+Insert, Shift+Insert) so the standard text-editing shortcuts
// still work in the field.
//
// Design constraints (audited against common terminal / shell usage):
//
// * NEVER bind a bare Ctrl-letter without Shift or Alt — readline /
//   emacs / vim / bash all live on those keys. Ctrl-W (delete-word) and
//   Ctrl-T (transpose) are pressed constantly inside shells; stealing
//   them breaks every readline-using app.
// * NEVER bind Ctrl-Q/Ctrl-S — they are XON/XOFF terminal flow control,
//   still bound by some TUIs and shells.
// * NEVER bind Ctrl-C / Ctrl-D / Ctrl-Z / Ctrl-\ — universal shell
//   interrupt / EOF / suspend / SIGQUIT. (We already don't.)
// * NEVER bind Ctrl-Alt-arrow on Windows or Linux — Intel HD Graphics
//   uses it to rotate the screen, and GNOME / KDE use it to switch
//   desktops. We use Alt-Shift-arrow for pane focus instead.
// * Use Ctrl-Shift-letter for app-level shortcuts (workspace nav,
//   tabs, splits) — this is the Windows Terminal / GNOME Terminal /
//   Konsole convention. None of these collide with readline / vim /
//   tmux / btop / htop keybindings.
// * Reserved shortcuts (search, vi mode) consume the keystroke and
//   show a transient snackbar so the user knows the binding is real.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../log.dart';

final Logger _log = moduleLogger('shortcuts');

/// Returns the platform's "primary" modifier for app shortcuts — `meta`
/// (the macOS Command key) on macOS, `control` everywhere else.
///
/// Tested with [SingleActivator.control] and [SingleActivator.meta]:
/// setting both to false produces a no-modifier binding; setting one
/// to true matches only that side of the keyboard.
bool get _useMetaAsPrimary => Platform.isMacOS;

/// Build a [ShortcutActivator] that uses the platform's primary
/// modifier. Optional [shift] / [alt] flags stack on top.
///
/// Examples (Win/Linux):
///   primary(LogicalKeyboardKey.keyB, shift: true)   // Ctrl+Shift+B
///   primary(LogicalKeyboardKey.keyT, alt: true)     // Ctrl+Alt+T
///
/// Examples (macOS):
///   primary(LogicalKeyboardKey.keyB, shift: true)   // Cmd+Shift+B
///   primary(LogicalKeyboardKey.keyT, alt: true)     // Cmd+Option+T
ShortcutActivator primary(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) {
  return SingleActivator(
    key,
    control: !_useMetaAsPrimary,
    meta: _useMetaAsPrimary,
    shift: shift,
    alt: alt,
  );
}

/// Build a [ShortcutActivator] that uses ONLY the Alt / Option modifier
/// with no primary modifier attached.
///
/// No longer used by `WorkspaceBindings.build()` (pane focus now
/// uses the platform-primary `Ctrl/Cmd+Shift+arrow` form). Kept
/// for any future binding that genuinely wants Alt-only — e.g.,
/// a developer-mode shortcut that shouldn't collide with the
/// system primary modifier on any platform.
ShortcutActivator altOnly(LogicalKeyboardKey key, {bool shift = false}) {
  return SingleActivator(key, alt: true, shift: shift);
}

/// Build a [ShortcutActivator] with no modifier. Used for `PageUp` /
/// `PageDown` scroll and `Shift+Insert` paste.
ShortcutActivator plain(LogicalKeyboardKey key) => SingleActivator(key);

/// Human-readable label of the platform's primary modifier, suitable for
/// tooltips and docs.
///
/// Returns `"⌘"` on macOS (concise, matches Apple HIG) and `"Ctrl"` on
/// Windows / Linux (matches Material tooltip convention).
String get primaryLabel => _useMetaAsPrimary ? '⌘' : 'Ctrl';

/// Render a shortcut like `Ctrl+Shift+B` (Win/Linux) or `⌘⇧B` (macOS)
/// for use in tooltips and the README. Modifier order is always
/// Ctrl/Cmd → Alt → Shift → key, matching every other doc we ship.
String describe(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) {
  final mac = _useMetaAsPrimary;
  final parts = <String>[];
  if (mac) {
    if (alt) parts.add('⌥');
    if (shift) parts.add('⇧');
    parts.add(primaryLabel);
  } else {
    parts.add('Ctrl');
    if (alt) parts.add('Alt');
    if (shift) parts.add('Shift');
  }
  parts.add(_keyLabel(key));
  return parts.join(mac ? '' : '+');
}

/// Show a transient floating snackbar for shortcuts whose feature
/// isn't built yet (search, vi mode, …). The snackbar auto-dismisses
/// after 2 seconds and floats above the bottom edge so it doesn't
/// push other widgets around.
///
/// [messenger] is the [ScaffoldMessengerState] captured at build time
/// (avoid `ScaffoldMessenger.of(context)` from inside a closure that
/// may outlive the [BuildContext] — that's the `_shellContext` pattern
/// from `_AppShellState`).
void showReservedHint(ScaffoldMessengerState? messenger, String message) {
  if (messenger == null) {
    _log.warning('showReservedHint called without a messenger');
    return;
  }
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
}

/// Compact label for a [LogicalKeyboardKey] used by [describe]. Falls
/// back to `key.<enumName>` so unknown keys still render something
/// readable (e.g. `key.f12` rather than `<unknown>`).
String _keyLabel(LogicalKeyboardKey key) {
  // Common letters.
  // Note: not `const` because [LogicalKeyboardKey] overrides `==` /
  // `hashCode`, which makes it ineligible as a const map key (Dart
  // analyzer: `const_map_key_not_primitive_equality`).
  final letterMap = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.keyA: 'A',
    LogicalKeyboardKey.keyB: 'B',
    LogicalKeyboardKey.keyC: 'C',
    LogicalKeyboardKey.keyD: 'D',
    LogicalKeyboardKey.keyE: 'E',
    LogicalKeyboardKey.keyF: 'F',
    LogicalKeyboardKey.keyG: 'G',
    LogicalKeyboardKey.keyH: 'H',
    LogicalKeyboardKey.keyI: 'I',
    LogicalKeyboardKey.keyJ: 'J',
    LogicalKeyboardKey.keyK: 'K',
    LogicalKeyboardKey.keyL: 'L',
    LogicalKeyboardKey.keyM: 'M',
    LogicalKeyboardKey.keyN: 'N',
    LogicalKeyboardKey.keyO: 'O',
    LogicalKeyboardKey.keyP: 'P',
    LogicalKeyboardKey.keyQ: 'Q',
    LogicalKeyboardKey.keyR: 'R',
    LogicalKeyboardKey.keyS: 'S',
    LogicalKeyboardKey.keyT: 'T',
    LogicalKeyboardKey.keyU: 'U',
    LogicalKeyboardKey.keyV: 'V',
    LogicalKeyboardKey.keyW: 'W',
    LogicalKeyboardKey.keyX: 'X',
    LogicalKeyboardKey.keyY: 'Y',
    LogicalKeyboardKey.keyZ: 'Z',
  };
  final letter = letterMap[key];
  if (letter != null) return letter;
  if (key == LogicalKeyboardKey.tab) return 'Tab';
  if (key == LogicalKeyboardKey.comma) return ',';
  if (key == LogicalKeyboardKey.period) return '.';
  if (key == LogicalKeyboardKey.slash) return '/';
  if (key == LogicalKeyboardKey.backspace) return 'Backspace';
  if (key == LogicalKeyboardKey.enter) return 'Enter';
  if (key == LogicalKeyboardKey.space) return 'Space';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.bracketLeft) return '[';
  if (key == LogicalKeyboardKey.bracketRight) return ']';
  if (key == LogicalKeyboardKey.backquote) return '`';
  if (key == LogicalKeyboardKey.pageUp) return 'PageUp';
  if (key == LogicalKeyboardKey.pageDown) return 'PageDown';
  if (key == LogicalKeyboardKey.insert) return 'Ins';
  if (key == LogicalKeyboardKey.f11) return 'F11';
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';
  return key.keyLabel;
}

// ─────────────────────────────────────────────────────────────────────
// Binding factories — one per scope.
//
// Each factory takes plain callbacks (instance methods bound from the
// caller) and returns a Map<ShortcutActivator, VoidCallback> ready to
// hand to `CallbackShortcuts(bindings: ...)`. Closures capture the
// passed-in callbacks by reference, so the map can be rebuilt on
// every build without leaking (the closure lifetime is tied to the
// owning widget, which is exactly what we want).
// ─────────────────────────────────────────────────────────────────────

/// USB-HID logical keys for digit 1..9 used by Ctrl+Shift+N workspace
/// jump and Ctrl+N tab jump. Defined here (not in terminal_view.dart)
/// because both the App and Workspace factories need them.
const _digitKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

/// App-level bindings, installed at `AppShell.build`. These win over
/// every other binding in the tree because the `CallbackShortcuts`
/// widget sits at the top of the shell subtree.
///
/// All bindings use `Ctrl/Cmd+Shift+letter` (Windows Terminal / GNOME
/// Terminal / Konsole convention) — none of them collide with
/// readline, vim, tmux, btop, or shell line-editing.
class AppShellBindings {
  static Map<ShortcutActivator, VoidCallback> build({
    required VoidCallback toggleDrawer,
    required VoidCallback newWorkspace,
    required VoidCallback closeCurrentWorkspace,
    required VoidCallback nextWorkspace,
    required VoidCallback previousWorkspace,
    required void Function(int index) jumpToWorkspace,
    required VoidCallback toggleFullscreen,
    required VoidCallback quit,
    required void Function(String feature) showReservedHint,
  }) {
    final bindings = <ShortcutActivator, VoidCallback>{};

    bindings[primary(LogicalKeyboardKey.keyB, shift: true)] = toggleDrawer;
    bindings[primary(LogicalKeyboardKey.keyN, shift: true)] = newWorkspace;
    bindings[primary(LogicalKeyboardKey.keyW, shift: true)] =
        closeCurrentWorkspace;
    bindings[primary(LogicalKeyboardKey.bracketRight, shift: true)] =
        nextWorkspace;
    bindings[primary(LogicalKeyboardKey.bracketLeft, shift: true)] =
        previousWorkspace;
    // No `Ctrl+,` / `Cmd+,` settings binding — per user request we
    // gave up trying to make it work; settings are reachable via
    // the drawer's Settings button instead.
    bindings[primary(LogicalKeyboardKey.keyQ, shift: true)] = quit;

    for (var i = 0; i < _digitKeys.length; i++) {
      final idx = i;
      bindings[primary(_digitKeys[i], shift: true)] = () =>
          jumpToWorkspace(idx);
    }

    // Fullscreen: F11 on Windows / Linux (universal binding,
    // conflicts with nothing because F-keys are not bound by any
    // shell / terminal app). On macOS, the system reserves F11 for
    // "Show Desktop" (Expose), so we use Ctrl+Cmd+F instead — the
    // conventional macOS fullscreen toggle (matches Chrome, VSCode,
    // iTerm2).
    if (Platform.isMacOS) {
      bindings[const SingleActivator(
            LogicalKeyboardKey.keyF,
            control: true,
            meta: true,
          )] =
          toggleFullscreen;
    } else {
      bindings[const SingleActivator(LogicalKeyboardKey.f11)] =
          toggleFullscreen;
    }

    // Reserved — search.
    bindings[primary(LogicalKeyboardKey.keyF, shift: true)] = () =>
        showReservedHint('Search is coming soon');

    // Reserved — vi mode.
    bindings[primary(LogicalKeyboardKey.space, shift: true)] = () =>
        showReservedHint('Vi mode is coming soon');

    return bindings;
  }
}

/// Workspace-level bindings, installed at `TerminalWorkspace.build`.
/// These fire when no `AppShell` ancestor binding matched.
class WorkspaceBindings {
  static Map<ShortcutActivator, VoidCallback> build({
    required VoidCallback newTab,
    required VoidCallback closeTab,
    required VoidCallback nextTab,
    required VoidCallback previousTab,
    required void Function(int index) jumpToTab,
    required VoidCallback splitRight,
    required VoidCallback splitDown,
    required void Function(PaneDirection direction) focusPaneInDirection,
    required VoidCallback toggleMaximizePane,
  }) {
    final bindings = <ShortcutActivator, VoidCallback>{};

    // Tab operations. `Ctrl+Shift+T` opens a new tab in the focused
    // pane — the `Ctrl+Alt+T` triple-modifier we previously used was
    // awkward on AZERTY / Dvorak and on Windows with Ctrl-Shift
    // already mapped to "switch input language" by some IMEs. The
    // reopen-last-closed-tab feature has been removed per user
    // request (it was rarely useful and conflicted with the
    // `Ctrl+Shift+T` shortcut we now use for new tab).
    bindings[primary(LogicalKeyboardKey.keyT, shift: true)] = newTab;
    bindings[primary(LogicalKeyboardKey.keyK, shift: true)] = closeTab;
    bindings[SingleActivator(LogicalKeyboardKey.tab, control: true)] = nextTab;
    bindings[SingleActivator(
          LogicalKeyboardKey.tab,
          control: true,
          shift: true,
        )] =
        previousTab;

    for (var i = 0; i < _digitKeys.length; i++) {
      final idx = i;
      bindings[SingleActivator(_digitKeys[i], control: true)] = () =>
          jumpToTab(idx);
    }

    // Split operations.
    bindings[primary(LogicalKeyboardKey.keyD, shift: true)] = splitRight;
    bindings[primary(LogicalKeyboardKey.keyE, shift: true)] = splitDown;

    // Pane focus — Ctrl+Shift+arrows. Mirrors i3 / sway / vimium
    // convention (with the primary modifier instead of Alt). The
    // early-key handler runs *before* `flutter_alacritty`'s
    // `_onKeyFallback`, so even if some shell binding consumed the
    // chord (none does by default — `Ctrl+Shift+arrows` is free in
    // bash, zsh, fish, vim normal mode, tmux default prefix), our
    // dispatch wins and the chord never leaks to the PTY.
    bindings[primary(LogicalKeyboardKey.arrowUp, shift: true)] = () =>
        focusPaneInDirection(PaneDirection.up);
    bindings[primary(LogicalKeyboardKey.arrowDown, shift: true)] = () =>
        focusPaneInDirection(PaneDirection.down);
    bindings[primary(LogicalKeyboardKey.arrowLeft, shift: true)] = () =>
        focusPaneInDirection(PaneDirection.left);
    bindings[primary(LogicalKeyboardKey.arrowRight, shift: true)] = () =>
        focusPaneInDirection(PaneDirection.right);

    // Maximize / restore.
    bindings[primary(LogicalKeyboardKey.keyM, shift: true)] =
        toggleMaximizePane;

    return bindings;
  }
}

/// Terminal-engine bindings, installed at `TerminalView.build`. These
/// are the deepest layer — `flutter_alacritty`'s internal `Shortcuts`
/// widget consumes everything that doesn't match here.
///
/// We deliberately do NOT bind bare Ctrl+letter without Shift / Alt —
/// those are owned by readline / vim / bash and we just pass them
/// through to the PTY. The `Ctrl+U/K/L/A/E` cluster writes raw bytes
/// directly through `_engine.write(...)`, bypassing the Shortcuts
/// activator entirely so the shell always sees the bytes.
///
/// **PageUp / PageDown / Shift+PageUp / Shift+PageDown are deliberately
/// NOT in this map.** They used to live here so the app-level early-key
/// handler could dispatch them — but that handler returns `handled`
/// after the first match, which (a) prevented `flutter_alacritty`'s
/// `fa.TerminalView._onKeyFallback` from ever seeing the event and (b)
/// routed the dispatch through a long `?.` chain that occasionally
/// resolved to a no-op (the focused terminal view wasn't always
/// resolvable from `_activeWorkspace?.key.currentState`), so PageUp
/// silently did nothing. Both classes of fix landed in `terminal_view.dart`
/// instead: the FA shortcut map now binds PageUp → `ScrollPageIntent`
/// (which calls `engine.scrollLines` directly), and a `Focus` widget
/// wrapping the Stack provides a second-line safety net for the
/// unlikely case that the FA path also fails. See
/// `terminal_view.dart:1064–1125` (shortcuts) and `:1144–1166` (safety
/// net) for the full reasoning.
///
/// Font zoom (`Ctrl+=` / `Ctrl++` / `Ctrl+-` / `Ctrl+0` and the
/// `Ctrl+Shift+…` variants) is **not** bound here. Alacritty owns
/// font-size state — the engine re-emits the configured font size
/// on `reconfigure(...)`, and the TerminalView's default action
/// handlers in `defaultTerminalActions` already wire the bundled
/// `defaultTerminalShortcuts` map to `IncreaseFontSizeIntent` /
/// `DecreaseFontSizeIntent` / `ResetFontSizeIntent`. Reimplementing
/// zoom on our side would duplicate that logic, drift from
/// alacritty's source of truth, and miss out on any future zoom
/// behavior alacritty adds. Instead, `TerminalView` injects an
/// extended `shortcuts:` map into `fa.TerminalView` — alacritty's
/// defaults plus our `Ctrl+Shift+…` variants (which alacritty's
/// stock bindings don't ship, since the upstream alacritty project
/// only configures the unshifted forms).
class TerminalBindings {
  static Map<ShortcutActivator, VoidCallback> build({
    required VoidCallback copySelection,
    required VoidCallback paste,
  }) {
    final bindings = <ShortcutActivator, VoidCallback>{};

    // Clipboard. We bind:
    //   - `Ctrl+Shift+C`       → copy selection (matches FA's default
    //     but we keep our copy for consistency — works in all paths
    //     including right-click menu / accessibility tools that prefer
    //     us over FA).
    //   - `Ctrl+Insert`        → copy selection (alt).
    //   - `Ctrl+V`             → paste (FA's stock bindings only ship
    //     `Ctrl+Shift+V` for paste, not bare `Ctrl+V`).
    //   - `Shift+Insert`       → paste (alt).
    //
    // `Ctrl+Shift+V` is **deliberately not bound** here. Alacritty's
    // own `defaultTerminalShortcuts` ships `Ctrl+Shift+V → PasteIntent`,
    // and our delegation pattern was producing inconsistent results
    // (the user reported the paste silently failing while `Ctrl+Shift+C`
    // worked). Letting alacritty's bundled `defaultPasteAction(engine,
    // controller)` handle it is the right call — alacritty owns the
    // engine's clipboard-load pathway and we don't want to fight it.
    bindings[primary(LogicalKeyboardKey.keyC, shift: true)] = copySelection;
    bindings[const SingleActivator(LogicalKeyboardKey.insert, control: true)] =
        copySelection;
    bindings[primary(LogicalKeyboardKey.keyV)] = paste;
    bindings[const SingleActivator(LogicalKeyboardKey.insert, shift: true)] =
        paste;

    // Readline passthrough (Ctrl+U/K/L/A/E) is NOT in this map — the
    // terminal view wires those directly to `_engine.write(...)` with
    // the appropriate control byte, bypassing the activator system so
    // the shell always receives the bytes regardless of Flutter's
    // shortcut state. See `TerminalView._sendCtrlU/K/L/A/E`.

    return bindings;
  }
}

/// Cardinal direction for `Ctrl/Cmd+Shift+arrow` pane focus.
enum PaneDirection { up, down, left, right }
