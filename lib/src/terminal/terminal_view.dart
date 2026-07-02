import 'dart:async';
import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart' as fa;
// `defaultTerminalShortcuts` is exported from the package barrel; we
// also need the zoom Intents so we can register shift variants of the
// zoom keys (which alacritty's stock shortcuts map omits).
import 'package:flutter_alacritty/flutter_alacritty.dart'
    show
        defaultTerminalShortcuts,
        DecreaseFontSizeIntent,
        IncreaseFontSizeIntent,
        ResetFontSizeIntent;
import 'package:signals/signals_flutter.dart';
import '../settings/settings_catalog.dart';
import '../log.dart';
import '../shortcuts/app_shortcuts.dart';
import 'pane_tree.dart' show Surface;

final Logger _log = moduleLogger('terminal.terminal_view');

/// Immutable snapshot of every user-facing setting that affects the terminal
/// engine (font, background, cursor, scrollback, bell, copy-on-select).
///
/// `TerminalWorkspace` rebuilds this whenever any of the underlying setting
/// stores emits a change; it's then passed down to `PaneLayout` → `TerminalView`.
/// `TerminalView.didUpdateWidget` compares against the previous snapshot and
/// calls `engine.reconfigure(_buildConfig())` so changes apply live without
/// re-spawning the shell.
///
/// Value-equality (==/hashCode) drives the didUpdateWidget change detection;
/// no need for the parent to wrap it in a manual `Key`.
class TerminalSettings {
  const TerminalSettings({
    required this.fontFamily,
    required this.fontSize,
    required this.backgroundColor,
    required this.cursorStyle,
    required this.cursorBlink,
    required this.scrollbackLines,
    required this.copyOnSelect,
    required this.bellMode,
  });

  final String fontFamily;
  final double fontSize;
  final Color backgroundColor;
  final CursorStyle cursorStyle;
  final bool cursorBlink;
  final int scrollbackLines;
  final bool copyOnSelect;
  final BellMode bellMode;

  TerminalSettings copyWith({
    String? fontFamily,
    double? fontSize,
    Color? backgroundColor,
    CursorStyle? cursorStyle,
    bool? cursorBlink,
    int? scrollbackLines,
    bool? copyOnSelect,
    BellMode? bellMode,
  }) =>
      TerminalSettings(
        fontFamily: fontFamily ?? this.fontFamily,
        fontSize: fontSize ?? this.fontSize,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        cursorStyle: cursorStyle ?? this.cursorStyle,
        cursorBlink: cursorBlink ?? this.cursorBlink,
        scrollbackLines: scrollbackLines ?? this.scrollbackLines,
        copyOnSelect: copyOnSelect ?? this.copyOnSelect,
        bellMode: bellMode ?? this.bellMode,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalSettings &&
          other.fontFamily == fontFamily &&
          other.fontSize == fontSize &&
          other.backgroundColor == backgroundColor &&
          other.cursorStyle == cursorStyle &&
          other.cursorBlink == cursorBlink &&
          other.scrollbackLines == scrollbackLines &&
          other.copyOnSelect == copyOnSelect &&
          other.bellMode == bellMode);

  @override
  int get hashCode => Object.hash(
        fontFamily,
        fontSize,
        backgroundColor,
        cursorStyle,
        cursorBlink,
        scrollbackLines,
        copyOnSelect,
        bellMode,
      );
}

/// Map our `CursorStyle` enum (block / underline / bar) to alacritty's
/// `defaultShape` int: 0=Block, 1=Underline, 2=Beam, 3=HollowBlock, 4=Hidden.
/// Our enum's name order matches the alacritty wire format so we can map by
/// index — using the name explicitly here keeps it robust to future enum
/// reordering.
int _cursorShapeFromEnum(CursorStyle s) => switch (s) {
      CursorStyle.block => 0,
      CursorStyle.underline => 1,
      CursorStyle.bar => 2,
    };

/// Convert a Flutter [Color] (RGBA, 0xAARRGGBB) to the packed
/// `0x00RRGGBB` int that `flutter_alacritty`'s [fa.TerminalColors]
/// expects. Alpha is dropped — alacritty's grid is always opaque.
int _toAlacrittyColor(Color c) {
  final r = (c.r * 255.0).round() & 0xFF;
  final g = (c.g * 255.0).round() & 0xFF;
  final b = (c.b * 255.0).round() & 0xFF;
  return (r << 16) | (g << 8) | b;
}

/// Visual flash length for `fa.TerminalView`'s bell animation when the
  /// bell mode is `visual`. Matches alacritty's default 100ms.
  const Duration _kVisualBellDuration = Duration(milliseconds: 100);

  /// Default colors palette from [fa.TerminalConfig.defaults]. Cached so
/// `_buildConfig` doesn't allocate a fresh TerminalColors + 16-ANSI
/// array on every call (called from initState, every settings change,
/// every zoom step).
final fa.TerminalColors _defaultColors =
    fa.TerminalConfig.defaults().colors;

