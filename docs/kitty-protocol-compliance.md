# Kitty protocol compliance for `Ctrl + (other modifier) + printable`

## Goal

`flutter_alacritty`'s `encodeKeyWithKitty` (the engine that feeds
bytes into the PTY) currently emits a CSI-u sequence for `Ctrl + letter`
**only when no other modifier is held**. As soon as the user presses
`Ctrl + Shift + P` (or `Ctrl + Alt + R`, `Ctrl + Meta + T`, …) the
function returns `null` and the keystroke falls through to the legacy
`encodeKey`, which writes the bare control byte — losing the
sub-modifier information that the Kitty protocol requires.

The fix is a **hybrid policy**:

- **Disambiguating cases** (`Ctrl+I` vs Tab, `Ctrl+M` vs Enter,
  `Ctrl+[` vs Escape, `Ctrl+Space` vs NUL) — emit a full CSI-u
  sequence so the app can distinguish the chords. The `mods` field
  carries the *entire* modifier mask, so `Ctrl+Shift+I` and `Ctrl+I`
  arrive as distinct events.
- **Unique-byteset cases** (`Ctrl+P`, `Ctrl+R`, `Ctrl+T`, `Ctrl+N`,
  …) — fall through to `encodeKey` and emit the legacy byte
  directly. Every modern TUI that we care about (opencode,
  Claude Code, Codex CLI, btop, htop) binds its `Ctrl+P` /
  `Ctrl+R` / etc. on the legacy byte, so emitting the legacy
  byte directly makes the keystroke work even with TUIs that
  only listen on legacy bytes (which is the common pattern).

After the fix:

- `Ctrl + P`          → `\x10`  (legacy, unchanged in effect)
- `Ctrl + Shift + P`  → `\x10`  (legacy; was already what the user
                          observed working pre-patch)
- `Ctrl + I`          → `CSI 9 ; 5 u`   (disambiguated from Tab)
- `Ctrl + Shift + I`  → `CSI 9 ; 6 u`   (shift included in mods)
- `Ctrl + M`          → `CSI 13 ; 5 u`  (disambiguated from Enter)
- `Ctrl + [`          → `CSI 27 ; 5 u`  (disambiguated from Escape)
- `Ctrl + Space`      → `CSI 0 ; 5 u`   (disambiguated from NUL)
- `Shift + P`         → `CSI 80 ; 2 u`  (unchanged)
- `Enter` under Ctrl  → `CSI 13 ; 5 u` (unchanged)

Apps inside the PTY (opencode, Claude Code, Codex CLI, btop, htop,
vim, …) all receive the correct encoding for their keybindings.

## Why "hybrid" instead of "strict"

A strict reading of the Kitty spec would say: under flag 1, every
modified key must arrive as a CSI-u sequence — including
`Ctrl + P` as `CSI 16;5 u`. That's what the original draft of this
patch did. It turned out that **opencode in the user's setup binds
its command panel on the legacy byte `\x10` and does not match
`CSI 16;5 u`**, even though it pushes flag 1. PowerShell and stock
alacritty (which the user tested as controls) send the legacy byte
under their default configs, so opencode's `Ctrl+P` panel fires in
those setups — but with the strict patch, the same key inside Octodo
fired nothing in opencode.

The hybrid policy keeps the strict protocol behaviour for every
case where the protocol actually adds disambiguation value
(`Ctrl+I`/Tab, `Ctrl+M`/Enter, `Ctrl+[`/Esc, `Ctrl+Space`/NUL)
while emitting the legacy byte — which is the canonical encoding for
*every* Ctrl-letter whose legacy byte is unique — directly. That
gives opencode, Claude Code, Codex CLI, btop, and htop exactly the
bytes they bind on, and gives any TUI that does enable strict
flag-1 handling on the four disambiguating cases the full CSI-u
form.

## Root cause

`invented-pro/flutter_alacritty` is pinned at `5c995bf` (ref
`2026.07.04`). The relevant code is in
`lib/input/kitty_keyboard.dart`, function `encodeKeyWithKitty`:

```dart
// 2. Ctrl + letter → keycode is the Ctrl control byte (1..26). Same
// for Ctrl + a few non-letter symbols that produce stable control
// bytes (matching the legacy encoder's `if (ctrl)` block).
if (ctrl && !shift && !alt && !meta && !superPressed) {
  final ch = (character != null && character.length == 1)
      ? character
      : (key.keyLabel.length == 1 ? key.keyLabel : null);
  if (ch != null) {
    final c = ch.toLowerCase().codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7a) return _csiU(c - 0x60, mods); // a..z
    switch (ch) {
      case ' ': return _csiU(0x00, mods);
      case '[': return _csiU(0x1b, mods);
      case '\\': return _csiU(0x1c, mods);
      case ']': return _csiU(0x1d, mods);
      case '^': return _csiU(0x1e, mods);
      case '_':
      case '/': return _csiU(0x1f, mods);
    }
  }
  if (key == LogicalKeyboardKey.space) return _csiU(0x00, mods);
}
```

