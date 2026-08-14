// Pins the POSIX OSC 7 cwd-reporting injections in TerminalWorkspaceState:
//
//   - the zsh `ZDOTDIR` `.zshenv` shim (`_zshEnvShim` +
//     `_ensureZshOsc7Integration`) — stock zsh emits no OSC 7 and reads no
//     env-var hooks, so cwd reporting has to be injected through the one
//     startup seam zsh exposes via the environment.
//   - the fish `--init-command` snippet (`_fishOsc7Init`) — fish reads no
//     env-var hooks either; `-C` code runs after the user's config.fish
//     and before the first prompt.
//
// These are golden-style string/file pins (same philosophy as
// pwsh_init_test.dart): spawning real shells in unit tests would make CI
// depend on the host's shell config. The zsh shim's behavior WAS verified
// against a real /bin/zsh during development (macOS, zsh 5.9):
//   - the precmd hook emits `\033]7;file://<host><cwd>\033\\` before the
//     first prompt,
//   - the user's own ~/.zshenv / .zshrc still load (ZDOTDIR is restored
//     before zsh looks for .zprofile / .zshrc / .zlogin),
//   - nested zsh processes inherit the restored (real) ZDOTDIR and do not
//     re-run the shim.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/terminal_workspace.dart';

void main() {
  group('zsh .zshenv shim (_zshEnvShim)', () {
    final shim = TerminalWorkspaceState.zshEnvShimForTest('/Users/tester');

    test(
      'restores the real ZDOTDIR first (so .zprofile/.zshrc/.zlogin load normally)',
      () {
        // The restore must appear BEFORE the hook registration and the
        // .zshenv chain so everything downstream sees the real ZDOTDIR.
        final restoreIdx = shim.indexOf("export ZDOTDIR='/Users/tester'");
        expect(restoreIdx, greaterThanOrEqualTo(0));
        final hookIdx = shim.indexOf('_octodo_osc7()');
        final chainIdx = shim.indexOf(r'source "$ZDOTDIR/.zshenv"');
        expect(
          hookIdx,
          greaterThan(restoreIdx),
          reason: 'the hook must be registered after ZDOTDIR is restored',
        );
        expect(
          chainIdx,
          greaterThan(restoreIdx),
          reason: 'the user .zshenv chain must use the restored ZDOTDIR',
        );
      },
    );

    test('registers an OSC 7 precmd hook on precmd_functions', () {
      expect(shim, contains('precmd_functions+=(_octodo_osc7)'));
      // The double-append guard: re-sourcing the shim (or a user copying
      // it) must not stack duplicate emissions.
      expect(shim, contains('*" _octodo_osc7 "*'));
    });

    test(
      'emits OSC 7 via printf with ST terminator (verified against real zsh)',
      () {
        // printf '\033]7;file://%s%s\033\\' "$HOST" "$PWD" — zsh single
        // quotes pass the escapes through so printf expands them; $HOST is
        // zsh-native (no $(hostname) subprocess per prompt).
        expect(
          shim,
          contains(r'''printf '\033]7;file://%s%s\033\\' "$HOST" "$PWD"'''),
        );
      },
    );

    test('chains to the user real .zshenv (skipped because zsh read ours)', () {
      expect(
        shim,
        contains(r'[[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"'),
      );
    });

    test('single quotes in the real ZDOTDIR are escaped', () {
      final shim = TerminalWorkspaceState.zshEnvShimForTest("/home/o'brien");
      expect(shim, contains(r"export ZDOTDIR='/home/o'\''brien'"));
    });
  });

  group('_ensureZshOsc7Integration (temp dir writer)', () {
    test(
      'writes a .zshenv inside <tmp>/octodo_zsh_integration and returns the dir',
      () async {
        final dirPath =
            await TerminalWorkspaceState.writeZshIntegrationForTest();
        expect(dirPath, endsWith('octodo_zsh_integration'));
        final zshenv = File('$dirPath/.zshenv');
        expect(
          zshenv.existsSync(),
          isTrue,
          reason: 'ZDOTDIR is only useful if .zshenv exists inside it',
        );
        final content = zshenv.readAsStringSync();
        expect(content, contains('precmd_functions+=(_octodo_osc7)'));
        expect(content, contains('export ZDOTDIR='));
      },
    );

    test(
      'cached dir path is returned on subsequent calls (idempotent)',
      () async {
        final first = await TerminalWorkspaceState.writeZshIntegrationForTest();
        final second =
            await TerminalWorkspaceState.writeZshIntegrationForTest();
        expect(second, first);
      },
    );
  });

  group('fish --init-command snippet (_fishOsc7Init)', () {
    final init = TerminalWorkspaceState.fishOsc7InitForTest;

    test('registers a handler on the fish_prompt event', () {
      expect(init, contains('--on-event fish_prompt'));
    });

    test(r'emits OSC 7 with hostname + $PWD via printf (BEL terminator)', () {
      // printf '\033]7;file://%s%s\a' (hostname) "$PWD" — single quotes
      // keep the escapes literal for printf to expand; $PWD is quoted so
      // paths with spaces stay one argv element.
      expect(init, contains(r"printf '\033]7;file://%s%s\a'"));
      expect(init, contains(r'(hostname) "$PWD"'));
    });

    test(
      'is one self-contained statement (passed as a single argv element)',
      () {
        // _makeSurface appends it as ONE argument after -C; it must not
        // depend on newlines or multi-line function bodies.
        expect(init.contains('\n'), isFalse);
        expect(init, startsWith('function __octodo_osc7'));
        expect(init, endsWith('end'));
      },
    );
  });
}