/// A self-contained terminal emulator widget backed by `flutter_alacritty`
/// (Alacritty Rust core via flutter_rust_bridge + `flutter_pty` for ConPTY).
///
/// Each [TerminalView] owns:
///   * a [fa.TerminalEngine] — the Alacritty VT/screen renderer,
///   * a [fa.TerminalController] — selection/search/zoom state,
///   * a [fa.PtyBackend] — wraps `flutter_pty::Pty.start` for ConPTY I/O.
///
/// The widget renders `flutter_alacritty`'s [fa.TerminalView] for cell
/// painting and built-in keyboard/mouse/IME handling.
/// overlay above clicks, and re-binds `onTitleChanged` / `onPwdChanged` /
/// `onExited` callbacks into the [Surface] model used by the tab bar.
///
/// Used by the tab shell in `lib/main.dart` — one [TerminalView] per tab.
/// Each instance manages an independent shell process. Only the instance
/// whose [FocusNode] has focus processes global key events; all others
/// silently ignore them.
class TerminalView extends StatefulWidget {
  /// Owning Surface. Provides the FocusNode the view binds to and the
  /// shell command string. The Surface is the source of truth for
  /// tab identity; this widget is a pure renderer.
  final Surface surface;

  /// Initial working directory for the spawned shell.
  final String? workingDirectory;

  /// Current user-facing terminal settings (font, cursor, scrollback, bell,
  /// copy-on-select). The widget caches this in its state and re-applies on
  /// didUpdateWidget whenever the workspace rebuilds with a new snapshot —
  /// no need to re-spawn the shell.
  final TerminalSettings settings;

  /// Called whenever the terminal title (set via OSC 0/2 escape sequences)
  /// changes.
  final ValueChanged<String>? onTitleChanged;

  /// Called whenever the working directory (reported via OSC 7) changes.
  /// The string is the decoded path, e.g. `C:\Users\x\proj`. Empty when
  /// the shell clears it.
  final ValueChanged<String>? onPwdChanged;

  /// Called when the underlying shell process exits.
  final VoidCallback? onExited;

