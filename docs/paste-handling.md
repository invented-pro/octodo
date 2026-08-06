# Clipboard paste — bracketed mode, newlines, and the ConPTY boundary

## Goal

Document how clipboard paste travels from a right-click / `Ctrl+V` in
Octodo to the child shell, the two bugs that broke multi-line paste in
WSL bash, and the newline-handling rules that differ between bracketed
and non-bracketed mode. This exists so the next contributor does not
re-derive (and re-break) the same rules — both bugs below survived for
a release precisely because the encoding was untested and the inline
constants were wrong.

## The pipeline

```
right-click / Ctrl+V
  └─ TerminalViewState._onSecondaryTapUp / _pasteFromClipboard
       └─ _engine.write(_pasteBytes(text, modeFlags: grid.modeFlags))
            └─ flutter_alacritty engine.output  (bytes forwarded as-is)
                 └─ flutter_pty Pty.write  → native pty_write
                      └─ single WriteFile(conin)  → ConPTY → shell
```

Key facts about the pipe, each verified during the investigation:

- **`flutter_pty` is a clean byte pipe.** `Pty.write`
  (`flutter_pty/lib/flutter_pty.dart`) makes one FFI call with the whole
  buffer; native `pty_write` (`flutter_pty/src/flutter_pty_win.c`) does
  one `malloc`+`memcpy` and enqueues a single `WriteRequest`; the writer
  thread issues one `WriteFile(fd, req->data, req->length, …)`. The
  `\e[200~ … \e[201~` sequence is never split. Paste bugs do **not**
  live here.
- **The engine does not normalize.** `TerminalEngine.write()` just
  forwards bytes onto `output`, which Octodo pipes straight into
  `pty.write` (`terminal_view.dart:1012`). Whatever `_pasteBytes` emits
  reaches ConPTY unchanged.
- **Enter is `\r`.** `flutter_alacritty/input/key_input.dart` returns
  `[0x0d]` for `Enter`. The PTY treats CR as Return.
- **The Windows clipboard is CRLF.** `Clipboard.getData('text/plain')`
  returns `\r\n` line endings. This is the root of the second bug below.

## `_pasteBytes` — the only place paste bytes are shaped

`lib/src/terminal/terminal_view.dart:2003`

```dart
Uint8List _pasteBytes(String text, {required int modeFlags}) {
  if (modeFlags & TerminalViewState.bracketedPasteModeFlag != 0) {
    final safe = text
        .replaceAll(RegExp(r'\r\n|\r'), '\n')   // CRLF / lone CR → LF
        .replaceAll(RegExp(r'[\x1b\x03]'), ''); // strip ESC / Ctrl+C
    return Uint8List.fromList([
      ...'\x1b[200~'.codeUnits,
      ...utf8.encode(safe),
      ...'\x1b[201~'.codeUnits,
    ]);
  }
  return Uint8List.fromList(utf8.encode(text));   // non-bracketed: raw
}
```

The two branches have **different** and **incompatible** newline rules.
This is intentional and explained below.

## Bug 1 — the bracketed-paste mode bit was wrong

`commit 66b1bb9`

`grid.modeFlags` carries the real `TermMode` bits (the mouse-reporting
bits `1<<3` / `1<<6` / `1<<13` are read from the same field and are
confirmed correct by `test/terminal_drag_select_test.dart`).
`flutter_alacritty/input/term_mode.dart` defines:

```dart
const int kModeBracketedPaste = 1 << 4;   // DECSET 2004
```

But `_pasteBytes` was checking `0x20000000` (bit 29) — a bit that no
`TermMode` flag ever sets. So `modeFlags & 0x20000000` was always `0`,
the bracketed branch was dead code, and every paste took the raw path.
The shell raced on multi-line input (commands echoed with extra newlines
instead of running) even though `bind -v | grep bracketed` reported the
mode `on` inside the pane.

**Fix:** the literal is now `TerminalViewState.bracketedPasteModeFlag`
(`1 << 4`), `@visibleForTesting`, mirrored from
`flutter_alacritty/input/term_mode.dart`. The barrel
`flutter_alacritty.dart` does **not** export `input/term_mode.dart`, which
is why Octodo carries a local mirror — the same reason it carries a local
mirror of the mouse bits.

### TermMode bit mirror (keep in lockstep with flutter_alacritty)

