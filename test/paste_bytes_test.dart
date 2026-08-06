// Regression guard for the bracketed-paste bit read from
// flutter_alacritty's `grid.modeFlags`. `_pasteBytes` wraps pasted text in
// ESC[200~ … ESC[201~ ONLY when this bit is set; a wrong bit value silently
// disables bracketed paste and every multi-line paste races the shell
// (commands echo back with extra newlines instead of running). This is
// exactly the bug this test exists for: the literal was 0x20000000 = bit 29,
// which is never set in TermMode, so wrapping never fired even though
// `bind -v | grep bracketed` showed the mode ON inside the pane.
//
// Bit assignment reference (kept in sync with flutter_alacritty's
// package-internal input/term_mode.dart, itself a mirror of the Rust
// TermMode):
//   kModeBracketedPaste = 1 << 4 = 0x10   (DECSET 2004)
//
// We pin the *literal value* rather than re-deriving it for the same reason
// terminal_drag_select_test.dart does: the bug class is "what if a future
// contributor renumbers the bit?" and a comment-only assertion would let a
// silent drift pass.

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/terminal_view.dart';

void main() {
  group('bracketedPasteModeFlag', () {
    test('is 1 << 4 (DECSET 2004, mirrors flutter_alacritty)', () {
      expect(
        TerminalViewState.bracketedPasteModeFlag,
        equals(1 << 4),
        reason:
            'Bitmask must mirror flutter_alacritty\'s '
            'input/term_mode.dart::kModeBracketedPaste (= 1 << 4 = 0x10). '
            'If this fails, multi-line paste silently sends raw bytes and '
            'races the shell. If alacritty\'s TermMode bits shift, update '
            'both sides together (also re-check terminalAnyMouseModeFlag).',
      );
    });

    test('does not collide with the mouse-mode bits', () {
      const flag = TerminalViewState.bracketedPasteModeFlag;
      // kModeMouseClick 1<<3, kModeMouseMotion 1<<6, kModeMouseDrag 1<<13.
      expect(flag & TerminalViewState.terminalAnyMouseModeFlag, equals(0));
      expect(flag, equals(0x10));
    });
  });
}
