// Regression guard for GitHub issue #14: bare PageUp/PageDown must reach the
// PTY as `ESC [ 5 ~` / `ESC [ 6 ~` so full-screen programs (less, vim,
// opencode, …) can page themselves.
//
// The fix removes every bare page-key binding from octodo's shortcut maps,
// which lets `fa.TerminalView._onKeyFallback` fall through to its
// `encodeKeyWithKitty` / `encodeKey` chain. This test pins the *payload* of
// that fall-through — the seam that actually has to be right for a user in
// `less`. `input/key_input.dart` isn't re-exported from the package barrel,
// so it's imported by path; it only depends on `flutter/services` and
// `input/term_mode.dart`, which keeps this test pure Dart (no Rust/FFI).
//
// What is NOT covered here: the key-event plumbing between the Flutter
// embedder and `fa.TerminalView` (needs a real app + desktop).

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:flutter_alacritty/flutter_alacritty.dart' as fa;
import 'package:flutter_alacritty/input/key_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // xterm modifier parameter 1 == no modifiers.
  const pageUpBytes = <int>[0x1b, 0x5b, 0x35, 0x7e]; // ESC [ 5 ~
  const pageDownBytes = <int>[0x1b, 0x5b, 0x36, 0x7e]; // ESC [ 6 ~
  // Shift+PageUp/Down — the encoder form of the chord, kept only as a
  // sanity check: octodo claims the Shift forms for local scrollback, so
  // this path is not expected to run in the app.
  const shiftPageUpBytes = <int>[0x1b, 0x5b, 0x35, 0x3b, 0x32, 0x7e];
  const shiftPageDownBytes = <int>[0x1b, 0x5b, 0x36, 0x3b, 0x32, 0x7e];

  // TermMode bit set while a full-screen program owns the screen (mirrors
  // flutter_alacritty's `input/term_mode.dart::kModeAltScreen`).
  const altScreenFlag = 1 << 12;

  group('encodeKey — bare page keys are PTY input', () {
    test('PageUp encodes to ESC [ 5 ~', () {
      expect(
        encodeKey(LogicalKeyboardKey.pageUp, null, modeFlags: 0),
        equals(pageUpBytes),
      );
    });

    test('PageDown encodes to ESC [ 6 ~', () {
      expect(
        encodeKey(LogicalKeyboardKey.pageDown, null, modeFlags: 0),
        equals(pageDownBytes),
      );
    });

    test('encoding is screen-mode independent (works in the alt screen)', () {
      // The reported symptom: inside `less` nothing happened. The bytes
      // don't depend on TermMode, so once nothing consumes the event the
      // alt-screen app receives them exactly like a plain shell would.
      expect(
        encodeKey(
          LogicalKeyboardKey.pageUp,
          null,
          modeFlags: altScreenFlag,
        ),
        equals(pageUpBytes),
      );
      expect(
        encodeKey(
          LogicalKeyboardKey.pageDown,
          null,
          modeFlags: altScreenFlag,
        ),
        equals(pageDownBytes),
      );
    });

    test('Shift forms keep their xterm modifier parameter', () {
      expect(
        encodeKey(
          LogicalKeyboardKey.pageUp,
          null,
          shift: true,
          modeFlags: 0,
        ),
        equals(shiftPageUpBytes),
      );
      expect(
        encodeKey(
          LogicalKeyboardKey.pageDown,
          null,
          shift: true,
          modeFlags: 0,
        ),
        equals(shiftPageDownBytes),
      );
    });
  });

  group("upstream defaultTerminalShortcuts doesn't claim page keys", () {
    // If alacritty ever adds a bare page-key binding to its stock map,
    // octodo's explicit map replaces it anyway — but a Shift-only change
    // upstream could still silently re-route the chord, so fail loudly.
    test('no PageUp/PageDown activator in the stock map', () {
      final pageActivators = fa.defaultTerminalShortcuts.keys
          .whereType<SingleActivator>()
          .where(
            (a) =>
                a.trigger == LogicalKeyboardKey.pageUp ||
                a.trigger == LogicalKeyboardKey.pageDown,
          )
          .toList();
      expect(pageActivators, isEmpty);
    });
  });
}