  const TerminalView({
    super.key,
    required this.surface,
    this.workingDirectory,
    this.settings = const TerminalSettings(
      fontFamily: 'Cascadia Code',
      fontSize: 14.0,
      backgroundColor: Color(0xFF181818),
      cursorStyle: CursorStyle.block,
      cursorBlink: true,
      scrollbackLines: 10000,
      copyOnSelect: false,
      bellMode: BellMode.visual,
    ),
    this.onTitleChanged,
    this.onPwdChanged,
    this.onExited,
  });

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView> {
  late final fa.TerminalEngine _engine;
  late final fa.TerminalController _controller;
  /// Borrowed from `widget.surface.focusNode`. The Surface owns it
  /// (and disposes it in `Surface.dispose()`); this state MUST NOT
  /// dispose it from its own `dispose()`. Borrowing rather than
  /// owning lets the workspace request focus via
  /// `surface.focusNode.requestFocus()` without needing a GlobalKey
  /// into this State (which collided with focus scopes when the
  /// parent rebuilt — see v6.0.4 fix).
  late final FocusNode _focus = widget.surface.focusNode;

  fa.PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<Uint8List>? _engineOutputSub;
  StreamSubscription<String>? _clipSub;
  StreamSubscription<void>? _clipLoadSub;
  StreamSubscription<void>? _bellSub;

  String _lastTitle = '';
  String _lastPwd = '';

  // ── Reactive state (signals) ──────────────────────────────────────
  //
  // UI-relevant booleans live as signals so the overlay widgets can
  // rebuild surgically via `SignalBuilder` without re-running the
  // outer build (which would re-instantiate `fa.TerminalView` and
  // drop its paint subscription).
  final Signal<bool> _exited = signal(false);
  final Signal<bool> _hasReceivedOutput = signal(false);
  final Signal<bool> _showSlowHint = signal(false);

  // After this many ms without any output, show an extra hint in the
  // placeholder so the user knows WSL cold-start can take 10-30 s.
  static const Duration _slowHintAfter = Duration(seconds: 8);
  Timer? _slowHintTimer;

  // Font fallback chain: Cascadia Code (ASCII) + Microsoft YaHei (CJK).
  // The primary family comes from `TerminalSettings.fontFamily`; the
  // fallback chain stays constant so CJK glyphs always render even when
  // the user picks an ASCII-only font.
  static const _cjkFontFamily = 'Microsoft YaHei';
  static const _lineHeight = 1.2;

  /// Baseline font size (drives zoom-reset). Tracked across settings
  /// changes via `didUpdateWidget` so `Ctrl+0` always returns to the
  /// value the user picked, not the one at first launch.
  double _defaultFontSize = 14.0;
  double _fontSize = 14.0;

  // Cached copy of `widget.settings.copyOnSelect` — re-read on every
  // selection-end event from `_controller` so the snapshot value at the
  // moment of the click wins (the user can toggle the setting mid-drag).
  bool _copyOnSelect = false;

  // Cached bell mode — drives both fa.TerminalView.bellDuration (visual)
  // and the SystemSound playback (audible). `none` zeroes both.
  BellMode _bellMode = BellMode.visual;

  // The last selection text we saw committed to the engine's primary
  // buffer. Used to detect "selection ended AND new text was captured"
  // without having to diff against the entire selection history.
  String _lastPrimary = '';

  @override
  void initState() {
    super.initState();
    _defaultFontSize = widget.settings.fontSize;
    _fontSize = _defaultFontSize;
    _copyOnSelect = widget.settings.copyOnSelect;
    _bellMode = widget.settings.bellMode;
    _log.fine('initState: creating engine (program="${widget.surface.program}", cwd=${widget.workingDirectory})');

    _engine = fa.TerminalEngine(config: _buildConfig());
    _log.fine('initState: engine created, grid rows=${_engine.grid.rows} cols=${_engine.grid.columns} gen=${_engine.grid.generation}');
    _controller = fa.TerminalController()..attach(_engine);
    _engine.title.addListener(_syncTitle);
    _engine.workingDir.addListener(_syncPwd);

    _clipSub = _engine.clipboardStore.listen((t) {
      Clipboard.setData(ClipboardData(text: t));
    });
    _clipLoadSub = _engine.clipboardLoad.listen((_) async {
      final data = await Clipboard.getData('text/plain');
      _engine.respondClipboardLoad(data?.text ?? '');
    });
    _bellSub = _engine.bell.listen((_) {
      // The underlying fa.TerminalView paints its own visual flash when
      // its bellDuration > zero (driven by settings.bellMode == visual).
      // Here we additionally play the system alert sound for `sound` mode
      // so the user gets audible feedback even with visual flash disabled.
      if (_bellMode == BellMode.sound) {
        SystemSound.play(SystemSoundType.alert);
      }
    });
    // copyOnSelect: listen to the controller so we can copy to the system
    // clipboard whenever a drag-selection ends with new text. The
    // controller's primary buffer is the engine's captured selection text;
    // capturePrimary() (called on drag-end in flutter_alacritty) updates
    // it and fires notifyListeners(). We diff against `_lastPrimary` to
    // ignore redundant capture events with no new text.
    _controller.addListener(_onControllerChanged);

    _start();

    _slowHintTimer = Timer(_slowHintAfter, () {
      if (!mounted || _hasReceivedOutput.value) return;
      _showSlowHint.value = true;
    });

    // Eagerly initialize the engine's grid so the TerminalPainter has
    // something to draw on the very first paint. flutter_alacritty's
    // LayoutBuilder schedules its own `_engine.resize(...)` via a
    // post-frame callback — but that callback fires AFTER the first
    // paint, leaving `grid.rows == 0` and `painter.paint()` returning
    // early. Pre-sizing with safe defaults here ensures the first
    // frame already shows an empty (default-bg) grid; the
    // LayoutBuilder's resize on the next frame just refines it to the
    // real viewport. Without this the pane stays black until some
    // unrelated rebuild (e.g. toggling the workspace drawer) flushes
    // it.
    try {
      _log.fine('initState: calling _engine.resize(80, 24)');
      _engine.resize(columns: 80, rows: 24);
      _log.fine('initState: AFTER resize, grid rows=${_engine.grid.rows} cols=${_engine.grid.columns} gen=${_engine.grid.generation}');
    } catch (e, st) {
      _log.severe('initState: engine.resize threw: $e\n$st');
    }

    // Force one rebuild after the first frame so flutter_alacritty's
    // TerminalPainter actually paints the freshly-sized grid. Without
    // this, the first paint happens before the engine grid is populated
    // (the LayoutBuilder schedules engine.resize via a post-frame
    // callback, which races with the CustomPaint's first paint) and the
    // pane stays black until some unrelated rebuild (e.g. toggling the
    // workspace drawer) flushes it. A `Timer(Duration.zero)` defers past
    // the post-frame callbacks and forces a real repaint cycle.
    Timer(Duration.zero, () {
      if (mounted) {
        _log.fine('Timer(zero) firing setState; grid rows=${_engine.grid.rows} cols=${_engine.grid.columns} gen=${_engine.grid.generation}');
        setState(() {});
      }
    });
  }

  fa.TerminalConfig _buildConfig() {
    final s = widget.settings;
    // Bell duration: `none` disables both visual flash AND audible feedback
    // (the engine skips emitting bell events when duration is 0; the host
    // skips SystemSound.play for `none`). `visual`/`sound` both enable the
    // animation — `sound` additionally plays the system alert in the bell
    // listener above.
    final bellDurationMs = s.bellMode == BellMode.none ? 0 : 100;
    // Cache the default colors palette so we only build it once per
    // process — `defaults()` allocates a full TerminalColors + 16-ANSI
    // array, and we previously called it twice in the same expression.
    final defaultColors = _defaultColors;
    return fa.TerminalConfig.defaults().copyWith(
      // Override the engine background to match `terminal.backgroundColor`.
      // The Flutter window + scaffold background (see main.dart) use the
      // same value so the chrome never flashes a different shade around
      // the terminal grid. alpha is dropped — alacritty takes 0x00RRGGBB.
      colors: defaultColors.copyWith(
            background: _toAlacrittyColor(s.backgroundColor),
          ),
      font: fa.FontConfig(
        family: s.fontFamily,
        fallback: const [
          _cjkFontFamily,
          'Microsoft YaHei UI',
          'SimSun',
          'Consolas',
          'monospace',
        ],
        size: _fontSize,
        lineHeight: _lineHeight,
      ),
      cursor: fa.CursorConfig(
        blinkInterval: 530,
        defaultShape: _cursorShapeFromEnum(s.cursorStyle),
        defaultBlinking: s.cursorBlink,
        blinkTimeout: 5,
      ),
      scrolling: fa.ScrollConfig(
        history: s.scrollbackLines,
        multiplier: 3,
      ),
      bell: fa.BellConfig(
        color: 0xFFFFFF,
        duration: bellDurationMs,
        animation: 'linear',
      ),
      // Disable the engine's own OSC 52 copy/paste so the host (Flutter's
      // Clipboard) owns clipboard I/O end-to-end via _clipSub / _clipLoadSub.
      terminal: const fa.TerminalBehaviorConfig(osc52: fa.Osc52Mode.disabled),
    );
  }

  /// Bell duration passed to `fa.TerminalView`. Zero disables the visual
  /// flash; > zero tells fa.TerminalView to animate the bell overlay.
  Duration get _bellDurationForView =>
      _bellMode == BellMode.none ? Duration.zero : _kVisualBellDuration;

  /// Copy-on-select host-side hook: when the user releases a drag-selection
  /// with non-empty new text in the engine's primary buffer, copy it to
  /// the system clipboard. `_controller.primary` is updated inside
  /// `capturePrimary()` (called from flutter_alacritty's pointer code on
  /// drag-end), which fires `notifyListeners()` — that's how we get here.
  void _onControllerChanged() {
    if (!_copyOnSelect) {
      // Still remember the latest primary so flipping the toggle on later
      // doesn't trigger a stale copy.
      _lastPrimary = _controller.primary;
      return;
    }
    final primary = _controller.primary;
    if (primary.isEmpty || primary == _lastPrimary) return;
    _lastPrimary = primary;
    Clipboard.setData(ClipboardData(text: primary));
  }

  @override
  void didUpdateWidget(covariant TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.settings;
    if (s == oldWidget.settings) return;

    // Cache values the host-side hooks depend on so the next bell event
    // or selection-end uses the latest snapshot.
    _copyOnSelect = s.copyOnSelect;
    _bellMode = s.bellMode;

    // Sync font size + baseline (zoom-reset target) so subsequent
    // builds pass the right `textStyle.size` to fa.TerminalView.
    // Note: we deliberately do NOT call _engine.reconfigure here for a
    // font-only change — fa.TerminalView updates its own metrics from
    // the new textStyle (see flutter_alacritty's didUpdateWidget) and
    // LayoutBuilder will recompute cols/rows, which would trigger a
    // cascading _pty.resize that some shells clear-on-resize (cmd.exe,
    // certain WSL bash configs). Reconfigure is reserved for non-font
    // changes (cursor, scrollback, bell).
    final fontChanged = _fontSize != s.fontSize;
    if (fontChanged) {
      _fontSize = s.fontSize;
      _defaultFontSize = s.fontSize;
    }

    // Non-font settings need to flow into the engine's live state via
    // _engine.reconfigure (scrollback limit, cursor shape/blink, bell
    // duration, font family). Re-apply unconditionally when any of
    // those change — it's a cheap FFI call.
    // Skip reconfigure for font-size-only changes — fa.TerminalView
    // updates its own metrics from the new textStyle and LayoutBuilder
    // recomputes cols/rows. Calling reconfigure AND triggering a resize
    // cascade can wipe scrollback on some shells (cmd.exe + several
    // WSL bash configs clear-on-resize via TIOCSWINSZ). For font-family
    // changes we DO reconfigure so the engine's stored config stays in
    // sync — otherwise new tabs use the old family until restart.
    final engineSideChange = s.cursorStyle != oldWidget.settings.cursorStyle ||
        s.cursorBlink != oldWidget.settings.cursorBlink ||
        s.scrollbackLines != oldWidget.settings.scrollbackLines ||
        s.bellMode != oldWidget.settings.bellMode ||
        s.fontFamily != oldWidget.settings.fontFamily;
    if (engineSideChange) {
      _engine.reconfigure(_buildConfig());
    }
    // Font-family-only changes have a render-quirk in flutter_alacritty:
    // fa.TerminalView's didUpdateWidget rebuilds the GlyphCache with the
    // new family, but TerminalPainter.shouldRepaint returns false when
    // cellWidth/cellHeight don't change (Cascadia Code → Consolas at the
    // same font size have identical metrics). The new painter is set on
    // RenderCustomPaint but `markNeedsPaint` is never called, so the
    // screen stays on the OLD glyphs until the next grid/blink update
    // arrives. `_engine.reconfigure()` already calls `refreshView()`
    // which bumps grid.generation — that bumps _paintGeneration on
    // the next painter construction, so shouldRepaint fires.
    // Explicitly call refreshView() again here as a belt-and-suspenders
    // for the case where fontFamily was the only field that changed
    // AND the painter construction runs after the first refreshView.
    if (s.fontFamily != oldWidget.settings.fontFamily) {
      _engine.refreshView();
    }
    // NOTE: no setState here. StatefulElement.update always calls
    // `rebuild(force: true)` after didUpdateWidget (see framework.dart
    // ~line 6007), so the next build will pick up the cached
    // _bellMode / _fontSize changes automatically.
  }

  /// Re-quote [s] so it survives `cmd.exe`'s `/c` parser as a single token.
  ///
  /// We launch every shell as `cmd.exe /c "<exe>" <args...>` (see [_start]
  /// for why). flutter_pty's Windows `build_command` joins `program` and each
  /// arg with a bare space — no quoting — so any token containing a space
  /// (e.g. `C:\Program Files\…`) must be wrapped here, or cmd/CreateProcessW
  /// would split it into `C:\Program` + `Files\…` and the shell would fail to
  /// find its own executable (the historical "C: Program" first-click crash).
  ///
  /// Backslashes are left alone — paths like `C:\Program Files\pwsh\pwsh.exe`
  /// round-trip cleanly because no backslash immediately precedes a quote in
  /// our token set (we only emit exec paths and readline-style flag args,
  /// never arbitrary user input). This is intentionally simpler than
  /// CommandLineToArgvW's full CRLF/backslash-pairing rules.
  String _quoteForCmd(String s) {
    if (!s.contains(RegExp(r'[\s"]'))) return s;
    return '"${s.replaceAll('"', r'\"')}"';
  }

/// Spawn the configured shell via [fa.FlutterPtyBackend].
  void _start() {
    // Workaround for a Windows-only flutter_pty 0.4.2 spawn quirk: the
    // native `build_command` (flutter_pty/src/flutter_pty_win.c) emits
    // `<executable> <executable> <args...>` because the Dart binding sets
    // `argv[0] = executable` AND `build_command` also iterates `arguments`
    // starting at index 0. CreateProcessW with a NULL lpApplicationName
    // takes the first token as the child's argv[0] and passes the rest as
    // argv[1..n]. cmd.exe and Windows PowerShell tolerate the stray extra
    // positional; pwsh, wsl.exe, and bash do not:
    //   pwsh → "Processing -File '<own path>' failed: no .ps1 extension"
    //   wsl  → runs the path as a Linux command → "command not found"
    //   bash → "<own path>: cannot execute binary file"
    //
    // We therefore launch every shell wrapped in `cmd.exe /c "<real>
    // <args>"`. The doubled token becomes a harmless extra `cmd.exe`
    // before `/c` (cmd ignores positionals before `/c`), and the real
    // invocation rides untouched in the /c payload. Verified:
    // `cmd.exe cmd.exe /c "<exe>" <args>` launches pwsh / bash / wsl
    // correctly.
    final String ptyProgram;
    final List<String> ptyArgs;
    if (widget.surface.program.isEmpty) {
      // No profile — let flutter_alacritty fall back to $SHELL/cmd.
      ptyProgram = '';
      ptyArgs = const [];
    } else {
      final realProgram = widget.surface.program;
      // Only PowerShell understands `-NoProfile`; passing it to wsl.exe,
      // git-bash, or cmd.exe either makes them fail (wsl tries to find a
      // Linux binary called "NoProfile") or is silently ignored. Force it
      // for *Shell pwsh/Windows PowerShell only.
      final isPowerShell = realProgram.toLowerCase().contains('pwsh') ||
          realProgram.toLowerCase().contains('powershell');
      final realArgs = <String>[
        ...widget.surface.args,
        if (isPowerShell) '-NoProfile',
      ];
      ptyProgram = 'cmd.exe';
      ptyArgs = <String>[
        '/c',
        _quoteForCmd(realProgram),
        ...realArgs.map(_quoteForCmd),
      ];
    }

    _log.fine('_start: ptyProgram=$ptyProgram ptyArgs=$ptyArgs (program="${widget.surface.program}") cwd=${widget.workingDirectory}');
    final pty = fa.FlutterPtyBackend(
      rows: 24,
      columns: 80,
      shell: fa.ShellConfig(
        program: ptyProgram.isEmpty ? null : ptyProgram,
        args: ptyArgs,
        workingDirectory: widget.workingDirectory,
      ),
    );
    _pty = pty;
    _log.fine('_start: PTY backend created');

    _engineOutputSub = _engine.output.listen(
      (bytes) {
        // Gate host→PTY writes after the PTY has exited. flutter_pty's
        // `pty_write` calls `WriteFile(handle->inputWriteSide, ...)` on
        // the ConPTY input pipe; once the ConPTY's client process
        // (cmd.exe wrapper) is gone, the kernel does NOT return
        // `ERROR_BROKEN_PIPE` until `ClosePseudoConsole` is invoked,
        // and we never invoke it. So `WriteFile` blocks the UI thread
        // indefinitely on any post-exit keystroke. Dropping the bytes
        // here is safe — there is no PTY to receive them anyway.
        _log.info('engine.output listener fired bytes=${bytes.length} _exited=${_exited.value}');
        if (_exited.value) return;
        _log.info('engine.output listener pre-pty.write bytes=${bytes.length}');
        pty.write(bytes);
        _log.info('engine.output listener post-pty.write bytes=${bytes.length}');
      },
    );
    _outputSub = pty.output.listen(
      (bytes) {
        if (!_hasReceivedOutput.value) {
          _hasReceivedOutput.value = true;
          _slowHintTimer?.cancel();
          _log.info('FIRST PTY OUTPUT: ${bytes.length} bytes (after ${DateTime.now().millisecondsSinceEpoch - _startTimeMs}ms)');
        }
        _log.info('pty.output listener fired bytes=${bytes.length} _exited=${_exited.value}');
        if (_exited.value) return;
        // `feedWithKitty` answers Kitty keyboard-protocol capability
        // queries (`CSI ? u`) and applies flag pushes (`CSI > ... u`),
        // writing responses back via `engine.write` (= PTY input). Apps
        // like opencode / Claude Code / Codex CLI enable flag 1
        // ("disambiguate escape codes") in response, which makes
        // Shift+Enter arrive as `CSI 13 ; 2 u` instead of legacy `\r` —
        // matching how real alacritty behaves and giving those TUIs a
        // way to bind multiline entry to Shift+Enter.
        _engine.feedWithKitty(bytes);
      },
      onDone: () {
        _log.info('PTY output stream done; calling _markExited');
        _markExited();
      },
    );
    pty.exitCode.then((code) {
      _log.info('PTY exitCode=$code');
      _markExited();
    });
  }

  late final int _startTimeMs = DateTime.now().millisecondsSinceEpoch;

  void _markExited() {
    if (_exited.value || !mounted) return;
    _log.fine('_markExited fired');
    _exited.value = true;
    // We intentionally do NOT call _pty?.close() here. On Windows,
    // ClosePseudoConsole blocks the caller while the C-side read thread
    // is still in ReadFile on the ConPTY output pipe, and that read only
    // unwinds once the pipe handle is closed by the kernel — which the
    // read thread itself owns. The pty_write liveness check (C-side
    // WaitForSingleObject on the duplicated process handle) already
    // makes post-exit writes a no-op, so the orphaned-ConPTY blocking
    // issue is addressed without needing to call pty.close. The OS
    // reclaims the ConPTY handle when the host process exits.
    widget.onExited?.call();
    _log.fine('_markExited post-onExited');
  }

  // ── Engine → host signal forwarding ──────────────────────────────

  void _syncTitle() {
    final title = _engine.title.value;
    if (title == _lastTitle) return;
    _lastTitle = title;
    widget.onTitleChanged?.call(title);
  }

  void _syncPwd() {
    final pwd = _engine.workingDir.value;
    if (pwd == _lastPwd) return;
    _lastPwd = pwd;
    widget.onPwdChanged?.call(pwd);
  }

  // ── Focus ────────────────────────────────────────────────────────

  /// Request input focus for this terminal.
  void requestFocus() => _focus.requestFocus();

  /// Whether this terminal currently has input focus.
  bool get hasFocus => _focus.hasFocus;

  // ── Font zoom ────────────────────────────────────────────────────
  //
  // Font-size state lives in alacritty's engine (the engine holds the
  // configured font size and re-emits it on `reconfigure(...)`). Our
  // job is to mirror it locally so the `fa.TerminalStyle` we pass to
  // `fa.TerminalView` matches the engine's view of the world. The
  // `Ctrl+=` / `Ctrl+-` / `Ctrl+0` shortcuts are wired directly into
  // alacritty's `defaultTerminalActions` via the extended
  // `shortcuts:` map we hand `fa.TerminalView` in `build()` — see
  // `_alacrittyShortcutsWithShiftVariants` below.

  void _onViewportResize(int cols, int rows) {
    _log.fine('_onViewportResize: cols=$cols rows=$rows (engine grid=${_engine.grid.rows}x${_engine.grid.columns} gen=${_engine.grid.generation})');
    _pty?.resize(rows, cols);
  }

  // ── Mouse: right-click = copy/paste, left-click = focus ────────────

  Future<void> _onSecondaryTapUp(
    TapUpDetails details,
    fa.CellOffset cell,
  ) async {
    // Alacritty's right-click convention: copy if there's a selection,
    // otherwise paste from the system clipboard.
    final text = _engine.selectionText();
    if (text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
    } else {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final t = data?.text;
      if (t != null && t.isNotEmpty) {
        _controller.onTerminalInputStart();
        _engine.write(_pasteBytes(t, modeFlags: _engine.grid.modeFlags));
      }
    }
  }

  // ── Clipboard / readline shortcuts ────────────────────────────────

  void _sendCtrlU() => _engine.write(Uint8List.fromList([0x15]));
  void _sendCtrlK() => _engine.write(Uint8List.fromList([0x0b]));
  void _sendCtrlL() => _engine.write(Uint8List.fromList([0x0c]));
  void _sendCtrlA() => _engine.write(Uint8List.fromList([0x01]));
  void _sendCtrlE() => _engine.write(Uint8List.fromList([0x05]));

  void _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text;
    if (t == null || t.isEmpty) return;
    _controller.onTerminalInputStart();
    _engine.write(_pasteBytes(t, modeFlags: _engine.grid.modeFlags));
  }

