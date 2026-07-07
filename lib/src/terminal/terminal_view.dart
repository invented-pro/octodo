import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data' show BytesBuilder;

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
        ResetFontSizeIntent,
        ScrollPageIntent;
import 'package:signals/signals_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../settings/settings_catalog.dart';
import '../log.dart';
import '../shortcuts/app_shortcuts.dart';
import 'pane_tree.dart' show Surface;
import 'terminal_settings_scope.dart';

final Logger _log = moduleLogger('terminal.terminal_view');

/// Immutable snapshot of every user-facing setting that affects the terminal
/// engine (font, background, cursor, scrollback, bell, copy-on-select, and the
/// active palette's terminal color set).
///
/// `TerminalWorkspace` publishes each new snapshot via the
/// [TerminalSettingsScope] inherited notifier. `TerminalView` reads it in
/// `didChangeDependencies`, compares against its cached value, and calls
/// `engine.reconfigure(_buildConfig())` so changes apply live without
/// re-spawning the shell — no widget rebuild, no layout, no paint cascade.
///
/// Value-equality (==/hashCode) drives the change detection;
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
    required this.terminalForeground,
    required this.terminalSelection,
    required this.terminalAnsiColors,
  });

  final String fontFamily;
  final double fontSize;
  final Color backgroundColor;
  final CursorStyle cursorStyle;
  final bool cursorBlink;
  final int scrollbackLines;
  final bool copyOnSelect;
  final BellMode bellMode;

  /// Default foreground color the alacritty renderer applies to cells
  /// with no explicit SGR foreground. Sourced from the active palette's
  /// [ThemePalette.terminalForeground] so picking a light theme also
  /// retints the terminal text — otherwise light themes render light
  /// text on light backgrounds (unreadable). See `palettes.dart`.
  final Color terminalForeground;

  /// Selection highlight color (translucent by convention). Sourced
  /// from the active palette's [ThemePalette.terminalSelection].
  final Color terminalSelection;

  /// 16 ANSI colors in alacritty's canonical order (black, red,
  /// green, yellow, blue, magenta, cyan, white, bright variants).
  /// Sourced from [ThemePalette.terminalAnsiColors] so light-mode
  /// palettes ship lighter ANSI tones that read against the light
  /// surface0 instead of the dark stock defaults.
  final List<Color> terminalAnsiColors;

  TerminalSettings copyWith({
    String? fontFamily,
    double? fontSize,
    Color? backgroundColor,
    CursorStyle? cursorStyle,
    bool? cursorBlink,
    int? scrollbackLines,
    bool? copyOnSelect,
    BellMode? bellMode,
    Color? terminalForeground,
    Color? terminalSelection,
    List<Color>? terminalAnsiColors,
  }) => TerminalSettings(
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: fontSize ?? this.fontSize,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    cursorStyle: cursorStyle ?? this.cursorStyle,
    cursorBlink: cursorBlink ?? this.cursorBlink,
    scrollbackLines: scrollbackLines ?? this.scrollbackLines,
    copyOnSelect: copyOnSelect ?? this.copyOnSelect,
    bellMode: bellMode ?? this.bellMode,
    terminalForeground: terminalForeground ?? this.terminalForeground,
    terminalSelection: terminalSelection ?? this.terminalSelection,
    terminalAnsiColors: terminalAnsiColors ?? this.terminalAnsiColors,
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
          other.bellMode == bellMode &&
          other.terminalForeground == terminalForeground &&
          other.terminalSelection == terminalSelection &&
          _listEq(other.terminalAnsiColors, terminalAnsiColors));

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
    terminalForeground,
    terminalSelection,
    Object.hashAll(terminalAnsiColors),
  );

  /// List equality helper — Dart's `List` lacks a built-in `==`, so
  /// `terminalAnsiColors` would compare by identity and miss any
  /// palette change. Length+element compare is enough since the
  /// palette always returns the same 16-tuple.
  static bool _listEq(List<Color> a, List<Color> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
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

/// Stock 16-color ANSI palette mirroring `fa.TerminalConfig.defaults()`
/// (the canonical alacritty Tango-ish default). Used as the fallback
/// when a [TerminalView] is constructed outside a
/// [TerminalSettingsScope] (the test path); production code always
/// feeds a palette-derived snapshot via [TerminalSettingsScope]. Kept
/// top-level so it's `const`-constructible.
const List<Color> _defaultAnsiColors = [
  Color(0xFF000000),
  Color(0xFFCC0000),
  Color(0xFF4E9A06),
  Color(0xFFC4A000),
  Color(0xFF3465A4),
  Color(0xFF75507B),
  Color(0xFF06989A),
  Color(0xFFD3D7CF),
  Color(0xFF555753),
  Color(0xFFEF2929),
  Color(0xFF8AE234),
  Color(0xFFFCE94F),
  Color(0xFF729FCF),
  Color(0xFFAD7FA8),
  Color(0xFF34E2E2),
  Color(0xFFEEEEEC),
];

/// Fallback [TerminalSettings] used by [TerminalView] only when no
/// [TerminalSettingsScope] is present in the tree (the test path).
/// Matches `fa.TerminalConfig.defaults()` so a bare `TerminalView`
/// looks like a stock alacritty without any caller-supplied settings.
const TerminalSettings _defaultTerminalSettings = TerminalSettings(
  fontFamily: 'Cascadia Code',
  fontSize: 14.0,
  backgroundColor: Color(0xFF181818),
  cursorStyle: CursorStyle.block,
  cursorBlink: true,
  scrollbackLines: 10000,
  copyOnSelect: false,
  bellMode: BellMode.visual,
  terminalForeground: Color(0xFFD8D8D8),
  terminalSelection: Color(0xFF3A6EA5),
  terminalAnsiColors: _defaultAnsiColors,
);

/// Element-wise equality for the 16 ANSI color lists. Used in
/// `didChangeDependencies` to detect a palette-driven reconfigure
/// without falling back to identity comparison (two lists built from
/// the same palette compare equal but are different instances).
bool _ansiListEq(List<Color> a, List<Color> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

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
final fa.TerminalColors _defaultColors = fa.TerminalConfig.defaults().colors;

/// Intent: scroll the scrollback by 5 pages (Shift+PageUp/Down).
///
/// Mirrors the unshifted `ScrollPageIntent` bundled with
/// `flutter_alacritty`, which has no `multiplier` field. We need a
/// distinct intent type so we can wire a different action in
/// [_alacrittyActions] — `defaultTerminalActions` keys actions by
/// `Type`, so a single `ScrollPageIntent` couldn't carry both the
/// 1-page and 5-page behaviors.
class _ScrollFastIntent extends Intent {
  const _ScrollFastIntent(this.up);
  final bool up;
}

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

  // PTY output is coalesced into [_outputBuffer] and flushed once per
  // [_flushInterval] so a `cat` of a large file or a verbose build log
  // doesn't flood the UI isolate with one FFI call per ConPTY read.
  // Without this, kHz-rate chunk arrival saturates the FFI bridge into
  // the Rust alacritty core even though the parser itself is idle.
  // 8 ms is well under one 60 Hz frame and invisible to interactive use.
  final BytesBuilder _outputBuffer = BytesBuilder(copy: false);
  Timer? _flushTimer;
  static const Duration _flushInterval = Duration(milliseconds: 8);

  String _lastTitle = '';
  String _lastPwd = '';

  // ── Settings propagation ────────────────────────────────────────
  //
  // The workspace publishes its [TerminalSettings] via
  // [TerminalSettingsScope]; we cache the latest snapshot here and
  // apply non-font changes through `_engine.reconfigure(...)` on
  // every `didChangeDependencies`. The font size is tracked
  // separately so `Ctrl+0` (zoom-reset) always returns to the
  // user's chosen baseline, not whatever the engine was last
  // reconfigured to.
  TerminalSettings? _settings;

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
  // The primary is always a known-good monospace Latin font; the
  // user's pick goes into the fallback list so it only kicks in for
  // the script it actually covers (e.g. "Adobe Devanagari" for
  // Devanagari glyphs). See _buildConfig for why.
  static const _cjkFontFamily = 'Microsoft YaHei';
  static const _lineHeight = 1.2;
  @visibleForTesting
  static const safeFontFamilyFallback = 'Cascadia Code';

  /// Module-level cache: does [family] have a usable Latin 'W'
  /// advance? Keyed by the raw family string. The result is a
  /// property of the OS font set + the family name, not of any
  /// widget instance, so the cache lives outside the State.
  ///
  /// The OS font set is bounded (typically <1000 faces on a
  /// Windows install), so a plain map doesn't grow without limit
  /// over a session. If the user later installs a new font and
  /// the cache misses, the validation just runs once on the next
  /// rebuild and gets cached.
  static final Map<String, bool> _latinAdvanceCache = <String, bool>{};

  /// Returns `true` if [family] can render the ASCII characters
  /// used by [CellMetrics.measure] ("W"*20). `false` for
  /// script-specific faces (e.g. "Adobe Devanagari", "MS Mincho"),
  /// for non-existent family names, AND for broken faces whose
  /// 'W' glyph exists in the cmap but renders as 0-width — all
  /// three cases would otherwise let `CellMetrics.measure`
  /// return 0 and crash flutter_alacritty's `LayoutBuilder`
  /// with `Infinity or NaN toInt`.
  ///
  /// Detection: lay out "W"*20 in the test family and compare to
  /// the platform default. We use the same probe as the
  /// production measurement (a 20-W string) so the result
  /// predicts the production behavior. Three conditions must
  /// all hold for a family to be "Latin":
  ///
  ///   1. `testTp.width` is positive — a 0-width 'W' (broken
  ///      cmap entry, font still loading, etc.) is treated as
  ///      non-Latin and pinned to the safe fallback.
  ///   2. `testTp.width` is finite — `NaN` / `Infinity` from
  ///      a malformed font are treated as non-Latin.
  ///   3. `testTp.width` differs from the default by more than
  ///      0.1 logical pixels — a missing or non-Latin family
  ///      falls back to the default and produces the same
  ///      width; a real match produces a different width
  ///      (every installed face has at least slightly
  ///      different 'W' metrics from every other one).
  ///
  /// Threshold 0.1px is enough to separate "different face"
  /// from "same face" — the smallest reasonable advance delta
  /// between two distinct installed fonts is well above this
  /// at any default size.
  @visibleForTesting
  static bool hasLatinAdvance(String family) {
    if (family.isEmpty) return false;
    if (family == safeFontFamilyFallback) return true;
    final cached = _latinAdvanceCache[family];
    if (cached != null) return cached;

    const sample = 20;
    const probe = 'W';
    final probeText = probe * sample;
    final defaultTp = TextPainter(
      text: TextSpan(text: probeText, style: const TextStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    final testTp = TextPainter(
      text: TextSpan(
        text: probeText,
        style: TextStyle(fontFamily: family),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final testWidth = testTp.width;
    final result =
        testWidth > 0 &&
        testWidth.isFinite &&
        (testWidth - defaultTp.width).abs() > 0.1;
    _latinAdvanceCache[family] = result;
    return result;
  }

  /// The family to use as the primary in the engine's [FontConfig]
  /// and in `fa.TerminalView`'s [TerminalStyle]. Returns [family]
  /// if it has Latin 'W' advance; otherwise returns
  /// [safeFontFamilyFallback]. The original [family] (when
  /// non-Latin) should still be added to the fallback list so it
  /// covers the script it actually has glyphs for.
  @visibleForTesting
  static String effectiveLatinPrimary(String family) {
    if (family.isEmpty) return safeFontFamilyFallback;
    if (hasLatinAdvance(family)) return family;
    return safeFontFamilyFallback;
  }

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
    // Pull the initial settings from the surrounding
    // TerminalSettingsScope WITHOUT registering a dependency —
    // `dependOnInheritedWidgetOfExactType` isn't safe in initState
    // (the framework hasn't wired up dependencies yet). The first
    // `didChangeDependencies` call picks up the dependency and
    // re-applies if anything raced. Production code always mounts
    // us inside a scope (TerminalWorkspace), but the
    // `?? _defaultTerminalSettings` fallback keeps a stray test
    // harness from crashing if it builds a bare TerminalView.
    _settings =
        context
            .getInheritedWidgetOfExactType<TerminalSettingsScope>()
            ?.notifier
            ?.value ??
        _defaultTerminalSettings;
    _defaultFontSize = _settings!.fontSize;
    _fontSize = _defaultFontSize;
    _copyOnSelect = _settings!.copyOnSelect;
    _bellMode = _settings!.bellMode;
    if (_log.isLoggable(Level.FINE)) {
      _log.fine(
        'initState: creating engine (program="${widget.surface.program}", cwd=${widget.workingDirectory})',
      );
    }

    _engine = fa.TerminalEngine(config: _buildConfig());
    // Gate the FFI getter calls — `engine.grid.rows/columns/generation`
    // each cross the FFI boundary. Once-per-tab today, but the gate
    // also future-proofs against a per-frame caller.
    if (_log.isLoggable(Level.FINE)) {
      _log.fine(
        'initState: engine created, grid rows=${_engine.grid.rows} cols=${_engine.grid.columns} gen=${_engine.grid.generation}',
      );
    }
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
      _log.fine(
        'initState: AFTER resize, grid rows=${_engine.grid.rows} cols=${_engine.grid.columns} gen=${_engine.grid.generation}',
      );
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
        _log.fine(
          'Timer(zero) firing setState; grid rows=${_engine.grid.rows} cols=${_engine.grid.columns} gen=${_engine.grid.generation}',
        );
        setState(() {});
      }
    });
  }

  fa.TerminalConfig _buildConfig() {
    final s = _settings ?? _defaultTerminalSettings;
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
    // Pack the palette's 16 ANSI colors into alacritty's wire format.
    // The TerminalSettings snapshot guarantees length == 16 (asserted
    // by the workspace when it builds the snapshot from a palette);
    // we still check defensively before copyWith so a malformed
    // extension of TerminalSettings can't crash every TerminalView.
    assert(
      s.terminalAnsiColors.length == 16,
      'terminalAnsiColors must be exactly 16 entries',
    );
    final ansiPacked = s.terminalAnsiColors
        .map(_toAlacrittyColor)
        .toList(growable: false);
    return fa.TerminalConfig.defaults().copyWith(
      // Override the full color set: background / foreground / selection
      // / ANSI all come from the active palette's [ThemePalette]
      // terminal palette (resolved in `TerminalWorkspace._initSettings`).
      //
      // The Flutter window + scaffold background (see main.dart) read
      // the same `palette.surface0` so the chrome never flashes a
      // different shade around the terminal grid; the foreground/ANSI
      // swap is what makes picking a light theme actually retint the
      // grid (the previous dark stock defaults produced light text on
      // light backgrounds).
      //
      // alpha is dropped for background/foreground — alacritty's
      // grid is always opaque. The selection overlay keeps its
      // alpha so it tints the cell underneath instead of replacing
      // it (the conventional alacritty behavior).
      colors: defaultColors.copyWith(
        background: _toAlacrittyColor(s.backgroundColor),
        foreground: _toAlacrittyColor(s.terminalForeground),
        selection: _toAlacrittyColor(s.terminalSelection),
        ansi: ansiPacked,
      ),
      font: fa.FontConfig(
        // The primary is the user's pick IF it has a Latin
        // 'W' advance; otherwise we pin to the safe Latin face
        // (Cascadia Code) so the Rust renderer's cell metrics
        // don't degenerate. The non-Latin pick is still added to
        // the fallback list so it covers the script it's meant
        // for (e.g. "Adobe Devanagari" for Devanagari glyphs,
        // "Microsoft YaHei" for CJK). See `hasLatinAdvance`
        // for how the Latin check works and why a script-only
        // face would otherwise crash flutter_alacritty's
        // `CellMetrics.measure` with `Infinity or NaN toInt`.
        family: effectiveLatinPrimary(s.fontFamily),
        fallback: <String>[
          // Only add the user's pick to the fallback when it
          // is NOT already serving as the primary (i.e., when
          // we had to pin the primary to safeFontFamilyFallback
          // because the pick is non-Latin). Latin picks are
          // already the primary, so the fallback would be a
          // no-op for them.
          if (s.fontFamily.isNotEmpty &&
              s.fontFamily != safeFontFamilyFallback &&
              s.fontFamily != effectiveLatinPrimary(s.fontFamily))
            s.fontFamily,
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
      scrolling: fa.ScrollConfig(history: s.scrollbackLines, multiplier: 3),
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-applies the latest [TerminalSettings] from the surrounding
    // [TerminalSettingsScope] to the alacritty engine. Called once
    // after initState (with the same value we already cached) and
    // then every time the workspace publishes a new snapshot via
    // the notifier. No widget rebuild, no layout, no paint — just
    // an FFI `_engine.reconfigure(...)` when non-font fields
    // actually changed.
    final s = TerminalSettingsScope.of(context);
    final old = _settings;
    if (identical(old, s)) return;
    if (old != null && s == old) return;

    _settings = s;

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
    final fontChanged = old == null || _fontSize != s.fontSize;
    if (fontChanged) {
      _fontSize = s.fontSize;
      _defaultFontSize = s.fontSize;
    }

    // Non-font settings need to flow into the engine's live state via
    // _engine.reconfigure (scrollback limit, cursor shape/blink, bell
    // duration, font family, AND the palette-driven terminal colors).
    // Re-apply unconditionally when any of those change — it's a cheap
    // FFI call. The terminal-color fields drive the light/dark retint
    // when the user picks a new palette from the settings dropdown:
    // a switch from Mocha to Latte swaps foreground + the 16 ANSI
    // swatches, so shell apps that emit no SGR color (e.g. `cat`,
    // `ls`) instantly read on the new surface0.
    //
    // Skip reconfigure for font-size-only changes — fa.TerminalView
    // updates its own metrics from the new textStyle and LayoutBuilder
    // recomputes cols/rows. Calling reconfigure AND triggering a resize
    // cascade can wipe scrollback on some shells (cmd.exe + several
    // WSL bash configs clear-on-resize via TIOCSWINSZ). For font-family
    // changes we DO reconfigure so the engine's stored config stays in
    // sync — otherwise new tabs use the old family until restart.
    final colorsChanged =
        old == null ||
        s.backgroundColor != old.backgroundColor ||
        s.terminalForeground != old.terminalForeground ||
        s.terminalSelection != old.terminalSelection ||
        !_ansiListEq(s.terminalAnsiColors, old.terminalAnsiColors);
    final engineSideChange =
        old == null ||
        s.cursorStyle != old.cursorStyle ||
        s.cursorBlink != old.cursorBlink ||
        s.scrollbackLines != old.scrollbackLines ||
        s.bellMode != old.bellMode ||
        s.fontFamily != old.fontFamily ||
        colorsChanged;
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
    if (old != null && s.fontFamily != old.fontFamily) {
      _engine.refreshView();
    }
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
      final isPowerShell =
          realProgram.toLowerCase().contains('pwsh') ||
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

    _log.fine(
      '_start: ptyProgram=$ptyProgram ptyArgs=$ptyArgs (program="${widget.surface.program}") cwd=${widget.workingDirectory}',
    );
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

    _engineOutputSub = _engine.output.listen(pty.write);
    _outputSub = pty.output.listen(
      (bytes) {
        if (!_hasReceivedOutput.value) {
          _hasReceivedOutput.value = true;
          _slowHintTimer?.cancel();
          // Gate the `DateTime.now()` + arithmetic in the message —
          // the framework would skip the emit at OFF level, but
          // argument evaluation still runs otherwise.
          if (_log.isLoggable(Level.INFO)) {
            _log.info(
              'FIRST PTY OUTPUT: ${bytes.length} bytes (after ${DateTime.now().millisecondsSinceEpoch - _startTimeMs}ms)',
            );
          }
        }
        // Accumulate into [_outputBuffer] and (re)start a one-shot flush
        // timer. The first chunk arms the timer; subsequent chunks within
        // the window are folded into the same batch. The result is one
        // FFI call to `feedWithKitty` per [_flushInterval] instead of one
        // per ConPTY read — see [_flushOutput] and the field doc above.
        _outputBuffer.add(bytes);
        _flushTimer ??= Timer(_flushInterval, _flushOutput);
      },
      onDone: () {
        _log.info('PTY output stream done; calling _markExited');
        // Drain any pending bytes synchronously before signaling exit so
        // the trailing bytes from the dying shell aren't lost or held
        // until the next tick.
        _flushOutput();
        _markExited();
      },
    );
    pty.exitCode.then((code) {
      _log.info('PTY exitCode=$code');
      _markExited();
    });
  }

  late final int _startTimeMs = DateTime.now().millisecondsSinceEpoch;

  /// Drain [_outputBuffer] into one [_engine.feedWithKitty] call.
  ///
  /// `feedWithKitty` answers Kitty keyboard-protocol capability queries
  /// (`CSI ? u`) and applies flag pushes (`CSI > ... u`), writing
  /// responses back via `engine.write` (= PTY input). Apps like opencode
  /// / Claude Code / Codex CLI enable flag 1 ("disambiguate escape
  /// codes") in response, which makes Shift+Enter arrive as `CSI 13 ; 2 u`
  /// instead of legacy `\r` — matching how real alacritty behaves and
  /// giving those TUIs a way to bind multiline entry to Shift+Enter.
  ///
  /// Coalescing the per-chunk FFI calls into one per [_flushInterval]
  /// collapses thousands of micro-FFI calls/sec (under `cat` of a large
  /// file or a build log) into one per frame budget, while keeping
  /// end-to-end latency under one 60 Hz frame.
  void _flushOutput() {
    _flushTimer = null;
    if (_outputBuffer.isEmpty) return;
    final batch = _outputBuffer.takeBytes();
    _outputBuffer.clear();
    _engine.feedWithKitty(batch);
  }

  void _markExited() {
    if (_exited.value || !mounted) return;
    _log.fine('_markExited fired');
    _exited.value = true;
    widget.onExited?.call();
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
    // Gate the three FFI getters — this fires on every drag-resize
    // tick (LayoutBuilder.postFrame → onViewportResize) and the
    // grid property reads cross the FFI boundary.
    if (_log.isLoggable(Level.FINE)) {
      _log.fine(
        '_onViewportResize: cols=$cols rows=$rows (engine grid=${_engine.grid.rows}x${_engine.grid.columns} gen=${_engine.grid.generation})',
      );
    }
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

  Future<void> _onLinkActivate(String uri) async {
    final target = Uri.tryParse(uri);
    if (target == null) return;
    final ok = await launchUrl(target, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open $target')));
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
  //
  // PageUp/PageDown are also wired here — without these, FA's
  // `_onKeyFallback` finds no match, falls through to `encodeKey`,
  // and writes `ESC [ 5 ~` / `ESC [ 6 ~` to the PTY (the shell
  // receives them as a PageUp keypress instead of the scrollback
  // scrolling). Routing through FA's `Shortcuts`/`Actions` lets the
  // match happen BEFORE the encodeKey path runs. `ScrollPageIntent`
  // already has a bundled action in `defaultTerminalActions`: on
  // PageUp it calls `engine.scrollLines(+rows)`, and a positive
  // delta scrolls up into history (see `terminal_engine.dart`),
  // which is the correct PageUp semantics. This is a deliberate
  // direction change from the old app-level binding, which used
  // `scrollLines(-rows)` for PageUp and so scrolled the wrong way
  // (masked in practice because the `?.` dispatch chain usually
  // resolved to a no-op). The Shift variants use a custom intent
  // (see [_ScrollFastIntent]) because the bundled
  // `ScrollPageIntent` has no multiplier and Shift+PageUp/Down is
  // meant to scroll 5 pages at a time.
  static final Map<ShortcutActivator, Intent>
  _alacrittyShortcutsWithShiftVariants = <ShortcutActivator, Intent>{
    ...defaultTerminalShortcuts,
    // PageUp/PageDown → 1-page scrollback scroll.
    SingleActivator(LogicalKeyboardKey.pageUp): const ScrollPageIntent(
      up: true,
    ),
    SingleActivator(LogicalKeyboardKey.pageDown): const ScrollPageIntent(
      up: false,
    ),
    // Shift+PageUp/PageDown → 5-page scrollback scroll. The
    // bundled ScrollPageIntent has no multiplier, so route via
    // a custom intent handled in [_alacrittyActions].
    SingleActivator(LogicalKeyboardKey.pageUp, shift: true):
        const _ScrollFastIntent(true),
    SingleActivator(LogicalKeyboardKey.pageDown, shift: true):
        const _ScrollFastIntent(false),
    // Shift variants of the zoom bindings. The unshifted forms are
    // already in `defaultTerminalShortcuts` — we only need to add the
    // shift variants alacritty doesn't ship.
    SingleActivator(LogicalKeyboardKey.equal, control: true, shift: true):
        const IncreaseFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.add, control: true, shift: true):
        const IncreaseFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.minus, control: true, shift: true):
        const DecreaseFontSizeIntent(),
    SingleActivator(
      LogicalKeyboardKey.numpadSubtract,
      control: true,
      shift: true,
    ): const DecreaseFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.digit0, control: true, shift: true):
        const ResetFontSizeIntent(),
    SingleActivator(LogicalKeyboardKey.numpad0, control: true, shift: true):
        const ResetFontSizeIntent(),
  };

  /// Custom intents dispatched by [_alacrittyShortcutsWithShiftVariants]
  /// whose action handlers don't come from `defaultTerminalActions`.
  ///
  /// Kept as a getter (not a `static final`) so the closure can
  /// capture `this` and call instance methods like `_scrollPageFast`.
  Map<Type, Action<Intent>> get _alacrittyActions => <Type, Action<Intent>>{
    _ScrollFastIntent: CallbackAction<_ScrollFastIntent>(
      onInvoke: (i) {
        _scrollPageFast(i.up ? 1 : -1);
        return null;
      },
    ),
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

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The user's font pick. Used in two places below (the engine
    // config in `_buildConfig` and the widget's `textStyle` here);
    // hoisted to a local so the long conditional in `textStyle`'s
    // fallback list stays readable.
    final fontFamilyPick = (_settings ?? _defaultTerminalSettings).fontFamily;
    return CallbackShortcuts(
      bindings: {
        ...TerminalBindings.build(
          copySelection: _copySelectionToClipboard,
          paste: _pasteFromClipboard,
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
      // Safety-net Focus wrapping the terminal tree. The PRIMARY
      // path for PageUp/PageDown is `fa.TerminalView._onKeyFallback`,
      // which (after the change at `_alacrittyShortcutsWithShiftVariants`
      // above) now finds our `PageUp → ScrollPageIntent` /
      // `PageDown → ScrollPageIntent` binding and invokes the bundled
      // `ScrollPageIntent` action (→ `engine.scrollLines`).
      // That path requires the action lookup to succeed; if it
      // somehow returns null (e.g. an FA Actions-tree quirk in some
      // scenario we haven't reproduced), the event propagates up the
      // focus tree and reaches THIS Focus. We catch plain
      // PageUp/PageDown and Shift+PageUp/PageDown here and call
      // `_scrollPage` / `_scrollPageFast` directly, returning
      // `handled` so the ancestor `CallbackShortcuts` doesn't
      // double-fire. Ctrl/Alt/Meta combinations are intentionally
      // ignored — those belong to other parts of the shortcut system.
      child: Focus(
        onKeyEvent: _handleScrollFallbackKey,
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
                  // Mirror `_buildConfig`: primary is the user's
                  // pick when it has Latin 'W' advance, otherwise
                  // pinned to safeFontFamilyFallback (Cascadia
                  // Code). The non-Latin pick goes into the
                  // fallback list for the script it actually
                  // covers. See `hasLatinAdvance` for the
                  // detection logic and the crash class this
                  // avoids in `CellMetrics.measure`.
                  family: effectiveLatinPrimary(fontFamilyPick),
                  fallback: <String>[
                    if (fontFamilyPick.isNotEmpty &&
                        fontFamilyPick != safeFontFamilyFallback &&
                        fontFamilyPick != effectiveLatinPrimary(fontFamilyPick))
                      fontFamilyPick,
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
                // Custom action handlers for intents whose behavior isn't
                // covered by `defaultTerminalActions` (see
                // [_alacrittyActions]). The `defaultTerminalActions`
                // merge happens inside fa.TerminalView's build, with
                // our overrides layered on top — the ScrollPageIntent
                // bundled handler keeps its 1-page behavior, and our
                // _ScrollFastIntent handler takes over for 5-page
                // scrolling.
                actions: _alacrittyActions,
                // Visual bell: fa.TerminalView paints its own overlay when
                // bellDuration > zero (driven by settings.bellMode == visual).
                bellDuration: _bellDurationForView,
                onViewportResize: _onViewportResize,
                onSecondaryTapUp: _onSecondaryTapUp,
                onLinkActivate: _onLinkActivate,
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
      ),
    );
  }

  /// Second-line handler for PageUp / PageDown / Shift+PageUp /
  /// Shift+PageDown. The PRIMARY path lives inside `fa.TerminalView`
  /// (`_onKeyFallback` → our `ScrollPageIntent` shortcut → bundled
  /// action → `engine.scrollLines`). This handler is the safety net:
  /// if that path returns `ignored` for any reason (e.g. an action
  /// lookup miss), the event propagates up the focus tree to this
  /// `Focus` widget, which intercepts the same set of keys and calls
  /// `_scrollPage` / `_scrollPageFast` directly.
  ///
  /// Modifier policy: only intercept when no Ctrl / Alt / Meta is
  /// pressed. Shift is allowed (and determines 1-page vs 5-page
  /// scroll). Any chord involving Ctrl / Alt / Meta falls through
  /// to the rest of the shortcut system.
  KeyEventResult _handleScrollFallbackKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final isPageUp = event.logicalKey == LogicalKeyboardKey.pageUp;
    final isPageDown = event.logicalKey == LogicalKeyboardKey.pageDown;
    if (!isPageUp && !isPageDown) {
      return KeyEventResult.ignored;
    }
    final direction = isPageUp ? 1 : -1;
    if (hw.isShiftPressed) {
      _scrollPageFast(direction);
    } else {
      _scrollPage(direction);
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _slowHintTimer?.cancel();
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushOutput();
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
