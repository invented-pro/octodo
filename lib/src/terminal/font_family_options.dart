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
// Linux has no `just_font_scan` backend, so there we shell out to
// fontconfig's `fc-list` instead (see [_enumerateLinux]). Every
// desktop Linux ships fontconfig — GTK3 itself depends on it — and
// Alacritty's own Linux font lookup goes through fontconfig (via
// crossfont), so the names `fc-list` reports are exactly the names
// the terminal renderer can resolve.
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
//     previously picked never disappears from the picker — even a
//     dead stored value stays visible until re-picked);
//   * the well-known monospace + CJK faces the terminal explicitly
//     requires as fallbacks, gated to the *current* platform via
//     `Platform.is*` AND (once a scan has completed) to faces the
//     scan actually found — an entry for a font that was never
//     installed is how a dead family reaches the renderer (GH #11);
//   * every family `just_font_scan` reports (sorted, deduplicated).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart'
    show ByteData, FontLoader, rootBundle;
import 'package:flutter/widgets.dart';
import 'package:just_font_scan/just_font_scan.dart';

/// The family name of the monospace font bundled with the app
/// (assets/fonts/JetBrainsMono-NFM-subset.ttf — a subset of JetBrains
/// Mono Nerd Font Mono, see assets/fonts/NOTICE.md). It is loaded via
/// [loadBundledTerminalFonts] at startup, so it resolves through
/// Flutter's dynamic font manager without touching fontconfig /
/// CoreText / DirectWrite and can never be substituted.
///
/// It is the terminal's **default font on every platform** — one
/// default everywhere, so there is no per-OS face that could be
/// missing, substituted, or measured differently — and serves two
/// further roles:
///   * last-resort primary when the configured family is not installed
///     (a request for a missing family never fails on Linux —
///     fontconfig silently substitutes a proportional face, which is
///     exactly the wide-spacing corruption of GH #11);
///   * last entry of the render fallback chain, where its Nerd Font
///     icon codepoints render powerline/starship/eza glyphs for users
///     whose own font is not a Nerd Font.
const String kBundledMonoFamily = 'JetBrainsMono NFM';

/// Asset path of the bundled fallback font.
const String kBundledMonoAsset = 'assets/fonts/JetBrainsMono-NFM-subset.ttf';

/// Load [kBundledMonoFamily] into the engine's dynamic font manager.
/// Must complete before the font can resolve; called from `main()`
/// before the first terminal view measures its cell metrics, so the
/// safe fallback is always usable by the time any widget needs it.
Future<void> loadBundledTerminalFonts() async {
  try {
    final data = await rootBundle.load(kBundledMonoAsset);
    final loader = FontLoader(kBundledMonoFamily);
    loader.addFont(Future<ByteData>.value(data));
    await loader.load();
  } catch (_) {
    // Without the bundle (stripped asset tree, test harness) the
    // platform defaults still work; the settings resolver just skips
    // this family.
  }
}

/// Process-wide knowledge of which font families are actually
/// installed on the host, fed by the same enumeration the settings
/// dropdown uses ([scanInstalledFontFamilies]).
///
/// Consumers ask [isAvailable] before handing a family string to the
/// renderer. Until the first scan lands, unknown families are
/// optimistically reported available: blocking first paint on a
/// several-hundred-ms font scan would trade a rare mis-resolution for
/// a guaranteed startup stall (the bundled default is trusted by
/// construction — it resolves in-engine). Once a scan completes, the
/// answer becomes authoritative — an uninstalled configured family is
/// re-pinned to the bundled default on the next settings snapshot.
///
/// It is a [ChangeNotifier]: every authoritative [apply] notifies, so
/// live terminal views can re-resolve their (primary, fallback) pair
/// (a dead pick that rendered optimistically until the scan landed
/// gets pinned) and the terminal view's Latin-advance memo can be
/// dropped.
class InstalledFontRegistry extends ChangeNotifier {
  InstalledFontRegistry._();

  /// Singleton — the installed font set is a property of the host.
  static final InstalledFontRegistry instance = InstalledFontRegistry._();

  Set<String> _installed = const <String>{};
  bool _loaded = false;