The `&& !shift && !alt && !meta && !superPressed` clause is the bug.
It means `Ctrl+Shift+P`, `Ctrl+Alt+R`, `Ctrl+Meta+T`, etc. all skip
branch 2 entirely and fall through to `encodeKey`, which writes the
bare legacy byte. The fix relaxes the qualifier so the branch
matches whenever Ctrl is held, and adds a disambiguation check
inside so only the four ambiguous cases emit CSI-u.

`Octodo`'s own code does **not** need to change. Verified:

- `lib/main.dart:503` (`_handleEarlyKeyEvent`) iterates
  `_mergedShortcuts` which is `AppShellBindings + WorkspaceBindings
  + TerminalBindings`. None of those contain `LogicalKeyboardKey.keyP`
  (or any other Ctrl-letter) — the audit at
  `test/app_shortcuts_test.dart:285` (`no bare Ctrl-letter is bound`)
  pins this and passes today.
- `lib/src/terminal/terminal_workspace.dart:1092` (`CallbackShortcuts`
  wrapping the workspace) — uses `WorkspaceBindings`. No Ctrl-letter.
- `lib/src/terminal/terminal_view.dart:883` (`CallbackShortcuts`
  wrapping each `TerminalView`) — uses `TerminalBindings` plus
  readline passthrough for `Ctrl+U/K/L/A/E` only. No `Ctrl+P/R/T/...`.

So the keystroke *reaches* `fa.TerminalView`'s `_onKeyFallback` for
every Ctrl-letter combo. What `flutter_alacritty` does with it from
there is what we're fixing.

## Patch

### `lib/input/kitty_keyboard.dart` — branch 2 of `encodeKeyWithKitty`

Relax the `if (ctrl && !shift && !alt && !meta && !superPressed)`
qualifier to `if (ctrl)`, and inside the branch only emit CSI-u for
the four ambiguous cases:

```dart
// 2. Ctrl + printable, with any combination of modifiers. We only emit
//    CSI-u for the cases where the legacy control byte collides with
//    another key:
//      Ctrl+I  (0x09) collides with Tab
//      Ctrl+M  (0x0D) collides with Enter
//      Ctrl+[  (0x1B) collides with Escape
//      Ctrl+Space (0x00) collides with NUL
//    For everything else (Ctrl+P = 0x10, Ctrl+R = 0x12, Ctrl+T = 0x14,
//    Ctrl+N = 0x0E, …) the legacy byte is unique, so we fall through
//    to `encodeKey` and emit it directly. Apps that listen on the
//    legacy byte — opencode's command panel matching on \x10, btop /
//    htop history keys, etc. — keep working unchanged, and apps that
//    bind Ctrl+I / Ctrl+M / Ctrl+[ on the CSI-u form still get full
//    disambiguation from Tab / Enter / Escape (with the full modifier
//    mask in `mods`).
if (ctrl) {
  final ch = (character != null && character.length == 1)
      ? character
      : (key.keyLabel.length == 1 ? key.keyLabel : null);
  if (ch != null) {
    final c = ch.toLowerCase().codeUnitAt(0);
    // Ctrl+I (0x69) collides with Tab (0x09); Ctrl+M (0x6D) collides
    // with Enter (0x0D). Emit CSI-u so the app can disambiguate.
    if (c == 0x69 /*i*/ || c == 0x6d /*m*/) {
      return _csiU(c - 0x60, mods);
    }
    // Ctrl+[ (0x5B) collides with Escape (0x1B). Emit CSI-u.
    if (ch == '[') {
      return _csiU(0x1b, mods);
    }
    // Other Ctrl+letter / Ctrl+symbol: unique legacy byte — let
    // `encodeKey` emit it.
  }
  // Ctrl+Space (0x20 / 0x00) collides with NUL. Emit CSI-u. Done
  // outside the `ch != null` guard because Windows sometimes delivers
  // character = null for Space.
  if (key == LogicalKeyboardKey.space) {
    return _csiU(0x00, mods);
  }
  // Other Ctrl+letter / Ctrl+symbol: unique legacy byte; let
  // `encodeKey` emit it so apps listening on the legacy byte see
  // Ctrl+P, Ctrl+R, Ctrl+T, … as a stock alacritty would.
}
```

Two diffs from the source:

