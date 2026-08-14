// Regression guard for issue #1: octodo used to force `-NoProfile` on every
// PowerShell launch, which suppresses the user's `$PROFILE`
// (Microsoft.PowerShell_profile.ps1) — exactly where oh-my-posh / oh-my-pwsh
// / starship / imported modules load. The reporter's oh-my-pwsh prompt never
// appeared for this reason. Windows Terminal loads `$PROFILE` by default; we
// now match that.
//
// `TerminalViewState._buildPtyLaunchArgs` is the single place the PTY
// `(program, args)` tuple is constructed. These tests pin the contract so a
// future contributor cannot silently reintroduce `-NoProfile` (or any other
// profile-suppressing flag) for PowerShell without also updating the
// docstring and failing here.
//
// Platform awareness: `_buildPtyLaunchArgs` has two branches:
//   - Windows: wraps everything in `cmd.exe /c "<real> <args>"` to work
//     around a flutter_pty 0.4.2 spawn quirk.
//   - macOS / Linux: passes through untouched (no ConPTY, no doubled-token
//     bug).
// Each test below branches on `Platform.isWindows` so the same regression
// contract is enforced on every host.

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/terminal_view.dart';

void main() {
  group('ptyLaunchArgsForTest', () {
    test('PowerShell 7: no -NoProfile (so \$PROFILE loads)', () {
      // Real-world program path detected by shell_profiles.dart; args carry
      // only `-NoLogo` from the profile.
      const program = r'C:\Program Files\PowerShell\7\pwsh.exe';
      final (ptyProgram, ptyArgs) =
          TerminalViewState.ptyLaunchArgsForTest(program, const ['-NoLogo']);

      if (Platform.isWindows) {
        // Windows wraps in cmd.exe /c. The executable path contains a
        // space, so it must survive cmd's /c parser wrapped in double
        // quotes; -NoLogo has no space so stays bare.
        expect(ptyProgram, 'cmd.exe');
        expect(ptyArgs, [
          '/c',
          r'"C:\Program Files\PowerShell\7\pwsh.exe"',
          '-NoLogo',
        ]);
      } else {
        // macOS / Linux: pwsh.exe (or whatever executable) is passed through
        // verbatim. No cmd.exe wrapper, no quoting layer.
        expect(ptyProgram, program);
        expect(ptyArgs, const ['-NoLogo']);
      }
      // The crux of issue #1: no token may suppress the profile.
      expect(
        ptyArgs,
        isNot(contains('-NoProfile')),
        reason: '-NoProfile would skip \$PROFILE and break oh-my-pwsh / '
            'oh-my-posh / starship prompts (issue #1).',
      );
    });

    test('Windows PowerShell: no -NoProfile', () {
      const program =
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
      final (ptyProgram, ptyArgs) =
          TerminalViewState.ptyLaunchArgsForTest(program, const ['-NoLogo']);
      if (Platform.isWindows) {
        expect(ptyProgram, 'cmd.exe');
      } else {
        expect(ptyProgram, program);
      }
      expect(ptyArgs, isNot(contains('-NoProfile')));
      expect(ptyArgs, contains('-NoLogo'));
    });

    test('PATH-resolved pwsh.exe (no spaces) still gets no -NoProfile', () {
      const program = r'C:\Users\me\scoop\shims\pwsh.exe';
      final (ptyProgram, ptyArgs) =
          TerminalViewState.ptyLaunchArgsForTest(program, const ['-NoLogo']);
      if (Platform.isWindows) {
        expect(ptyProgram, 'cmd.exe');
        // No spaces → no quoting needed.
        expect(ptyArgs, ['/c', program, '-NoLogo']);
      } else {
        expect(ptyProgram, program);
        expect(ptyArgs, const ['-NoLogo']);
      }
      expect(ptyArgs, isNot(contains('-NoProfile')));
    });

    test('CMD is launched as-is (no PowerShell-specific flags leaked)', () {
      const program = r'C:\Windows\System32\cmd.exe';
      final (ptyProgram, ptyArgs) =
          TerminalViewState.ptyLaunchArgsForTest(program, const []);
      if (Platform.isWindows) {
        expect(ptyProgram, 'cmd.exe');
        expect(ptyArgs, ['/c', program]);
      } else {
        expect(ptyProgram, program);
        expect(ptyArgs, isEmpty);
      }
      expect(ptyArgs, isNot(contains('-NoProfile')));
      expect(ptyArgs, isNot(contains('-NoLogo')));
    });

    test('WSL is launched with its args and never sees -NoProfile', () {
      // wsl.exe -d Ubuntu --cd ~ ; passing -NoProfile here would make wsl
      // try to run a Linux binary named "NoProfile".
      const program = r'C:\Windows\System32\wsl.exe';
      final (ptyProgram, ptyArgs) = TerminalViewState.ptyLaunchArgsForTest(
        program,
        const ['-d', 'Ubuntu', '--cd', '~'],
      );
      if (Platform.isWindows) {
        expect(ptyProgram, 'cmd.exe');
        expect(ptyArgs, ['/c', program, '-d', 'Ubuntu', '--cd', '~']);
      } else {
        expect(ptyProgram, program);
        expect(ptyArgs, const ['-d', 'Ubuntu', '--cd', '~']);
      }
      expect(ptyArgs, isNot(contains('-NoProfile')));
    });

    test('empty program falls back to flutter_alacritty default', () {
      final (ptyProgram, ptyArgs) =
          TerminalViewState.ptyLaunchArgsForTest('', const []);
      expect(ptyProgram, '');
      expect(ptyArgs, isEmpty);
    });

    test('args containing spaces are quoted (cmd /c parser survival)', () {
      // Guards the _quoteForCmd contract for a flag with a space, e.g. a
      // hypothetical -File "some path.ps1" arg.
      const program = r'C:\Program Files\PowerShell\7\pwsh.exe';
      final (ptyProgram, ptyArgs) = TerminalViewState.ptyLaunchArgsForTest(
        program,
        const ['-NoLogo', r'C:\Some Dir\script.ps1'],
      );
      if (Platform.isWindows) {
        // The executable path contains a space → _quoteForCmd wraps it.
        // The script path also contains a space → wrapped.
        expect(ptyArgs, [
          '/c',
          r'"C:\Program Files\PowerShell\7\pwsh.exe"',
          '-NoLogo',
          r'"C:\Some Dir\script.ps1"',
        ]);
      } else {
        // macOS / Linux: passthrough, no quoting at this layer (the
        // underlying fork/exec handles argv natively, no cmd.exe parser).
        expect(ptyProgram, program);
        expect(ptyArgs, const ['-NoLogo', r'C:\Some Dir\script.ps1']);
      }
      expect(ptyArgs, isNot(contains('-NoProfile')));
    });
  });

  group('regression: profile-suppression flags', () {
    // Belt-and-suspenders: even if someone renames the flag, scan every
    // token for the known profile-suppression switches across the shell
    // families that actually have profiles.
    const cases = <(String, List<String>)>[
      (r'C:\Program Files\PowerShell\7\pwsh.exe', ['-NoLogo']),
      (r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', ['-NoLogo']),
      (r'C:\Users\me\.cargo\bin\nu.exe', []),
    ];
    for (final (program, args) in cases) {
      test('$program never receives a profile-suppression flag', () {
        final (ptyProgram, ptyArgs) =
            TerminalViewState.ptyLaunchArgsForTest(program, args);
        // Scan every token including the program itself (Windows cmd.exe
        // wrapper case, where the program is the second token).
        final allTokens = [ptyProgram, ...ptyArgs];
        for (final token in allTokens) {
          if (token.isEmpty) continue;
          final lower = token.toLowerCase();
          expect(
            lower,
            isNot(anyOf(
              equals('-noprofile'),
              equals('--noprofile'),
              // pwsh also accepts a `-NoProfile` short form via the
              // generic flag parser; guard the literal too.
              contains('noprofile'),
            )),
            reason: 'token "$token" would suppress \$PROFILE (issue #1)',
          );
        }
      });
    }
  });
}
