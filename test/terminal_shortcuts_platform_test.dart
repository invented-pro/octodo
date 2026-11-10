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
//
// The map shipped to `fa.TerminalView` is also where the PageUp/PageDown
// policy lives (GitHub issue #14): bare page keys must NOT appear here, so
// the encoder can turn them into `ESC [ 5 ~` / `ESC [ 6 ~` for the running
// program, while the Shift forms stay bound to the local scrollback. See
// `page_key_encoding_test.dart` for the payload side of that contract.

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

  group('alacrittyShortcutsForTest — page keys', () {
    // GitHub issue #14: bare PageUp/PageDown must reach the PTY as
    // `ESC [ 5 ~` / `ESC [ 6 ~`, so nothing in the map may claim them.
    // Shift+PageUp/Down stays local (scrollback, 5 pages per press).
    test('bare PageUp/PageDown are NOT bound (they are PTY input)', () {
      final barePageActivators = map.keys
          .whereType<SingleActivator>()
          .where(
            (a) =>
                (a.trigger == LogicalKeyboardKey.pageUp ||
                    a.trigger == LogicalKeyboardKey.pageDown) &&
                !a.control &&
                !a.meta &&
                !a.alt &&
                !a.shift,
          )
          .toList();
      expect(
        barePageActivators,
        isEmpty,
        reason:
            'A bare page-key binding here short-circuits '
            "fa.TerminalView's encodeKey path and the running app never "
            'sees the key — the exact bug in issue #14.',
      );
    });

    test('Shift+PageUp/PageDown stay bound to the fast local scroll', () {
      final pageUp = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.pageUp &&
            a.shift &&
            !a.control &&
            !a.meta &&
            !a.alt,
      );
      final pageDown = intentFor(
        (a) =>
            a.trigger == LogicalKeyboardKey.pageDown &&
            a.shift &&
            !a.control &&
            !a.meta &&
            !a.alt,
      );
      expect(pageUp, isNotNull);
      expect(pageDown, isNotNull);
      // Not the stock 1-page intent: the Shift forms are 5 pages, carried
      // by octodo's private `_ScrollFastIntent` (hence no `isA<...>` here).
      expect(pageUp, isNot(isA<fa.ScrollPageIntent>()));
      expect(pageDown, isNot(isA<fa.ScrollPageIntent>()));
    });
  });

  group('shiftPageScrollPages — fallback policy', () {
    // Mirrors the shortcut map for the `_handleKeyFallback` safety net, so
    // the two layers can't drift apart.
    test('bare PageUp/PageDown are never consumed', () {
      expect(
        TerminalViewState.shiftPageScrollPages(
          LogicalKeyboardKey.pageUp,
          shiftPressed: false,
        ),
        isNull,
      );
      expect(
        TerminalViewState.shiftPageScrollPages(
          LogicalKeyboardKey.pageDown,
          shiftPressed: false,
        ),
        isNull,
      );
    });

    test('Shift+PageUp scrolls +5 pages, Shift+PageDown -5', () {
      expect(
        TerminalViewState.shiftPageScrollPages(
          LogicalKeyboardKey.pageUp,
          shiftPressed: true,
        ),
        equals(5),
      );
      expect(
        TerminalViewState.shiftPageScrollPages(
          LogicalKeyboardKey.pageDown,
          shiftPressed: true,
        ),
        equals(-5),
      );
    });

    test('other keys are unaffected by Shift', () {
      expect(
        TerminalViewState.shiftPageScrollPages(
          LogicalKeyboardKey.arrowUp,
          shiftPressed: true,
        ),
        isNull,
      );
    });
  });
}