  void _copySelectionToClipboard() {
    final text = _engine.selectionText();
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  void _scrollPage(int direction) {
    final rows = _engine.grid.rows;
    if (rows <= 0) return;
    _engine.scrollLines(rows * direction);
  }

  /// Fast scroll — used by `Shift+PageUp/Down`. Steps 5 pages at a
  /// time so users can blow through long scrollback without mashing
  /// the key.
  void _scrollPageFast(int direction) => _scrollPage(direction * 5);

  // ── Alacritty shortcut map (zoom extensions) ────────────────────
  //
  // Alacritty owns font-size state — re-emitting it through
  // `_engine.reconfigure(_buildConfig())` requires engine-level access
  // we don't (and shouldn't) duplicate. Instead, we hand
  // `fa.TerminalView` a shortcuts map that bundles alacritty's
  // stock `defaultTerminalShortcuts` with our `Ctrl+Shift+…` variants
  // — the upstream alacritty project only configures the unshifted
  // forms (`Ctrl+=` / `Ctrl+-` / `Ctrl+0`), so without the shift
  // extensions a `Ctrl+Shift+=` press would fall through to
  // `encodeKey` and write `+` into the PTY instead of zooming.
  //
  // `fa.TerminalView`'s `_onKeyFallback` consults
  // `widget.shortcuts ?? defaultTerminalShortcuts`, so by passing a
  // non-null map we fully replace the stock bindings with this
  // extended set. We must therefore explicitly re-include every
  // binding alacritty ships in `defaultTerminalShortcuts` (Copy,
  // Paste, ToggleSearch, plus the unshifted zoom forms).
  static final Map<ShortcutActivator, Intent>
      _alacrittyShortcutsWithShiftVariants = <ShortcutActivator, Intent>{
    ...defaultTerminalShortcuts,
    // Shift variants of the zoom bindings. The unshifted forms are
    // already in `defaultTerminalShortcuts` — we only need to add
    // the shift variants alacritty doesn't ship.
    SingleActivator(LogicalKeyboardKey.equal,
        control: true, shift: true): const IncreaseFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.add,
        control: true, shift: true): const IncreaseFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.minus,
        control: true, shift: true): const DecreaseFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.numpadSubtract,
        control: true, shift: true): const DecreaseFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.digit0,
        control: true, shift: true): const ResetFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.numpad0,
        control: true, shift: true): const ResetFontSizeIntent(),
  };

  // ── Public action API ────────────────────────────────────────────
  //
  // These public mirrors of the private methods above are the
  // dispatch targets for the app-level `HardwareKeyboard` handler
  // installed by `_AppShellState` (see lib/main.dart). We need a
  // level above `CallbackShortcuts` because `flutter_alacritty`'s
  // `TerminalView` registers a `Focus.onKeyEvent` callback that
  // **consumes every key event** before it can bubble up to ancestor
  // `CallbackShortcuts` widgets. The hardware handler fires before
  // any widget's `onKeyEvent`, so it wins. See the file header in
  // `lib/src/shortcuts/app_shortcuts.dart` for the full reasoning.

  void copySelectionToClipboardPublic() => _copySelectionToClipboard();
  void pasteFromClipboardPublic() => _pasteFromClipboard();
  // Font zoom (`Ctrl+=` / `Ctrl++` / `Ctrl+-` / `Ctrl+0` and the
  // `Ctrl+Shift+…` variants) is owned by alacritty itself — we
  // extend `fa.TerminalView`'s stock `defaultTerminalShortcuts` with
  // the shift variants in `_alacrittyShortcutsWithShiftVariants`,
  // and alacritty's default action handlers dispatch the bundled
  // `IncreaseFontSizeIntent` / `DecreaseFontSizeIntent` /
  // `ResetFontSizeIntent`. No public mirror here — `main.dart`'s
  // early-key handler doesn't reach us for zoom.
  void scrollPagePublic(int direction) => _scrollPage(direction);
  void scrollPageFastPublic(int direction) => _scrollPageFast(direction);

  // ── Build ────────────────────────────────────────────────────────