  /// True once at least one scan has been applied (authoritative mode).
  bool get loaded => _loaded;

  /// Whether [family] is installed on this host.
  ///
  /// The bundled font ([kBundledMonoFamily]) is always available once
  /// [loadBundledTerminalFonts] has run — it loads into the engine
  /// itself rather than the OS font collection. Comparison is
  /// case-insensitive: enumerators and resolvers disagree on casing
  /// for some localized family names.
  bool isAvailable(String family) {
    final f = family.trim();
    if (f.isEmpty) return false;
    if (f == kBundledMonoFamily) return true;
    if (!_loaded) return true; // optimistic until the first scan lands
    return _installed.contains(f.toLowerCase());
  }

  /// Replace the registry contents with a fresh scan result, switch
  /// to authoritative mode, and notify listeners.
  void apply(List<String> families) {
    _installed = {
      for (final f in families) f.trim().toLowerCase(),
    };
    _loaded = true;
    notifyListeners();
  }

  /// Drop back to optimistic mode and forget the scan result.
  /// Test seam; production never calls this.
  @visibleForTesting
  void resetForTest() {
    _installed = const <String>{};
    _loaded = false;
  }
}

/// Populate [InstalledFontRegistry] at startup.
///
/// On Linux the fc-list enumeration is cheap (~tens of ms), so it is
/// awaited — the settings store reads `terminal.fontFamily` during
/// construction and can validate immediately. On Windows/macOS the
/// DirectWrite/CoreText scan costs a few hundred ms, so it runs in
/// the background: the first frames render with the optimistic
/// registry (see [InstalledFontRegistry.isAvailable]) and a dead
/// configured family is sanitized a moment later, when the snapshot
/// listener re-resolves after the scan applies.
Future<void> warmInstalledFontRegistry() async {
  if (Platform.isLinux) {
    try {
      final families = await Isolate.run(_enumerateLinux);
      InstalledFontRegistry.instance.apply(families);
      return;
    } catch (_) {
      // fall through to the generic background scan
    }
  }
  unawaited(
    scanInstalledFontFamilies()
        .then(InstalledFontRegistry.instance.apply)
        .catchError((_) {}),
  );
}

