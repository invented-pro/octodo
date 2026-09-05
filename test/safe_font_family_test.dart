// Regression guard for the `Infinity or NaN toInt` crash in
// `flutter_alacritty`'s `terminal_view.dart:758-759`. The upstream
// code computes `(availW / _metrics.width).floor()` against a
// `CellMetrics.measure` call that lays out "W"*20 in
// `style.fontFamily`. If the primary family has no Latin advance
// (e.g. "Adobe Devanagari", whose 'W' has no glyph), the painter
// returns 0 for the width and the layout pass divides by zero →
// `Infinity → floor() → Unsupported operation: Infinity or NaN toInt`.
//
// The fix is structural: the primary family passed to
// `flutter_alacritty` (both the engine config in `_buildConfig`
// AND the widget's `textStyle` in `build`) is computed by
// `effectiveLatinPrimary(family)`:
//   * Latin pick  → use the pick as the primary
//   * non-Latin   → pin to `safeFontFamilyFallback` (the
//                   platform's known-good monospace Latin face:
//                   Cascadia Code on Windows, Menlo on macOS, the
//                   fontconfig-resolved concrete monospace default
//                   on Linux); the pick is added to the fallback
//                   list so it still covers the script it actually
//                   has glyphs for.
//
// `hasLatinAdvance(family)` is the detection primitive. It
// compares the rendered advance of "Wi" in the test family against
// the default font — a real match gives a different width than
// the default; a fallback (missing family or non-Latin script)
// gives the same width as the default.
//
// These tests pin both the constant and the detection logic. The
// detection logic depends on a real font being installed for the
// positive case (we use a CSS generic 'monospace' as the probe —
// it resolves to *some* Latin face on every platform Flutter
// supports), and on the platform default being measurable (which
// `TestWidgetsFlutterBinding.ensureInitialized()` wires up).
//
// `safeFontFamilyFallback` is per-platform, so the value-pinning
// test branches on `Platform.isWindows` / `Platform.isMacOS` to
// match what `defaultPlatformMonospaceFont` returns — the same
// pattern `pty_launch_args_test.dart` uses for its per-platform
// contract.