@override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        ...TerminalBindings.build(
          copySelection: _copySelectionToClipboard,
          paste: _pasteFromClipboard,
          scrollPageUp: () => _scrollPage(-1),
          scrollPageDown: () => _scrollPage(1),
          scrollPageUpFast: () => _scrollPageFast(-1),
          scrollPageDownFast: () => _scrollPageFast(1),
        ),
        // Readline-style Ctrl+U/K/L/A/E — write raw control bytes
        // through the PTY so the shell receives them. These are the
        // bare Ctrl-letter shortcuts that the audit explicitly says
        // we MUST leave alone for readline compatibility; the factory
        // doesn't include them because their payload is a byte, not
        // a VoidCallback.
        primary(LogicalKeyboardKey.keyU): _sendCtrlU,
        primary(LogicalKeyboardKey.keyK): _sendCtrlK,
        primary(LogicalKeyboardKey.keyL): _sendCtrlL,
        primary(LogicalKeyboardKey.keyA): _sendCtrlA,
        primary(LogicalKeyboardKey.keyE): _sendCtrlE,
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
// fa.TerminalView directly (no outer GestureDetector /
// Listener / MouseRegion wrapper). Reasoning:
//   * The original v6.0.0 tree wrapped fa.TerminalView in a
//     GestureDetector whose internal `RenderPointerListener`
//     silently swallowed `PointerHoverEvent` (no matching
//     callback → no `super.handleEvent` forwarding), so the
//     I-beam cursor never appeared at the pane edges.
//   * The pane-edge cursor + selection bug was traced (v6.0.1
//     investigation) to the always-present translucent `MetaData`
//     of `_PaneDropOverlay`'s four `_EdgeSplitZone` DragTargets
//     — fixed by rendering them only while a tab drag is in
//     flight (see pane_tree.dart).
//   * fa.TerminalView calls `_focus.requestFocus()` inside its
//     own `__pointerOnDown`, and carries its own `MouseRegion`
//     that dynamically resolves to text / click based on cell
//     content (link detection).
//
// `padding: EdgeInsets.symmetric(horizontal: cellWidthHalf)` —
// ~half a letter width. fa.TerminalView uses `widget.padding`
// to shrink the available area before computing cols/rows (so the
// PTY grid sizes to the padded area, not the full pane — last
// column wouldn't be clipped), then wraps the tree in a Padding.
// Cascadia Code is roughly `fontSize * 0.6` wide per glyph at
// the default lineHeight, so half-letter ≈ `fontSize * 0.3`.
Positioned.fill(
  child: fa.TerminalView(
    _engine,
    controller: _controller,
    focusNode: _focus,
    autofocus: true,
    padding: EdgeInsets.symmetric(horizontal: _fontSize * 0.3),
    // Pass the actual font size/family to fa.TerminalView so its
    // internal cell metrics match ours. Without this, fa.TerminalView
    // uses `TerminalStyle.defaults()` (size: 14) regardless of our
    // settings, which causes LayoutBuilder to compute a wrong grid
    // size and triggers a cascading `_engine.resize` + `_pty.resize`
    // on every settings change → some shells clear their screen on
    // TIOCSWINSZ (cmd.exe, WSL bash with certain configs), wiping
    // the visible content.
    textStyle: fa.TerminalStyle(
      family: widget.settings.fontFamily,
      fallback: const [
        _cjkFontFamily,
        'Microsoft YaHei UI',
        'SimSun',
        'Consolas',
        'monospace',
      ],
      size: _fontSize,
      lineHeight: _lineHeight,
    ),
    // Font zoom — let alacritty own it. We pass `defaultTerminalShortcuts`
    // plus our shift variants so users who hold Shift while pressing
    // `=` / `-` / `0` (yielding `+` / `_` / `)` on US layouts) get
    // zoom too. Alacritty's stock `defaultTerminalShortcuts` only
    // ships the unshifted forms (`Ctrl+=`, `Ctrl+-`, `Ctrl+0`), so
    // without this merge a `Ctrl+Shift+=` press would fall through
    // to `encodeKey` and write `+` into the PTY.
    shortcuts: _alacrittyShortcutsWithShiftVariants,
    // Visual bell: fa.TerminalView paints its own overlay when
    // bellDuration > zero (driven by settings.bellMode == visual).
    bellDuration: _bellDurationForView,
    onViewportResize: _onViewportResize,
    onSecondaryTapUp: _onSecondaryTapUp,
  ),
),
            SignalBuilder(
              builder: (_) => _exited.value
                  ? const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black54,
                        child: Center(
                          child: Text(
                            '[process exited]',
                            style: TextStyle(
                              color: Color(0xFFBDBDBD),
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            SignalBuilder(
              builder: (_) {
                if (_hasReceivedOutput.value || _exited.value) {
                  return const SizedBox.shrink();
                }
                return Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Color(0xFF89B4FA),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Starting shell…',
                              style: TextStyle(
                                color: Color(0xFFBDBDBD),
                                fontSize: 13,
                              ),
                            ),
                            SignalBuilder(
                              builder: (_) => _showSlowHint.value
                                  ? const Padding(
                                      padding: EdgeInsets.only(top: 6),
                                      child: Text(
                                        'WSL cold start can take 10-30 s on first launch.',
                                        style: TextStyle(
                                          color: Color(0xFF7F7F7F),
                                          fontSize: 11,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
],
        ),
      );
  }

  @override
  void dispose() {
    _slowHintTimer?.cancel();
    _outputSub?.cancel();
    _engineOutputSub?.cancel();
    _clipSub?.cancel();
    _clipLoadSub?.cancel();
    _bellSub?.cancel();
    _controller.removeListener(_onControllerChanged);
    _engine.title.removeListener(_syncTitle);
    _engine.workingDir.removeListener(_syncPwd);
    _pty?.kill();
    _controller.dispose();
    _engine.dispose();
    // _focus is BORROWED from widget.surface.focusNode — Surface owns
    // it and disposes in its own dispose(). Do NOT call _focus.dispose()
    // here or you'll dispose a node that the workspace may still hold
    // (and Flutter will assert on the double-free).
    super.dispose();
  }
}

/// Encode [text] for PTY paste. Wraps the payload in ESC[200~ … ESC[201~
/// when bracketed paste is active and strips ESC/Ctrl+C to keep the
/// bracketed sequence intact. Mirrors flutter_alacritty's
/// `input/paste.dart::pasteBytes` (kept local so we don't depend on an
/// implementation import).
Uint8List _pasteBytes(String text, {required int modeFlags}) {
  // Bracketed-paste mode bit = 0x20000000 (BRACKETED_PASTE in
  // alacritty's TermModeFlags).
  const bracketedPasteFlag = 0x20000000;
  if (modeFlags & bracketedPasteFlag != 0) {
    final safe = text.replaceAll(RegExp(r'[\x1b\x03]'), '');
    return Uint8List.fromList([
      ...'\x1b[200~'.codeUnits,
      ...utf8.encode(safe),
      ...'\x1b[201~'.codeUnits,
    ]);
  }
  return Uint8List.fromList(utf8.encode(text));
}