/// Well-known monospace faces pre-installed per-platform plus the
/// CJK families the terminal renderer wires up as fallback glyphs.
/// Listed in priority order: most-preferred monospace pick →
/// western fallbacks → cross-platform supplemental faces → CJK
/// fallbacks → the bundled monospace font, which resolves in-engine
/// on every host.
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
  // Distros vary too much to pin Latin faces; the default is the
  // bundled font on every platform, so no curated Latin entries.
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
///
/// The list ends with the bundled font (not the `'monospace'` CSS
/// keyword, which the engine's desktop resolver does not reliably
/// parse): once a scan completes, `mergeFontFamilies` gates these
/// entries against the installed set, and the bundled font is the
/// only entry guaranteed to survive that gate everywhere.
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
  return [...latin, ..._kSupplementalFonts, ...cjk, kBundledMonoFamily];
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
/// Per-platform: Windows ships YaHei + SimSun + Consolas; macOS ships
/// Hiragino + PingFang + Courier; Linux standardises on Noto CJK.
/// The chain always terminates in the bundled font [kBundledMonoFamily]:
/// it resolves in-engine (no OS font collection involved, so no
/// substitution), is genuinely monospace, and carries the Nerd Font
/// icon codepoints that user fonts without the Nerd Fonts patch are
/// missing (powerline separators, starship/p10k/eza glyphs).
List<String> get defaultPlatformFontFallback {
  if (Platform.isWindows) {
    return const ['Microsoft YaHei UI', 'SimSun', 'Consolas', kBundledMonoFamily];
  }
  if (Platform.isMacOS) {
    return const ['Hiragino Sans', 'PingFang SC', 'Courier', kBundledMonoFamily];
  }
  return const ['Noto Sans Mono CJK SC', kBundledMonoFamily];
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
/// Runs via `Isolate.run` so the DirectWrite / CoreText / fontconfig
/// call walks the full system font collection off the UI thread.
/// Returns `[]` on platforms with no enumeration backend (anything
/// other than Windows, macOS and Linux). Native enumeration
/// failures **propagate to the caller**: an empty list from a
/// swallowed error would be applied as an authoritative "zero fonts
/// installed" (see [InstalledFontRegistry.apply]) and silently pin
/// every live terminal to the bundled font, so callers must be able
/// to tell a failed scan apart from a genuinely empty collection.
///
/// Linux exception: when `fc-list` is missing entirely
/// (container/minimal installs) the enumeration returns `[]` rather
/// than throwing — in that environment nothing but the bundled font
/// resolves anyway, so an authoritative empty registry is correct.
///
/// The caller is expected to feed the result into
/// [mergeFontFamilies] with whatever `pinCurrent` it currently
/// wants pinned at the top of the dropdown. Splitting the scan
/// from the merge avoids a race where a user picks a new font
/// while the worker isolate is still running: if the pin were
/// baked into this call, the late-resolving Future would
/// overwrite the dropdown with a list keyed on the *old* value
/// and drop the user's just-picked entry.
Future<List<String>> scanInstalledFontFamilies() {
  return Isolate.run<List<String>>(
    _enumerateInBackground,
    debugName: 'FontFamilyOptions.enumerate',
  );
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
      // Every completed scan also refreshes the process-wide
      // availability registry, so a family the user just uninstalled
      // is re-validated on the next settings snapshot.
      InstalledFontRegistry.instance.apply(result);
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
/// Dispatches per-OS: DirectWrite (Windows) / CoreText (macOS) via
/// `JustFontScan`, fontconfig via `fc-list` on Linux. All the file
/// I/O stays off the UI isolate. Returns family *names* only —
/// `JustFontScan` also exposes per-face details (weight, style,
/// file path, monospace flag, variation axes) which are not needed
/// by the dropdown yet but would be the entry point for richer UI
/// (weight picker, file-pinning, etc.) later.
List<String> _enumerateInBackground() {
  if (Platform.isLinux) return _enumerateLinux();
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
  } on Object catch (e) {
    // DirectWrite / CoreText failures propagate (they surface out
    // of `Isolate.run` to the caller of scanInstalledFontFamilies):
    // a failed scan must never be conflated with "zero fonts
    // installed" — see that function's doc.
    throw StateError('system font enumeration failed: $e');
  }
}

/// Enumerate installed font families on Linux via fontconfig's
/// `fc-list`.
///
/// Fontconfig is a hard dependency of every desktop Linux (GTK3
/// links against it), and Alacritty's Linux font matching goes
/// through fontconfig itself, so the reported names round-trip
/// exactly into `terminal.fontFamily`.
///
/// Primary query `fc-list --format='%{family[0]}\n'` prints one
/// *primary* family per installed face — indexed element access
/// drops the per-face compound names ("Noto Sans Khmer SemiBold")
/// that DirectWrite/CoreText grouping also hides, so the dropdown
/// lists families at the same granularity as on Windows/macOS.
///
/// Family names are preserved exactly as `fc-list` serialises
/// them, including fontconfig's backslash escapes (`\-`, `\,`).
/// That is deliberate: the value is handed back to fontconfig by
/// the renderer, and fc-list's escaped form is the spelling
/// fontconfig's pattern parser matches (an unescaped name can fail
/// `fc-match` for faces whose names contain escaped characters).
///
/// If the `--format` element index isn't supported by an old
/// fontconfig, falls back to the classic `fc-list : family` form,
/// which comma-joins each face's family list — there we keep only
/// the first comma field. If `fc-list` is missing entirely
/// (container/minimal installs), returns `[]` and the dropdown
/// keeps its curated fallback list.
List<String> _enumerateLinux() {
  final indexed = _runFcList(const ['--format=%{family[0]}\n']);
  if (indexed != null) {
    return parseFontconfigFamilyLines(indexed);
  }
  final legacy = _runFcList(const [':', 'family']);
  if (legacy == null) return const <String>[];
  return parseFontconfigFamilyLines(legacy, firstCommaFieldOnly: true);
}

/// Run `fc-list` with [args], returning stdout (utf-8, malformed
/// bytes tolerated — a stray invalid byte in one exotic font name
/// must not nuke the whole listing) or null if the binary is
/// missing / the invocation fails / the exit code is non-zero.
String? _runFcList(List<String> args) {
  try {
    final result = Process.runSync(
      'fc-list',
      args,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (result.exitCode != 0) return null;
    final stdout = result.stdout;
    if (stdout is! String) return null;
    return stdout;
  } catch (_) {
    return null;
  }
}

/// Parse `fc-list` output into a sorted, deduplicated list of
/// family names.
///
/// [firstCommaFieldOnly] selects the legacy `fc-list : family`
/// shape, where each line comma-joins a face's family list
/// ("Noto Sans,Noto Sans Condensed SemiBold") and only the first
/// field is the family. The `--format=%{family[0]}` shape already
/// emits one family per line, so comma-splitting is skipped there.
///
/// Blank lines are dropped; everything else is kept verbatim
/// (including fontconfig escapes — see [_enumerateLinux]).
@visibleForTesting
List<String> parseFontconfigFamilyLines(
  String output, {
  bool firstCommaFieldOnly = false,
}) {
  final names = <String>{};
  for (var line in output.split('\n')) {
    if (firstCommaFieldOnly) {
      final comma = _indexOfListSeparator(line);
      if (comma >= 0) line = line.substring(0, comma);
    }
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    names.add(trimmed);
  }
  return names.toList()..sort();
}

/// Index of the first comma in [line] that *separates* two family
/// names, i.e. one not escaped as `\,` by fontconfig's serializer.
/// A family containing a literal comma is serialised as
/// `Foo\,Bar` — splitting at that comma would truncate the name to
/// `Foo\`, so backslash-escaped characters are skipped wholesale
/// (this also correctly steps over `\\` and any other escape).
int _indexOfListSeparator(String line) {
  for (var i = 0; i < line.length; i++) {
    if (line.codeUnitAt(i) == 0x5C) {
      i++; // skip the escaped character
      continue;
    }
    if (line.codeUnitAt(i) == 0x2C) return i;
  }
  return -1;
}

/// Merge the off-isolate discoveries with the fallback list and the
/// caller's pinned current value. Order:
///
///   1. Pinned current value (if any), at the top — even when the
///      scan says it is not installed, so the user can always see
///      (and re-pick away from) a dead stored value.
///   2. Fallback monospace / CJK faces for the current platform,
///      in priority order.
///   3. Discovered faces, sorted A→Z (case-insensitive, with a
///      case-sensitive tie-breaker so 'A' comes before 'a').
///
/// With [installedOnly] set (the caller has a completed scan in
/// hand), tier 2 keeps only curated faces the scan actually found on
/// this machine. Without a scan result the curated tier renders
/// immediately while the enumeration is in flight — but offering
/// e.g. "Fira Code" on a machine where it was never installed is how
/// a dead family ends up in settings.json and reaches the renderer
/// (GH #11), so completed scans must always pass `installedOnly:
/// true`.
///
/// Public so UI code can call it after the await on
/// [scanInstalledFontFamilies] with the latest pin value, instead
/// of having [loadInstalledFontFamilies] bake the pin in at call
/// time (which races against the user changing the selection
/// during the scan).
List<String> mergeFontFamilies({
  required List<String> installed,
  String? pinCurrent,
  bool installedOnly = false,
}) {
  final seen = <String>{};
  final out = <String>[];

  void add(String s) {
    if (s.isEmpty) return;
    if (seen.add(s)) out.add(s);
  }

  if (pinCurrent != null) add(pinCurrent);

  if (installedOnly) {
    final present = {for (final f in installed) f.trim().toLowerCase()};
    for (final f in _knownMonospaceFonts) {
      // The bundled font is not in any OS scan output but is always
      // selectable — it lives in the engine's dynamic font manager.
      if (f == kBundledMonoFamily || present.contains(f.toLowerCase())) {
        add(f);
      }
    }
  } else {
    for (final f in _knownMonospaceFonts) {
      add(f);
    }
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