1. The outer `if` no longer has `&& !shift && !alt && !meta && !superPressed`.
2. Inside, the unconditional `return _csiU(c - 0x60, mods)` for
   letters a..z is replaced with a conditional that only returns
   CSI-u for `i` / `m` / `[`. The other switch cases
   (`\\`, `]`, `^`, `_`, `/`) are dropped — those legacy bytes
   (`0x1C`, `0x1D`, `0x1E`, `0x1F`) are also unique and should be
   emitted directly by `encodeKey`.

### Behaviour-matrix doc comment

Update the matrix at the top of `encodeKeyWithKitty` so the contract
is honest:

```dart
/// Behaviour matrix:
///
///   * `kitty.disambiguate == false` → null (legacy owns it).
///   * No modifier flags pressed → null (legacy byte is the same).
///   * Functional key (Enter, Tab, arrows, F-keys, ...) with any mods
///     → `CSI <keycode> ; <mods> u`.
///   * Ctrl + printable, with any modifier combination →
///     `CSI <ctrl-byte> ; <mods> u` only when the legacy byte collides
///     with another key (Ctrl+I ↔ Tab, Ctrl+M ↔ Enter, Ctrl+[ ↔ Escape,
///     Ctrl+Space ↔ NUL). For every other Ctrl+letter (Ctrl+P, Ctrl+R,
///     Ctrl+T, …) — whose legacy byte is unique — we fall through to
///     `encodeKey` and emit the legacy byte directly. The `mods` field
///     of the emitted CSI-u sequence carries the full modifier mask,
///     so Ctrl+Shift+I / Ctrl+I arrive as distinct events for apps
///     that bind on the CSI-u form.
///   * Printable with Shift / Alt / Meta / Super (no Ctrl) →
///     `CSI <codepoint> ; <mods> u`, using the *shifted* character so
///     the program can recover both the logical key and the produced
///     text in one sequence.
///
/// Per the spec, plain (unmodified) keys keep their legacy byte under
/// flag 1 — only modified keys change format. For Ctrl+letter, we
/// only emit CSI-u where the legacy byte is ambiguous; everywhere else
/// the legacy byte is the canonical encoding that modern TUIs bind on
/// (opencode's command panel on `\x10`, etc.).
```

## Byte-level before / after

| Chord                     | Before                          | After (hybrid)                  |
| ------------------------- | ------------------------------- | ------------------------------- |
| `Ctrl+P`                  | `CSI 16;5 u`                    | `\x10` (fall through)           |
| `Ctrl+Shift+P`            | `\x10` (legacy)                 | `\x10` (fall through)           |
| `Ctrl+Alt+P`              | `\x10` (legacy)                 | `\x10` (fall through)           |
| `Ctrl+Meta+P`             | `\x10` (legacy)                 | `\x10` (fall through)           |
| `Ctrl+Shift+Alt+P`        | `\x10` (legacy)                 | `\x10` (fall through)           |
| `Ctrl+R`                  | `CSI 18;5 u`                    | `\x12` (fall through)           |
| `Ctrl+Shift+R`            | `\x12` (legacy)                 | `\x12` (fall through)           |
| `Ctrl+T`                  | `CSI 20;5 u`                    | `\x14` (fall through)           |
| `Ctrl+I` (≡ Tab legacy)   | `CSI 9;5 u`                     | `CSI 9;5 u` (unchanged)         |
| `Ctrl+Shift+I`            | `\x09` (legacy, ambiguous!)     | `CSI 9;6 u`                     |
| `Ctrl+M` (≡ Enter legacy) | `CSI 13;5 u`                    | `CSI 13;5 u` (unchanged)        |
| `Ctrl+Shift+M`            | `\x0D` (legacy, ambiguous!)     | `CSI 13;6 u`                    |
| `Ctrl+[` (≡ Esc legacy)   | `CSI 27;5 u`                    | `CSI 27;5 u` (unchanged)        |
| `Ctrl+Shift+[`            | `\x1B` (legacy, ambiguous!)     | `CSI 27;6 u`                    |
| `Ctrl+Space`              | `CSI 0;5 u`                     | `CSI 0;5 u` (unchanged)         |
| `Shift+P`                 | `P` or `CSI 80;2 u`*            | `CSI 80;2 u`                    |
| `Alt+P`                   | `\x1b p`                        | `CSI 112;3 u`                   |

\* The "Shift+P" row was already split: `encodeKeyWithKitty` returned
`CSI 80;2 u` when `character` was the shifted glyph (`P`), but fell
through to `encodeKey` (which wrote a raw `P`) when Flutter's
`event.character` was `null`. That inconsistency goes away too because
the relaxed Ctrl branch covers `Shift+P` consistently via branch 3.

## Downstream effect on apps inside the PTY

