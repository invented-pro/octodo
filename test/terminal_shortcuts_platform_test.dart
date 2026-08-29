// Regression guard for the macOS ⌘V paste bug (and the sibling ⌘-chords
// that shared the same root cause).
//
// Root cause: `_alacrittyShortcutsWithShiftVariants` — the shortcuts map
// `TerminalView` hands to `fa.TerminalView` — hardcoded `control: true`
// on every clipboard / zoom entry, and the stock
// `defaultTerminalShortcuts` spread in before them does the same. On
// macOS the primary modifier is Cmd, and `SingleActivator.accepts`
// requires an exact modifier match, so ⌘V missed the map, fell through
// `_onKeyFallback` into `encodeKeyWithKitty`, and wrote kitty `super+v`
// bytes into the PTY instead of pasting (Ctrl+V kept working because it
// literally matched the hardcoded form). The fix re-binds those entries
// through `primary(...)` (Cmd+… on macOS, Ctrl+… elsewhere). These tests
// pin the platform-correct activators so the hardcoded-Ctrl regression
// can't silently return.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Intent, SingleActivator;
import 'package:flutter_alacritty/flutter_alacritty.dart' as fa;
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/terminal_view.dart';

void main() {
  final map = TerminalViewState.alacrittyShortcutsForTest;

  /// True when the host platform's primary modifier is Cmd (meta).
  final bool mac = Platform.isMacOS;

  Intent? intentFor(bool Function(SingleActivator) match) {
    for (final entry in map.entries) {
      final activator = entry.key;
      if (activator is SingleActivator && match(activator)) {
        return entry.value;
      }
    }
    return null;
  }

  group('alacrittyShortcutsForTest — paste activators', () {
    test(
      'platform-primary paste binding exists (⌘V on macOS, Ctrl+V elsewhere)',
      () {
        final intent = intentFor(
          (a) =>
              a.trigger == LogicalKeyboardKey.keyV &&
              (mac ? a.meta && !a.control : a.control && !a.meta) &&
              !a.shift &&
              !a.alt,
        );
        expect(intent, isA<fa.PasteIntent>(), reason: 'the ⌘V bug fix');
      },
    );

    test(
      'shifted platform-primary paste binding exists (⌘⇧V / Ctrl+Shift+V)',
      () {
        final intent = intentFor(
          (a) =>
              a.trigger == LogicalKeyboardKey.keyV &&
              (mac ? a.meta && !a.control : a.control && !a.meta) &&
              a.shift &&
              !a.alt,
        );
        expect(intent, isA<fa.PasteIntent>());
      },
    );

    test('bare Ctrl+V still pastes on every platform (documented exception)', () {
      // The deliberate Ctrl+V alias from the pre-fix map — see the
      // readline-exception note in test/app_shortcuts_test.dart and
      // GitHub issue #2. Must survive alongside the ⌘V re-bind.
      final intent = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.keyV &&
            a.control &&
            !a.meta &&
            !a.shift &&
            !a.alt,
      );
      expect(intent, isA<fa.PasteIntent>());
    });
  });

  group('alacrittyShortcutsForTest — zoom activators', () {
    test(
      'unshifted zoom uses the platform primary (⌘= / ⌘- / ⌘0 on macOS)',
      () {
        final increase = intentFor(
          (a) =>
              a.trigger == LogicalKeyboardKey.equal &&
              (mac ? a.meta && !a.control : a.control && !a.meta) &&
              !a.shift &&
              !a.alt,
        );
        final decrease = intentFor(
          (a) =>
              a.trigger == LogicalKeyboardKey.minus &&
              (mac ? a.meta && !a.control : a.control && !a.meta) &&
              !a.shift &&
              !a.alt,
        );
        final reset = intentFor(
          (a) =>
              a.trigger == LogicalKeyboardKey.digit0 &&
              (mac ? a.meta && !a.control : a.control && !a.meta) &&
              !a.shift &&
              !a.alt,
        );
        expect(increase, isA<fa.IncreaseFontSizeIntent>());
        expect(decrease, isA<fa.DecreaseFontSizeIntent>());
        expect(reset, isA<fa.ResetFontSizeIntent>());
      },
    );

    test('shifted zoom variants use the platform primary', () {
      final increase = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.add &&
            (mac ? a.meta && !a.control : a.control && !a.meta) &&
            a.shift &&
            !a.alt,
      );
      final decrease = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.minus &&
            (mac ? a.meta && !a.control : a.control && !a.meta) &&
            a.shift &&
            !a.alt,
      );
      final reset = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.digit0 &&
            (mac ? a.meta && !a.control : a.control && !a.meta) &&
            a.shift &&
            !a.alt,
      );
      expect(increase, isA<fa.IncreaseFontSizeIntent>());
      expect(decrease, isA<fa.DecreaseFontSizeIntent>());
      expect(reset, isA<fa.ResetFontSizeIntent>());
    });
  });

  group('alacrittyShortcutsForTest — map shape', () {
    test('stock PageUp/PageDown scroll bindings survive the re-bind', () {
      final pageUp = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.pageUp &&
            !a.control &&
            !a.meta &&
            !a.alt &&
            !a.shift,
      );
      final pageDown = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.pageDown &&
            !a.control &&
            !a.meta &&
            !a.alt &&
            !a.shift,
      );
      expect(pageUp, isA<fa.ScrollPageIntent>());
      expect(pageDown, isA<fa.ScrollPageIntent>());
    });
  });
}
