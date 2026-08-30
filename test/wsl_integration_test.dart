// Pins the WSL-side shell-integration plumbing in TerminalWorkspaceState:
//
//   - `_composeWslenv` — the single WSLENV composition for WSL surfaces.
//     History: two inline appends each rebuilt the value, the second one
//     from `Platform.environment`, silently dropping the first block's
//     OPENTUI_NOTIFICATION_PROTOCOL entry — WSL sessions (and interop
//     Windows children) never saw the OpenTUI notification override.
//   - `_windowsPathToWslPath` — the drvfs translation for the ZDOTDIR
//     shim dir (WSLENV forwards values verbatim, so the WSL side needs
//     the already-translated /mnt/<drive>/… form).
//   - `_ensureZshOsc7Integration` per-realZdotdir caching — a Windows
//     host spawns WSL distros with different $HOMEs; a shared cache
//     would hand one distro another distro's restore path.
//
// Golden-style string pins (same philosophy as posix_osc7_init_test.dart
// and pwsh_init_test.dart). The shim's behavior against a real WSL zsh
// was verified manually during development (Debian, zsh 5.2 via wsl.exe).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/terminal_workspace.dart';

void main() {
  group('WSLENV composition (composeWslenv)', () {
    test('includes the flagless OpenTUI override (both directions)', () {
      // Flagless is deliberate: /u only travels Win32→WSL, but
      // `opencode` in a WSL tab commonly resolves via PATH interop to
      // the WINDOWS install (npm shim → node.exe) — a Windows child
      // that only receives /w or unflagged entries.
      final wslenv = TerminalWorkspaceState.composeWslenvForTest(
        '',
        bashIntegration: true,
        zshIntegration: true,
      );
      expect(wslenv, contains('OPENTUI_NOTIFICATION_PROTOCOL'));
      expect(
        wslenv.split(':'),
        contains('OPENTUI_NOTIFICATION_PROTOCOL'),
      );
    });

    test('bash and zsh entries carry /u', () {
      final wslenv = TerminalWorkspaceState.composeWslenvForTest(
        '',
        bashIntegration: true,
        zshIntegration: true,
      );
      final entries = wslenv.split(':').toSet();
      expect(entries, contains('PROMPT_COMMAND/u'));
      expect(entries, contains('PS0/u'));
      expect(entries, contains('ZDOTDIR/u'));
    });

    test('zsh entry absent when no ZDOTDIR was injected', () {
      final wslenv = TerminalWorkspaceState.composeWslenvForTest(
        '',
        bashIntegration: true,
        zshIntegration: false,
      );
      expect(wslenv, isNot(contains('ZDOTDIR')));
    });

    test('preserves user entries and never clobbers earlier ones', () {
      // The regression this pins: the value must accumulate — an
      // OPENTUI entry already present must survive a later compose
      // that adds PROMPT_COMMAND/PS0.
      final wslenv = TerminalWorkspaceState.composeWslenvForTest(
        'MY_VAR/p',
        bashIntegration: true,
        zshIntegration: true,
      );
      final entries = wslenv.split(':');
      expect(entries.first, 'MY_VAR/p');
      expect(entries, contains('OPENTUI_NOTIFICATION_PROTOCOL'));
      expect(entries, contains('PROMPT_COMMAND/u'));
      expect(entries, contains('PS0/u'));
      expect(entries, contains('ZDOTDIR/u'));
    });

    test('dedupes by variable NAME, not substring', () {
      // A user's own flagged entry must not gain a duplicate; a var
      // whose name merely CONTAINS another's must not be skipped.
      final wslenv = TerminalWorkspaceState.composeWslenvForTest(
        'PS0/w:MY_PROMPT_COMMAND/u',
        bashIntegration: true,
        zshIntegration: false,
      );
      final entries = wslenv.split(':');
      expect(entries.where((e) => e.startsWith('PS0')), ['PS0/w']);
      expect(
        entries,
        contains('PROMPT_COMMAND/u'), // MY_PROMPT_COMMAND is a different var
      );
    });

    test('empty existing produces no leading/trailing separators', () {
      final wslenv = TerminalWorkspaceState.composeWslenvForTest(
        '',
        bashIntegration: true,
        zshIntegration: false,
      );
      expect(wslenv, isNot(startsWith(':')));
      expect(wslenv, isNot(endsWith(':')));
      expect(wslenv, isNot(contains('::')));
    });
  });

  group('Windows → WSL path translation (windowsPathToWslPath)', () {
    test('drive-letter path with backslashes', () {
      expect(
        TerminalWorkspaceState.windowsPathToWslPathForTest(
          r'C:\Users\Sun\AppData\Local\Temp\octodo_zsh_integration\home_s1',
        ),
        '/mnt/c/Users/Sun/AppData/Local/Temp/octodo_zsh_integration/home_s1',
      );
    });

    test('accepts forward slashes and lowercases the drive', () {
      expect(
        TerminalWorkspaceState.windowsPathToWslPathForTest('D:/Temp Dir/x'),
        '/mnt/d/Temp Dir/x',
      );
    });

    test('relative and UNC paths are rejected (null)', () {
      expect(
        TerminalWorkspaceState.windowsPathToWslPathForTest('Temp/x'),
        isNull,
      );
      expect(
        TerminalWorkspaceState.windowsPathToWslPathForTest(r'\\server\share'),
        isNull,
      );
    });
  });

  group('zsh shim dir caching (_ensureZshOsc7Integration)', () {
    test(
      'distinct realZdotdirs get distinct dirs baking their own restore',
      () async {
        final alice = await TerminalWorkspaceState
            .writeZshIntegrationForTest(realZdotdir: '/home/alice');
        final bob = await TerminalWorkspaceState
            .writeZshIntegrationForTest(realZdotdir: '/home/bob');

        expect(alice, isNot(bob));
        expect(
          File('$alice/.zshenv').readAsStringSync(),
          contains("export ZDOTDIR='/home/alice'"),
        );
        expect(
          File('$bob/.zshenv').readAsStringSync(),
          contains("export ZDOTDIR='/home/bob'"),
        );
      },
    );

    test(
      'null realZdotdir (WSL) bakes a dynamic \$HOME restore — no '
      'upfront distro query needed',
      () async {
        final dir = await TerminalWorkspaceState
            .writeZshIntegrationForTest(realZdotdir: null);
        final content = File('$dir/.zshenv').readAsStringSync();
        expect(content, contains('export ZDOTDIR="\$HOME"'));
        expect(content, isNot(contains("export ZDOTDIR='")));
        // Still registers the full hook set.
        expect(content, contains('precmd_functions+=(_octodo_osc7)'));
        expect(content, contains(r'preexec_functions+=(_octodo_133c)'));
        // And does not collide with a baked dir.
        final baked = await TerminalWorkspaceState
            .writeZshIntegrationForTest(realZdotdir: '/home/bob');
        expect(dir, isNot(baked));
      },
    );

    test('same realZdotdir reuses the cached dir', () async {
      final first = await TerminalWorkspaceState
          .writeZshIntegrationForTest(realZdotdir: '/home/dup');
      final second = await TerminalWorkspaceState
          .writeZshIntegrationForTest(realZdotdir: '/home/dup');
      expect(first, second);
    });

    test('written with LF endings whatever the host checkout uses', () async {
      final dir = await TerminalWorkspaceState
          .writeZshIntegrationForTest(realZdotdir: '/home/lf');
      expect(
        File('$dir/.zshenv').readAsStringSync(),
        isNot(contains('\r')),
      );
    });
  });
}

