// Font-availability plumbing for GH #11 ("linux版字体渲染有问题").
//
// Root cause being guarded: a configured family that is not
// installed never fails to resolve on Linux — fontconfig silently
// substitutes a *proportional* face. The terminal then measures its
// cell width from that substituted font's wide 'W' advance while
// every other glyph advances proportionally less, producing a
// uniform wide-spacing corruption of the grid.
//
// The fix has three layers, each pinned here:
//   1. `InstalledFontRegistry` — process-wide knowledge of what is
//      actually installed; optimistic until the first scan lands so
//      startup never blocks on enumeration.
//   2. `resolveTerminalFonts` — the single (primary, fallback)
//      resolution used by BOTH the engine config and the paint-side
//      TerminalStyle; an unavailable pick is pinned to the bundled
//      font and never reaches the renderer.
//   3. The bundled JetBrainsMono NFM subset — the default font on
//      every platform; it resolves in-engine and can never be
//      substituted, so dead/empty picks always land somewhere safe.

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/settings/settings_catalog.dart';
import 'package:octodo/src/terminal/font_family_options.dart';
import 'package:octodo/src/terminal/terminal_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Fresh, optimistic registry for every test; tests that need
    // authoritative mode call `apply` explicitly.
    InstalledFontRegistry.instance.resetForTest();
  });

  group('InstalledFontRegistry', () {
    test('optimistic before the first scan: unknown families allowed', () {
      // Startup must not stall on a font scan; defaults and stored
      // picks render immediately and are re-validated when the scan
      // lands.
      expect(InstalledFontRegistry.instance.loaded, isFalse);
      expect(
        InstalledFontRegistry.instance.isAvailable('Maple Mono NF CN'),
        isTrue,
      );
    });

    test('authoritative after apply: case-insensitive membership', () {
      InstalledFontRegistry.instance.apply(const ['Menlo', 'firA cOde']);
      expect(InstalledFontRegistry.instance.loaded, isTrue);
      expect(InstalledFontRegistry.instance.isAvailable('Menlo'), isTrue);
      expect(InstalledFontRegistry.instance.isAvailable('menlo'), isTrue);
      expect(InstalledFontRegistry.instance.isAvailable('Fira Code'), isTrue);
      expect(
        InstalledFontRegistry.instance.isAvailable('Maple Mono NF CN'),
        isFalse,
        reason:
            'After a scan that does not list the pick, the pick must be '
            'reported unavailable — this is the exact GH #11 case where a '
            'dead family reached the renderer and fontconfig substituted '
            'a proportional face.',
      );
    });

    test('bundled font is always available; empty never is', () {
      InstalledFontRegistry.instance.apply(const []);
      expect(InstalledFontRegistry.instance.isAvailable(kBundledMonoFamily), isTrue);
      expect(InstalledFontRegistry.instance.isAvailable(''), isFalse);
      expect(InstalledFontRegistry.instance.isAvailable('  '), isFalse);
    });

    test('apply notifies listeners (drives re-resolution + cache drop)', () {
      // Live terminal views listen for this pulse to re-resolve a
      // pick that only passed the optimistic gate (GH #11), and the
      // Latin-advance memo is dropped so a family installed after a
      // failed probe does not stay dead for the session.
      var fired = 0;
      InstalledFontRegistry.instance.addListener(() => fired++);
      InstalledFontRegistry.instance.apply(const ['Menlo']);
      expect(fired, 1);
    });
  });

  group('bundled default', () {
    test('safeFontFamilyFallback is the bundled font', () {
      // The safe Latin baseline and the universal default are the
      // same in-engine-resolvable face; anything else reintroduces a
      // host-dependent (substitutable) default.
      expect(
        TerminalViewState.safeFontFamilyFallback,
        equals(kBundledMonoFamily),
      );
    });

    test('terminal.fontFamily defaults to the bundled font', () {
      // If the catalog default ever drifts away from the bundled
      // font, a fresh install would hand a possibly-unresolvable
      // family to the renderer again (GH #11).
      expect(
        TerminalSettingsSection().fontFamily.defaultValue,
        equals(kBundledMonoFamily),
      );
    });
  });

  group('resolveTerminalFonts (renderer-handoff contract)', () {
    test('installed Latin pick is the primary and leads its own chain', () {
      // Optimistic registry → any pick passes the availability gate.
      // Use the safe fallback itself (the bundled font) for a
      // host-independent positive case.
      final pick = TerminalViewState.safeFontFamilyFallback;
      final r = TerminalViewState.resolveTerminalFonts(pick);
      expect(r.primary, equals(pick));
      // The pick already being primary must not duplicate itself in
      // the fallback chain.
      expect(r.fallback, isNot(contains(pick)));
    });

    test('unavailable pick is pinned to the bundled font', () {
      InstalledFontRegistry.instance.apply(const []);
      final r = TerminalViewState.resolveTerminalFonts('Maple Mono NF CN');
      expect(
        r.primary,
        equals(kBundledMonoFamily),
        reason:
            'A dead pick must never become the primary — fontconfig '
            'substitution of a missing family is the GH #11 corruption.',
      );
      expect(r.primary, isNot(equals('Maple Mono NF CN')));
      // The dead pick must not leak into the fallback chain either:
      // it resolves to the substituted proportional face there too.
      expect(r.fallback, isNot(contains('Maple Mono NF CN')));
    });

    test('empty pick resolves to the bundled default', () {
      InstalledFontRegistry.instance.apply(const []);
      final r = TerminalViewState.resolveTerminalFonts('');
      expect(r.primary, equals(kBundledMonoFamily));
    });

    test('fallback chain terminates in the bundled font', () {
      // The chain's last entry must be the in-engine bundled font:
      // it can never be substituted, is genuinely monospace, and
      // carries the Nerd Font icon codepoints — UNLESS the primary
      // already is the bundled font, in which case it is deduped
      // out of the chain entirely (the renderer tries the primary
      // before walking the chain).
      final r = TerminalViewState.resolveTerminalFonts(
        TerminalViewState.safeFontFamilyFallback,
      );
      if (r.primary == kBundledMonoFamily) {
        expect(r.fallback, isNot(contains(kBundledMonoFamily)));
      } else {
        expect(r.fallback.last, equals(kBundledMonoFamily));
      }
    });

    test('chain includes the CJK fallback face', () {
      final r = TerminalViewState.resolveTerminalFonts(
        TerminalViewState.safeFontFamilyFallback,
      );
      expect(r.fallback, contains(defaultPlatformCjkFont));
    });

    test('the bundled default survives an empty-install scan', () {
      // The settings default is the bundled font; with an empty
      // (container-style) install it is still the primary — it
      // resolves in-engine, so no scan outcome can invalidate it.
      InstalledFontRegistry.instance.apply(const []);
      final r = TerminalViewState.resolveTerminalFonts(kBundledMonoFamily);
      expect(r.primary, equals(kBundledMonoFamily));
    });
  });

  group('mergeFontFamilies installed-only gating', () {
    test('curated tier is filtered to the installed set', () {
      final merged = mergeFontFamilies(
        installed: const ['Menlo'],
        pinCurrent: null,
        installedOnly: true,
      );
      // 'Menlo' is curated on macOS only; on other hosts nothing
      // curated survives an empty scan except the bundled font.
      if (Platform.isMacOS) {
        expect(merged, contains('Menlo'));
      }
      expect(merged, contains(kBundledMonoFamily));
      expect(
        merged,
        isNot(contains('Fira Code')),
        reason:
            '"Fira Code" was never installed on this machine — offering '
            'it in the dropdown is how dead families end up in '
            'settings.json (GH #11).',
      );
    });

    test('pinned current value survives even when not installed', () {
      final merged = mergeFontFamilies(
        installed: const [],
        pinCurrent: 'Maple Mono NF CN',
        installedOnly: true,
      );
      expect(merged.first, equals('Maple Mono NF CN'));
    });

    test('installedOnly=false keeps the historical pre-scan behaviour', () {
      final merged = mergeFontFamilies(
        installed: const [],
        pinCurrent: null,
        installedOnly: false,
      );
      // The pre-scan placeholder tier still shows curated faces.
      expect(merged, contains('JetBrains Mono'));
      expect(merged, contains(kBundledMonoFamily));
    });
  });
}