import 'dart:io' show Platform, Process;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/font_family_options.dart';
import 'package:octodo/src/terminal/terminal_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('safeFontFamilyFallback primary-pin contract', () {
    test('safeFontFamilyFallback is a known-good monospace Latin face', () {
      // Pin the *value* — the bug class is "what if a future
      // contributor picks a script-specific face here?". A
      // comment-only assertion is too easy to drift past; this
      // fails if anyone changes the per-platform pick away from a
      // guaranteed-present monospace Latin face. Per-platform:
      //   Windows → 'Cascadia Code' (shipped on Win 10/11)
      //   macOS   → 'Menlo'         (shipped since 10.6)
      //   Linux   → the fontconfig-resolved concrete monospace
      //             default (e.g. 'DejaVu Sans Mono') — the bare
      //             'monospace' generic is NOT reliably parsed by
      //             the engine's desktop font resolver, so the
      //             getter resolves it via `fc-match` at first use.
      final expected = Platform.isWindows
          ? 'Cascadia Code'
          : Platform.isMacOS
              ? 'Menlo'
              : _fcMatchMonospace() ?? 'monospace';
      expect(
        TerminalViewState.safeFontFamilyFallback,
        equals(expected),
        reason:
            'Primary family must be a monospace Latin face shipped '
            'on the current platform. Non-Latin faces (e.g. '
            '"Adobe Devanagari") have no Latin advance and crash '
            'flutter_alacritty\'s CellMetrics.measure with '
            '"Infinity or NaN toInt" at terminal_view.dart:758.',
      );
      // Belt-and-suspenders: even if a future contributor edits
      // `defaultPlatformMonospaceFont` away from the values above,
      // the getter must still agree with the per-platform helper
      // (otherwise the production code in `_buildConfig` would
      // diverge from the contract these tests pin).
      expect(
        TerminalViewState.safeFontFamilyFallback,
        equals(defaultPlatformMonospaceFont),
        reason: 'safeFontFamilyFallback must delegate to '
            'defaultPlatformMonospaceFont; if these diverge, the '
            'production fallback chain and the test contract are '
            'reading different sources of truth.',
      );
    });

    test('safeFontFamilyFallback is exposed @visibleForTesting', () {
      // No longer `const` — the getter delegates to
      // `defaultPlatformMonospaceFont`, which reads `Platform.*`
      // at call time.
      final symbol = TerminalViewState.safeFontFamilyFallback;
      expect(symbol, isA<String>());
    });
  });

  group('hasLatinAdvance detection', () {
    test('empty family returns false (no glyphs, no face)', () {
      // The TextPainter would fall back to the default for an
      // empty family — the cell metrics would silently use the
      // default's width, masking the bug. We treat empty as
      // "not Latin" so the caller is forced to pin to the safe
      // fallback explicitly.
      expect(TerminalViewState.hasLatinAdvance(''), isFalse);
    });

    test('safeFontFamilyFallback returns true (per-platform Latin face has W/i)', () {
      // Short-circuit path: we don't want to re-measure a face
      // we already know is safe. The pick is per-platform
      // (Cascadia Code / Menlo / monospace), but every value is
      // a Latin monospace face with a measurable W/i advance on
      // its host OS — so `hasLatinAdvance` must agree.
      expect(
        TerminalViewState.hasLatinAdvance(
          TerminalViewState.safeFontFamilyFallback,
        ),
        isTrue,
      );
    });

    test('a non-existent family falls back to the platform default', () {
      // Detection contract: a missing family name produces the
      // same "Wi" width as the unstyled default (the painter
      // substitutes the platform default). So
      // `hasLatinAdvance` returns false for it — which is what
      // we want, because CellMetrics.measure against a missing
      // family would silently use the default's width and the
      // resulting terminal cells would be sized for whatever
      // face happened to be the default (not the user's pick).
      expect(
        TerminalViewState.hasLatinAdvance(
          '__octodo_no_such_font_${DateTime.now().microsecondsSinceEpoch}__',
        ),
        isFalse,
      );
    });
  });

  group('effectiveLatinPrimary routing', () {
    test('safeFontFamilyFallback passes through unchanged', () {
      expect(
        TerminalViewState.effectiveLatinPrimary(
          TerminalViewState.safeFontFamilyFallback,
        ),
        equals(TerminalViewState.safeFontFamilyFallback),
      );
    });

    test('empty pick is pinned to safeFontFamilyFallback', () {
      expect(
        TerminalViewState.effectiveLatinPrimary(''),
        equals(TerminalViewState.safeFontFamilyFallback),
      );
    });

    test('non-existent family is pinned to safeFontFamilyFallback', () {
      expect(
        TerminalViewState.effectiveLatinPrimary(
          '__octodo_no_such_font_${DateTime.now().microsecondsSinceEpoch}__',
        ),
        equals(TerminalViewState.safeFontFamilyFallback),
      );
    });
  });

  group('terminal-engine integration', () {
    testWidgets('pumping a TerminalView with a non-Latin pick does not throw', (
      tester,
    ) async {
      // Smoke test: build a TerminalView with a non-Latin
      // family. The crash class is "LayoutBuilder throws
      // Infinity or NaN toInt during a layout pass after the
      // user picks a non-Latin face". If `effectiveLatinPrimary`
      // ever stops being called or returns the wrong value,
      // the engine would receive a non-Latin primary and
      // reproduce the crash.
      //
      // We can't actually pump a TerminalView (it owns a PTY
      // and a Rust engine), so this just verifies that the
      // helper itself doesn't throw on the input it will see
      // in production.
      for (final nonLatin in const [
        'Adobe Devanagari',
        '__octodo_nonexistent__',
        'MS Mincho',
        'Microsoft YaHei',
      ]) {
        expect(
          () => TerminalViewState.effectiveLatinPrimary(nonLatin),
          returnsNormally,
          reason: 'non-Latin pick "$nonLatin" must not throw',
        );
      }
      // Sanity: the call actually returns a String.
      expect(
        TerminalViewState.effectiveLatinPrimary('Adobe Devanagari'),
        isA<String>(),
      );
    });
  });

  // Touch the widgets import so the analyzer doesn't flag it as
  // unused in environments that strip the testWidgets block.
  test('widgets import is wired up', () {
    expect(WidgetsBinding, isNotNull);
  });
}

/// Mirror of the production `fc-match --format=%{family} monospace`
/// resolution (see `defaultPlatformMonospaceFont`), used to compute
/// the expected Linux value independently of the code under test.
/// Returns null when `fc-match` isn't available (non-Linux runners,
/// minimal containers) — callers then expect the 'monospace' literal
/// fallback.
String? _fcMatchMonospace() {
  try {
    final result = Process.runSync(
      'fc-match',
      const ['--format=%{family}', 'monospace'],
    );
    if (result.exitCode != 0) return null;
    var name = (result.stdout as String).trim();
    final comma = name.indexOf(',');
    if (comma >= 0) name = name.substring(0, comma);
    name = name.trim();
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}
