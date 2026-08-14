// Font-family enumeration for the Terminal settings UI.
//
// The terminal is configured by `terminal.fontFamily`, which the
// renderer passes straight to Alacritty's `font:` config — so the
// value must match a family the OS actually exposes. We can't just
// hard-code a list of "common" monospace faces, because the user may
// have installed any number of custom fonts and will want to pick
// from the real set installed on the machine.
//
// `just_font_scan` uses DirectWrite (Windows) / CoreText (macOS) to
// enumerate system fonts. The OS already groups variant faces under
// a single family — `Arial` comes back as one family with 14 faces
// (Regular, Bold, Italic, Bold Italic, Black, Narrow variants, etc.)
// rather than four separate entries per weight/style suffix. That
// eliminates the post-processing the previous `system_fonts`-based
// implementation had to do.
//
// The scan is moderately expensive (a few hundred ms on a typical
// Windows install with hundreds of fonts), so we run it on a worker
// isolate via `Isolate.run` and pin the user's current selection +
// a small monospace/CJK fallback list at the top of the dropdown
// while the enumeration is in flight, so the dialog is interactive
// immediately.
//
// The returned list is the union of:
//   * the user's currently-selected value (so a custom face the user
//     previously picked never disappears from the picker);
//   * the well-known monospace + CJK faces the terminal explicitly
//     requires as fallbacks, gated to the *current* platform via
//     `Platform.is*` — so e.g. "Microsoft YaHei" (a Windows font)
//     never shows up in the dropdown on macOS. These remain present
//     even if the scan returns nothing useful (e.g. on Linux, which
//     `just_font_scan` doesn't support);
//   * every family `just_font_scan` reports (sorted, deduplicated).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:just_font_scan/just_font_scan.dart';

/// Well-known monospace faces pre-installed per-platform plus the
/// CJK families the terminal renderer wires up as fallback glyphs.
/// Listed in priority order: most-preferred monospace pick →
/// western fallbacks → cross-platform supplemental faces → CJK
/// fallbacks → the generic CSS keyword `monospace`, which every
/// renderer recognises.
///
/// Gated to the current platform via `Platform.is*`: Windows-only
/// faces ("Microsoft YaHei", "SimSun", …) must not appear in the
/// dropdown on macOS, and vice versa. The OS scan would never
/// report them, but this list is merged into the dropdown *before*
/// and *after* the scan resolves, so an ungated entry would leak
/// through on every platform.
const _kWindowsLatinFonts = <String>[
  'Cascadia Code',
  'Cascadia Mono',
  'Consolas',
  'Lucida Console',
  'Courier New',
];

const _kWindowsCjkFonts = <String>[
  'Microsoft YaHei',
  'Microsoft YaHei UI',
  'SimSun',
  'NSimSun',
  'MS Gothic',
  'MS Mincho',
];

const _kMacosLatinFonts = <String>[
  // Pre-installed on every release since 10.6.
  'Menlo',
  'SF Mono',
  'Monaco',
  'Andale Mono',
  'Courier',
];

const _kMacosCjkFonts = <String>[
  'PingFang SC',
  'Hiragino Sans GB',
  'Hiragino Sans',
];

const _kLinuxLatinFonts = <String>[
  // Distros vary too much to pin Latin faces; the generic
  // `monospace` keyword resolves to the distro's default.
];

const _kLinuxCjkFonts = <String>[
  'Noto Sans CJK SC',
  'Noto Sans Mono CJK SC',
];

/// Cross-platform / supplemental monospace faces users commonly
/// install themselves. Kept on every platform.
const _kSupplementalFonts = <String>[
  'PT Mono',
  'JetBrains Mono',
  'Fira Code',
];

/// The well-known fallback list for the current platform only, in
/// priority order (see the per-platform consts above). Reads
/// `Platform.*` at call time, so it cannot be `const`.
List<String> get _knownMonospaceFonts {
  final latin = Platform.isWindows
      ? _kWindowsLatinFonts
      : Platform.isMacOS
      ? _kMacosLatinFonts
      : _kLinuxLatinFonts;
  final cjk = Platform.isWindows
      ? _kWindowsCjkFonts
      : Platform.isMacOS
      ? _kMacosCjkFonts
      : _kLinuxCjkFonts;
  return [...latin, ..._kSupplementalFonts, ...cjk, 'monospace'];
}

/// Per-platform default monospace font. Picked because it ships
/// pre-installed on every supported release of that OS — no setup,
/// no download. The fallback chain in `TerminalView._buildConfig`
/// adds the user's pick + a CJK face; this string is what the
/// fallback chain reduces to when no better candidate is available.
String get defaultPlatformMonospaceFont {
  if (Platform.isWindows) return 'Cascadia Code';
  if (Platform.isMacOS) return 'Menlo';
  return 'monospace';
}

