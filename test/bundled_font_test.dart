// Guards the bundled fallback font artifact itself
// (assets/fonts/JetBrainsMono-NFM-subset.ttf).
//
// This file is the last line of defence for the whole font-resolution
// contract: when the configured family is not installed, the terminal
// pins to this font (see font_availability_test.dart). If the artifact
// were regenerated wrongly — non-monospace advance, missing icons, a
// renamed family — the "safe" path would itself corrupt the grid.
//
// The test loads the real bytes from disk (rootBundle in `flutter
// test` has no asset tree), registers them through the same
// `ui.FontLoader` production uses, and measures with the same
// TextPainter probe `CellMetrics.measure` uses.

import 'dart:io' show File;

import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/font_family_options.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final bytes = await File(kBundledMonoAsset).readAsBytes();
    final loader = FontLoader(kBundledMonoFamily);
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  double widthOf(String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontFamily: kBundledMonoFamily, fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  test('artifact exists and is a plausible TTF', () {
    final f = File(kBundledMonoAsset);
    expect(f.existsSync(), isTrue, reason: '$kBundledMonoAsset is missing');
    final magic = f.readAsBytesSync().sublist(0, 4);
    // TrueType: 00 01 00 00 (or 'true'/OTTO 'OTTO' — all sfnt).
    expect(magic[0], anyOf(0x00, 0x74, 0x4F), reason: 'not an sfnt font');
  });

  test('resolves under the bundled family name with a positive advance', () {
    // If the internal family name ever changes (bad subset, renamed
    // upstream), the request falls back to the default face and the
    // whole availability contract silently degrades.
    final w = widthOf('W' * 20) / 20;
    expect(w, greaterThan(0));
    expect(w, lessThan(14 * 0.8), reason: 'cell wider than 0.8em looks broken');
  });

  test('ASCII advances are uniform (truly monospace)', () {
    // The GH #11 corruption is exactly a non-uniform advance grid:
    // every glyph must share one advance for cell math to hold.
    final widths = <double>{
      for (final ch in r'Wa.@i-1m|#[]~$'.split('')) widthOf(ch * 10) / 10,
    };
    final spread =
        widths.reduce((a, b) => a > b ? a : b) -
        widths.reduce((a, b) => a < b ? a : b);
    expect(spread, lessThan(0.1), reason: 'advances drifted: $widths');
  });

  test('Nerd Font icon codepoints render with a positive advance', () {
    // Powerline separators (E0B0/E0B1) are the highest-traffic
    // prompt icons; if a regeneration drops the icon blocks, users
    // with non-Nerd-Font picks see tofu in their prompts again.
    for (final cp in [0xE0B0, 0xE0B1, 0xE0A0]) {
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(cp),
          style: const TextStyle(fontFamily: kBundledMonoFamily, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(
        tp.width,
        greaterThan(0),
        reason: 'U+${cp.toRadixString(16).toUpperCase()} lost from subset',
      );
    }
  });

  test('default-primary text coverage: box drawing, Latin-1, Greek, currency', () {
    // The bundled font is the default on every platform, so TUI
    // borders (htop/tmux) and non-ASCII text must not depend on the
    // OS fallback chain — a regeneration that drops the text ranges
    // would push those glyphs onto substituted faces (wrong style,
    // possibly wrong advance → cell misalignment).
    for (final cp in [0x2500, 0x2551, 0x2588, 0x00E9, 0x03B1, 0x20AC]) {
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(cp),
          style: const TextStyle(fontFamily: kBundledMonoFamily, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(
        tp.width,
        greaterThan(0),
        reason: 'U+${cp.toRadixString(16).toUpperCase()} lost from subset',
      );
    }
  });
}
