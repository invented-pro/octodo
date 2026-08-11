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

import 'dart:convert';

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

  group('pasteBytesForTest (non-bracketed)', () {
    // Non-bracketed paste sends bytes RAW — no newline normalization. ConPTY
    // (flutter_pty's backend) already handles \r\n / \n; collapsing to a bare
    // \r double-processes through ConPTY + the WSL PTY's ICRNL and inserts an
    // extra blank line per command (empirically verified). These tests pin
    // the "do NOT normalize" decision so nobody re-introduces that regression.
    const off = 0;

    test('CRLF passes through unchanged (Windows clipboard)', () {
      expect(
        TerminalViewState.pasteBytesForTest('a\r\nb\r\nc', modeFlags: off),
        utf8.encode('a\r\nb\r\nc'),
      );
    });

    test('bare LF passes through unchanged (Linux/macOS clipboard)', () {
      expect(
        TerminalViewState.pasteBytesForTest('a\nb\nc', modeFlags: off),
        utf8.encode('a\nb\nc'),
      );
    });

    test('lone CR passes through unchanged', () {
      expect(
        TerminalViewState.pasteBytesForTest('a\rb', modeFlags: off),
        utf8.encode('a\rb'),
      );
    });

    test('preserves non-newline bytes (unicode + control)', () {
      expect(
        TerminalViewState.pasteBytesForTest('echo héllo\x7f', modeFlags: off),
        utf8.encode('echo héllo\x7f'),
      );
    });

    test('regression: NEVER collapses CRLF to CR (would add blank lines)', () {
      // Sending bare '\r' per line is the classic Unix-PTY rule but is WRONG
      // on ConPTY — it inserts an extra blank line between pasted commands.
      final out = TerminalViewState.pasteBytesForTest('x\r\ny', modeFlags: off);
      expect(out, utf8.encode('x\r\ny'));
      expect(out, isNot(utf8.encode('x\ry')));
    });
  });

  group('pasteBytesForTest (bracketed)', () {
    const on = TerminalViewState.bracketedPasteModeFlag;

    test('wraps payload with CRLF collapsed to LF (Windows clipboard)', () {
      // bash/readline insert one line break per LF; a raw CRLF would insert
      // two (CR + LF) and leave a blank line between pasted commands.
      final out = TerminalViewState.pasteBytesForTest(
        'a\r\nb',
        modeFlags: on,
      );
      expect(out, [
        ...'\x1b[200~'.codeUnits,
        ...utf8.encode('a\nb'),
        ...'\x1b[201~'.codeUnits,
      ]);
    });

    test('collapses a lone CR to LF inside the bracket', () {
      expect(
        TerminalViewState.pasteBytesForTest('a\rb', modeFlags: on),
        [
          ...'\x1b[200~'.codeUnits,
          ...utf8.encode('a\nb'),
          ...'\x1b[201~'.codeUnits,
        ],
      );
    });

    test('leaves an existing LF as LF', () {
      expect(
        TerminalViewState.pasteBytesForTest('a\nb', modeFlags: on),
        [
          ...'\x1b[200~'.codeUnits,
          ...utf8.encode('a\nb'),
          ...'\x1b[201~'.codeUnits,
        ],
      );
    });

    test('strips ESC and Ctrl+C inside the bracket', () {
      final out = TerminalViewState.pasteBytesForTest(
        'a\x1b[201~b\x03c',
        modeFlags: on,
      );
      expect(out, [
        ...'\x1b[200~'.codeUnits,
        ...utf8.encode('a[201~bc'),
        ...'\x1b[201~'.codeUnits,
      ]);
    });

    test('regression: multi-line CRLF payload has no CR (no blank lines)', () {
      final out = TerminalViewState.pasteBytesForTest(
        'cmd1\r\ncmd2\r\ncmd3',
        modeFlags: on,
      );
      // Payload between the markers must contain only LF, never CR — a CR
      // renders as an extra blank line per command in bash/readline.
      final body = out.sublist(6, out.length - 6);
      expect(body.contains(0x0d), isFalse);
      expect(body, utf8.encode('cmd1\ncmd2\ncmd3'));
    });
  });

  group('imagePasteTriggerBytesForTest', () {
    // When a paste (Ctrl+V / Shift+Insert / right-click) finds no text in the
    // clipboard because it holds an image, Octodo forwards a Ctrl+V keystroke
    // (0x16) to the PTY so TUI apps that read the OS clipboard themselves
    // (opencode, MimoCode, ...) can react. opencode binds `ctrl+v` →
    // `prompt.paste` (described "Paste from clipboard"); opentui's
    // parseKeypress decodes 0x16 as {name:"v", ctrl:true}. See
    // _imagePasteTriggerBytes and GitHub issue #2.

    test('emits the raw Ctrl+V byte (0x16)', () {
      expect(
        TerminalViewState.imagePasteTriggerBytesForTest(),
        [0x16],
      );
    });
  });
}