/// Per-platform CJK fallback face. The terminal renderer walks the
/// `FontConfig.fallback` chain for any glyph the primary doesn't
/// carry — CJK chars are the common case. Apple ships Hiragino
/// Sans GB on every release; Linux distros standardise on Noto.
String get defaultPlatformCjkFont {
  if (Platform.isWindows) return 'Microsoft YaHei';
  if (Platform.isMacOS) return 'Hiragino Sans GB';
  return 'Noto Sans CJK SC';
}

/// Extra render-side fallback faces appended to whatever the user
/// picked, so the renderer has a complete (Latin + CJK) chain even
/// before the JustFontScan enumeration resolves on a worker isolate.
/// Per-platform: Windows ships Consolas + SimSun + YaHei; macOS
/// ships Menlo + PingFang + Hiragino; Linux relies on the generic
/// CSS keyword.
List<String> get defaultPlatformFontFallback {
  if (Platform.isWindows) {
    return const ['Microsoft YaHei UI', 'SimSun', 'Consolas', 'monospace'];
  }
  if (Platform.isMacOS) {
    return const ['Hiragino Sans', 'PingFang SC', 'Courier', 'monospace'];
  }
  return const ['Noto Sans Mono CJK SC', 'monospace'];
}

/// The synchronous fallback list for the font dropdown. Used as a
/// starter set while the off-isolate scan is in progress, and as a
/// guaranteed-present set of entries even if the scan fails
/// outright. Contains only the current platform's well-known faces
/// (see [_knownMonospaceFonts]), sorted by its priority order.
List<String> fallbackFontFamilies() =>
    List<String>.unmodifiable(_knownMonospaceFonts);

/// Pinned-current + fallback union, returned synchronously. Caller
/// passes [pinCurrent] (typically the value already stored in
/// `terminal.fontFamily`) so a custom-installed face previously
/// chosen by the user survives any merge.
List<String> initialFontFamilies({String? pinCurrent}) {
  final out = <String>[];
  final seen = <String>{};
  void add(String s) {
    if (s.isEmpty) return;
    if (seen.add(s)) out.add(s);
  }

  if (pinCurrent != null) add(pinCurrent);
  for (final f in _knownMonospaceFonts) {
    add(f);
  }
  return out;
}

/// Asynchronously scan the system font collection on a worker
/// isolate, returning the raw list of installed family names.
///
/// Runs via `Isolate.run` so the DirectWrite / CoreText call walks
/// the full system font collection off the UI thread. Returns `[]`
/// on platforms `just_font_scan` doesn't support (currently Linux)
/// or if the native call throws.
///
/// The caller is expected to feed the result into
/// [mergeFontFamilies] with whatever `pinCurrent` it currently
/// wants pinned at the top of the dropdown. Splitting the scan
/// from the merge avoids a race where a user picks a new font
/// while the worker isolate is still running: if the pin were
/// baked into this call, the late-resolving Future would
/// overwrite the dropdown with a list keyed on the *old* value
/// and drop the user's just-picked entry.
Future<List<String>> scanInstalledFontFamilies() async {
  try {
    return await Isolate.run<List<String>>(
      _enumerateInBackground,
      debugName: 'FontFamilyOptions.enumerate',
    );
  } catch (_) {
    return const <String>[];
  }
}

/// Convenience wrapper around [scanInstalledFontFamilies] +
/// [mergeFontFamilies] for callers that don't need the post-await
/// pin behaviour. Equivalent to:
///
/// ```dart
/// final installed = await scanInstalledFontFamilies();
/// return mergeFontFamilies(installed: installed, pinCurrent: pinCurrent);
/// ```
///
/// Prefer [scanInstalledFontFamilies] directly in any UI code that
/// captures `pinCurrent` from mutable state — see the doc on that
/// function for the race this avoids.
Future<List<String>> loadInstalledFontFamilies({String? pinCurrent}) async {
  final installed = await scanInstalledFontFamilies();
  return mergeFontFamilies(installed: installed, pinCurrent: pinCurrent);
}

/// Owns the system-font scan for the lifetime of the settings
/// dialog. The dialog constructs one in [State.initState], calls
/// [load] once, and exposes it to descendants via
/// [FontFamilyCacheScope] so every font dropdown in the panel
/// reads from the same cache instead of triggering its own scan.
///
/// Caching at this layer (vs. the dropdown) means:
///
///   * The scan runs exactly once per panel-open, not once per
///     dropdown that happens to mount.
///   * The result survives the dropdown being rebuilt (e.g. when
///     the user switches the section General → Terminal, or
///     toggles "Show JSON paths", which rebuilds the detail pane
///     and re-creates the dropdown widget).
///   * When the panel closes, the cache goes with it — no
///     stale global state, no manual invalidation needed.
class FontFamilyCache extends ChangeNotifier {
  FontFamilyCache({Future<List<String>> Function()? scanner})
    : _scanner = scanner ?? scanInstalledFontFamilies;