These tools opt into flag 1. After the hybrid fix:

- **`opencode`** — `Ctrl+P` opens the command panel via the legacy
  byte `\x10` (the binding opencode listens on). `Ctrl+R` likewise.
  `Ctrl+Shift+P` also arrives as `\x10` and is interpreted as Ctrl+P
  (same as in stock alacritty / PowerShell — the historical
  behaviour).
- **`Claude Code`** — same story. Its `Ctrl+R` reverse-history
  binding receives `\x12`. Future bindings on `Ctrl+Shift+R` would
  collapse to `\x12` as before.
- **`Codex CLI`** — same.
- **`vim`** — `Ctrl+I` arrives as `CSI 9;5 u` (correctly
  disambiguated from Tab); `Ctrl+P` arrives as `\x10`; etc.
- **`btop`/`htop`** — unaffected. They bind on legacy bytes which
  is exactly what we emit.

## Octodo-side: no change required

The existing tests already lock down the Octodo side of the contract:

- `test/app_shortcuts_test.dart:285` — `no bare Ctrl-letter is bound`
  enforces that none of `AppShellBindings / WorkspaceBindings /
  TerminalBindings` contain a bare Ctrl-letter activator (with `keyP`
  in the readline-keys set). Passes today, will continue to pass after
  the patch.

The keystroke path `HardwareKeyboard → FocusManager.handleKeyMessage
→ early handlers (no match for Ctrl+P) → focus tree walk →
fa.TerminalView._onKeyFallback → encodeKeyWithKitty → ?? encodeKey →
_engine.write → PTY` is fully wired; once `encodeKeyWithKitty` returns
the right encoding (CSI-u for ambiguous cases, null for the rest),
the bytes reach the TUI unmodified.

## Test plan (in the `flutter_alacritty` fork)

Added `test/kitty_keyboard_test.dart` with 25 cases:

- **Ambiguous Ctrl+letter** (CSI-u emitted):
  `Ctrl+I`, `Ctrl+Shift+I`, `Ctrl+Alt+I`, `Ctrl+M`, `Ctrl+Shift+M`,
  `Ctrl+[`, `Ctrl+Shift+[`, `Ctrl+Space`, `Ctrl+Space` with `null`
  character — all assert their expected `CSI <code>;<mods> u` form.
- **Non-ambiguous Ctrl+letter** (falls through to null):
  `Ctrl+P`, `Ctrl+Shift+P`, `Ctrl+Alt+P`, `Ctrl+Meta+P`,
  `Ctrl+Super+P`, `Ctrl+Shift+Alt+P`, `Ctrl+R`, `Ctrl+Shift+R`,
  `Ctrl+T`, `Ctrl+N` — all assert `encodeKeyWithKitty` returns
  `null` (so `encodeKey` is used and emits the legacy byte).
- **Guard rails**:
  - `kitty.disambiguate == false` → null for Ctrl+P
  - no modifier → null for plain printable
  - Shift only → `CSI 80;2 u`
  - Alt only → `CSI 112;3 u`
  - Enter under Ctrl → `CSI 13;5 u` (functional-key path)
  - Tab under Ctrl+Shift → `CSI 9;6 u` (still disambiguated from
    Ctrl+I)

These tests pin the contract so future refactors of
`encodeKeyWithKitty` can't silently regress.

## Rollout

1. Apply the patch on `invented-pro/flutter_alacritty`, push to a new
   branch, open a PR.
2. Tag a new ref, e.g. `2026.07.04-kitty-hybrid-ctrl`.
3. In the Octodo repo:
   - `pubspec.yaml`: bump `flutter_alacritty.ref` from `2026.07.04`
     to the new ref.
   - `flutter pub get` to refresh `pubspec.lock`.
   - `flutter test` — confirm both the new `flutter_alacritty` tests
     and Octodo's existing `app_shortcuts_test` pass.
4. Smoke-test in the running app:
   - Launch `opencode` inside Octodo.
   - `Ctrl+P` → command panel opens.
   - `Ctrl+R` → reverse-history search opens.
   - `Ctrl+T` → whatever opencode binds it to.
   - `Ctrl+I`, `Ctrl+M`, `Ctrl+[` still reach the TUI as
     CSI-u sequences (apps that bind on the form will see them).
5. Update the Octodo changelog:
   - "Hybrid Kitty-protocol policy for Ctrl+letter: emit CSI-u only
     for the cases where the legacy byte collides with another key
     (Ctrl+I/M/[/Space). All other Ctrl+letter emit the legacy
     byte, matching stock alacritty / PowerShell behaviour for
     `Ctrl+P` / `Ctrl+R` / `Ctrl+T` in modern TUIs."