| Mode                | Bit     | Value    | DECSET  |
| ------------------- | ------- | -------- | ------- |
| `kModeAppCursor`    | `1 << 1`| `0x0002` | DECSET 1 |
| `kModeAppKeypad`    | `1 << 2`| `0x0004` | — |
| `kModeMouseClick`   | `1 << 3`| `0x0008` | DECSET 1000 |
| `kModeBracketedPaste` | `1 << 4` | `0x0010` | DECSET 2004 |
| `kModeSgrMouse`     | `1 << 5`| `0x0020` | DECSET 1006 |
| `kModeMouseMotion`  | `1 << 6`| `0x0040` | DECSET 1002 |
| `kModeFocusInOut`   | `1 << 11`| `0x0800`| DECSET 1004 |
| `kModeAltScreen`    | `1 << 12`| `0x1000`| DECSET 1049 |
| `kModeMouseDrag`    | `1 << 13`| `0x2000`| DECSET 1003 |

`test/paste_bytes_test.dart` and `test/terminal_drag_select_test.dart`
pin the literals actually used by Octodo so a future bit renumbering
fails loudly instead of silently breaking paste or mouse selection.

## Bug 2 — CRLF inside the bracket caused a blank line per command

`commit 9dbfeb4`

With bug 1 fixed, the bracketed branch finally fired — but a Windows
clipboard (`\r\n`) pasted into WSL bash showed a blank line between
every command. Cause: the payload was sent with `\r\n` untouched, and
bash/readline inserts **one line break for the CR and another for the
LF**, doubling every line break.

Upstream alacritty (`alacritty/src/event.rs`, `fn paste`) also sends the
bracketed payload raw — but its Linux/macOS clipboards are already LF, so
the issue never surfaces there. Octodo runs on Windows, where the
clipboard is CRLF, so it must collapse `\r\n` / lone `\r` → `\n` inside
the bracket itself. Apps that opt into bracketed paste
(bash/zsh/fish/vim/readline) expect LF as the line separator in pasted
data.

ESC (`\x1b`) and Ctrl+C (`\x03`) are still stripped from the payload so
an embedded `\e[201~` cannot close the bracket early — matches
`alacritty/src/event.rs:paste`.

## Why non-bracketed stays raw

When `enable-bracketed-paste` is off (or the shell does not advertise
DECSET 2004), `_pasteBytes` sends the bytes **raw** — no newline
normalization. Two reasons:

1. **ConPTY mishandles a bare CR.** The classic Unix-PTY rule (and
   upstream alacritty's non-bracketed path) is to collapse every line
   ending to a single `\r` so each line is submitted as one Enter.
   Empirically this is wrong on Octodo's ConPTY→WSL path: ConPTY plus
   the Linux PTY's ICRNL double-process a lone CR and insert an extra
   blank line per command. Raw `\r\n` does not have that problem.
2. **Multi-line paste is inherently racy in non-bracketed mode anyway.**
   The shell executes line 1 the instant its newline arrives, so the
   remaining pasted lines collide with whatever line 1 spawned. Example
   observed in the wild: `sudo mkdir …` prompted for a password and
   swallowed `curl -` from the next pasted line as the password, leaving
   `fsSL …` to run as a command. No terminal can fix this — it is
   precisely the problem bracketed paste was invented to solve.

**Recommendation:** keep `enable-bracketed-paste on` (the bash default).
That is the supported path and it is now correct end-to-end.

## Reference: upstream alacritty's three paste cases

`alacritty/src/event.rs::paste(text, bracketed)` distinguishes three
cases, useful as the authoritative reference:

| Condition                                             | Output                                                  |
| ----------------------------------------------------- | ------------------------------------------------------- |
| `bracketed && mode has BRACKETED_PASTE`               | `\e[200~` + text (ESC/Ctrl-C stripped, newlines raw) + `\e[201~` |
| `bracketed` but mode lacks `BRACKETED_PASTE`          | line endings collapsed to `\r` (keystroke simulation)   |
| not a paste (e.g. single-char IME commit)             | raw                                                     |

Octodo matches case 1 (plus the Windows-CRLF→LF fix) and deliberately
diverges from case 2 (stays raw rather than collapsing to `\r`) because
of the ConPTY behavior above.

## Test surface

`test/paste_bytes_test.dart` exercises both branches through the
`TerminalViewState.pasteBytesForTest` `@visibleForTesting` seam
(`terminal_view.dart:434`):

- the bracketed-paste **bit value** (`1 << 4`, and that it does not
  collide with the mouse bits);
- bracketed **CRLF → LF**, lone-CR → LF, existing-LF preserved, ESC/Ctrl-C
  stripped, and a regression guard asserting no `0x0d` (CR) in the
  payload;
- non-bracketed **raw pass-through** (CRLF unchanged, LF unchanged, lone
  CR unchanged), with an explicit regression guard that CRLF is **never**
  collapsed to CR.
