// Unit tests for the theme palette system and the
// [PaletteIdCodec] used by the `appearance.themeName` setting.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/settings/setting_codec.dart';
import 'package:octodo/src/theme/palettes.dart';

void main() {
  group('AppPalettes', () {
    test('registry is non-empty and starts with the default', () {
      expect(AppPalettes.all, isNotEmpty);
      expect(AppPalettes.all.first.id, AppPalettes.defaultId);
    });

    test('every palette has a unique id', () {
      final ids = AppPalettes.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length,
          reason: 'duplicate palette id in registry');
    });

    test('every palette has a non-empty display name', () {
      for (final p in AppPalettes.all) {
        expect(p.displayName, isNotEmpty, reason: '${p.id} has no name');
      }
    });

    test('every palette has a brightness', () {
      // Sanity: brightness isn't `null` (Flutter's Brightness has no
      // null state but the test guards against accidental removal of
      // the getter on a future refactor).
      for (final p in AppPalettes.all) {
        expect(p.brightness, isIn([Brightness.light, Brightness.dark]));
      }
    });

    test('byId returns the matching palette', () {
      for (final p in AppPalettes.all) {
        expect(AppPalettes.byId(p.id).id, p.id);
      }
    });

    test('byId falls back to the default for unknown ids', () {
      final fallback = AppPalettes.byId('not-a-real-palette');
      expect(fallback.id, AppPalettes.defaultId);
    });

    test('byId falls back to the default for empty input', () {
      final fallback = AppPalettes.byId('');
      expect(fallback.id, AppPalettes.defaultId);
    });

    test('Catppuccin Mocha is dark and Latte is light', () {
      final mocha = AppPalettes.byId('catppuccin-mocha');
      final latte = AppPalettes.byId('catppuccin-latte');
      expect(mocha.brightness, Brightness.dark);
      expect(latte.brightness, Brightness.light);
    });
  });

  group('Palette terminal colors', () {
    // flutter_alacritty's fa.TerminalColors.ansi asserts the list
    // is exactly length 16 — every palette must comply or the
    // TerminalView throws on construction. Guard against future
    // palette additions forgetting this contract.
    test('every palette declares exactly 16 ANSI colors', () {
      for (final p in AppPalettes.all) {
        expect(p.terminalAnsiColors, hasLength(16),
            reason: '${p.id} terminalAnsiColors length != 16');
      }
    });

    test('terminal foreground contrasts with the palette surface0', () {
      // The terminal grid is unreadable when foreground ≈ background
      // brightness. Light themes must use a dark foreground, dark
      // themes a light one. Compare per-channel sums as a cheap
      // proxy for perceived luminance — picks up the Latte/Mocha
      // inversion and any near-zero-contrast regression.
      int lum(Color c) =>
          ((c.r * 255).round() * 299 +
                  (c.g * 255).round() * 587 +
                  (c.b * 255).round() * 114) ~/
              1000;
      for (final p in AppPalettes.all) {
        final fg = lum(p.terminalForeground);
        final bg = lum(p.surface0);
        final delta = (fg - bg).abs();
        expect(delta, greaterThan(80),
            reason:
                '${p.id}: terminal foreground and surface0 are too close '
                '(fg=$fg bg=$bg, delta=$delta) — text would be unreadable');
      }
    });

    test('light palettes invert foreground brightness vs dark ones', () {
      // Sanity-check the Latte/Mocha split: a light palette should
      // have a darker fg than a dark palette (low luminance fg on
      // light bg), and vice versa. Keeps us honest about future
      // light-mode palette additions.
      int lum(Color c) =>
          ((c.r * 255).round() * 299 +
                  (c.g * 255).round() * 587 +
                  (c.b * 255).round() * 114) ~/
              1000;
      final mocha = AppPalettes.byId('catppuccin-mocha');
      final latte = AppPalettes.byId('catppuccin-latte');
      expect(lum(mocha.terminalForeground),
          greaterThan(lum(latte.terminalForeground)),
          reason:
              'dark Mocha should have brighter fg than light Latte');
    });
  });

  group('PaletteIdCodec', () {
    const codec = PaletteIdCodec();

    test('roundtrips known palette ids', () {
      for (final p in AppPalettes.all) {
        expect(codec.fromJson(codec.toJson(p.id)), p.id);
      }
    });

    test('returns the default for unknown ids (no throw)', () {
      expect(codec.fromJson('not-a-real-palette'), AppPalettes.defaultId);
    });

    test('returns the default for null', () {
      expect(codec.fromJson(null), AppPalettes.defaultId);
    });

    test('returns the default for non-string values', () {
      expect(codec.fromJson(42), AppPalettes.defaultId);
      expect(codec.fromJson(true), AppPalettes.defaultId);
      expect(codec.fromJson(['catppuccin-mocha']), AppPalettes.defaultId);
    });

    test('toJson is a passthrough of the input id', () {
      expect(codec.toJson('dracula'), 'dracula');
    });
  });
}