  final Future<List<String>> Function() _scanner;

  List<String> _fonts = const <String>[];
  bool _loading = false;
  Object? _error;
  bool _disposed = false;

  /// The most recent scan result. Empty until [load] completes at
  /// least once. Listeners are notified when the value changes
  /// (i.e. after the first successful load).
  List<String> get fonts => _fonts;

  /// True while a scan is in flight. Multiple concurrent
  /// [load] calls are coalesced — see [load].
  bool get loading => _loading;

  /// The most recent scan error, or null if the last scan
  /// succeeded. Cleared at the start of each scan.
  Object? get error => _error;

  Future<void>? _inflight;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Kick off (or join) the scan. Idempotent: if a scan is
  /// already in flight, the returned Future completes when that
  /// one finishes. If a scan has already completed, the cached
  /// result is returned immediately without re-scanning.
  Future<void> load() {
    if (_inflight != null) return _inflight!;
    if (_fonts.isNotEmpty) return Future<void>.value();
    _loading = true;
    _error = null;
    notifyListeners();
    _inflight = _runScan();
    return _inflight!;
  }

  Future<void> _runScan() async {
    try {
      final result = await _scanner();
      if (_disposed) return;
      _fonts = result;
      _error = null;
    } catch (e) {
      if (_disposed) return;
      _error = e;
      _fonts = const <String>[];
    } finally {
      _loading = false;
      _inflight = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Forget the cached result. The next [load] will re-scan.
  /// Mainly useful for tests and for the rare "user just
  /// installed a new font and wants to see it" flow.
  void invalidate() {
    _fonts = const <String>[];
    _error = null;
    notifyListeners();
  }
}

/// InheritedWidget that exposes a [FontFamilyCache] to descendants
/// in the settings dialog. Read via [FontFamilyCacheScope.of].
class FontFamilyCacheScope extends InheritedNotifier<FontFamilyCache> {
  const FontFamilyCacheScope({
    super.key,
    required FontFamilyCache super.notifier,
    required super.child,
  });

  /// The active cache, or null if the widget is mounted outside
  /// the settings dialog. Callers (typically the font dropdown)
  /// should fall back to triggering their own scan when this is
  /// null, so the widget remains usable in bare-AppShell tests.
  static FontFamilyCache? of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<FontFamilyCacheScope>();
    return scope?.notifier;
  }
}

/// Body of the off-isolate worker. Must be a top-level (or static)
/// function — `Isolate.run` cannot capture instance state.
///
/// Pulls the family list out of `JustFontScan`. The DirectWrite /
/// CoreText calls walk the per-OS font collection, so the file
/// I/O stays off the UI isolate. Returns family *names* only —
/// `JustFontScan` also exposes per-face details (weight, style,
/// file path, monospace flag, variation axes) which are not needed
/// by the dropdown yet but would be the entry point for richer UI
/// (weight picker, file-pinning, etc.) later.
List<String> _enumerateInBackground() {
  if (!Platform.isWindows && !Platform.isMacOS) {
    return const <String>[];
  }
  try {
    final families = JustFontScan.scan();
    final names = <String>[];
    for (final f in families) {
      final trimmed = f.name.trim();
      if (trimmed.isEmpty) continue;
      names.add(trimmed);
    }
    return names;
  } catch (_) {
    return const <String>[];
  }
}

/// Merge the off-isolate discoveries with the fallback list and the
/// caller's pinned current value. Order:
///
///   1. Pinned current value (if any), at the top.
///   2. Fallback monospace / CJK faces for the current platform,
///      in priority order.
///   3. Discovered faces, sorted A→Z (case-insensitive, with a
///      case-sensitive tie-breaker so 'A' comes before 'a').
///
/// Public so UI code can call it after the await on
/// [scanInstalledFontFamilies] with the latest pin value, instead
/// of having [loadInstalledFontFamilies] bake the pin in at call
/// time (which races against the user changing the selection
/// during the scan).
List<String> mergeFontFamilies({
  required List<String> installed,
  String? pinCurrent,
}) {
  final seen = <String>{};
  final out = <String>[];

  void add(String s) {
    if (s.isEmpty) return;
    if (seen.add(s)) out.add(s);
  }

  if (pinCurrent != null) add(pinCurrent);
  for (final f in _knownMonospaceFonts) {
    add(f);
  }

  final sorted = [...installed]
    ..sort((a, b) {
      final al = a.toLowerCase();
      final bl = b.toLowerCase();
      final cmp = al.compareTo(bl);
      if (cmp != 0) return cmp;
      return a.compareTo(b);
    });
  for (final f in sorted) {
    add(f);
  }
  return out;
}
