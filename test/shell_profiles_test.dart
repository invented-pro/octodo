import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/shell_profiles.dart';

/// Build the UTF-16LE byte representation of [s], optionally prefixed with
/// the `FF FE` BOM that some `wsl.exe` builds emit before `--list` output.
List<int> _utf16le(String s, {bool bom = false}) {
  final out = <int>[];
  if (bom) {
    out.addAll(const [0xFF, 0xFE]);
  }
  for (final codeUnit in s.codeUnits) {
    out.add(codeUnit & 0xFF);
    out.add((codeUnit >> 8) & 0xFF);
  }
  return out;
}

/// A [PathProbe] that reports exactly [paths] as existing.
PathProbe _existsFor(Set<String> paths) =>
    (p) => paths.contains(p);

// Well-known paths detectShellsFrom probes — captured here so tests stay in
// sync with the implementation and don't hardcode the developer's machine.
const _pwshPath = r'C:\Program Files\PowerShell\7\pwsh.exe';
const _winPsPath = r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
const _cmdPath = r'C:\Windows\System32\cmd.exe';
const _wslPath = r'C:\Windows\System32\wsl.exe';
const _gitBashPath = r'C:\Program Files\Git\bin\bash.exe';
const _nuWingetPath = r'C:\Users\tester\AppData\Local\Programs\nu\bin\nu.exe';
const _nuCargoPath = r'C:\Users\tester\.cargo\bin\nu.exe';
const _nuScoopPath = r'C:\Users\tester\scoop\shims\nu.exe';
const _nuProgramFilesPath = r'C:\Program Files\nu\bin\nu.exe';
const _nuLegacyPath = r'C:\Program Files\Nushell\nu.exe';

// POSIX well-known paths that detectShellsPosixFrom probes — captured here
// for the same reason as the Windows constants above: keeping tests in sync
// with the implementation and decoupled from the developer's machine.
const _zshPath = '/bin/zsh';
const _bashPath = '/bin/bash';
const _fishArmHomebrew = '/opt/homebrew/bin/fish';
const _fishIntelHomebrew = '/usr/local/bin/fish';
const _fishUsrBin = '/usr/bin/fish';

const _baseEnv = <String, String>{
  'SystemRoot': r'C:\Windows',
  'USERPROFILE': r'C:\Users\tester', // test placeholder, never a real user
  'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
  'ProgramFiles': r'C:\Program Files',
  'PATH': '',
};

/// Minimal POSIX environment mirror of [_baseEnv]: no `$SHELL` by default
/// so tests that rely on "SHELL unset" don't have to strip it. Tests that
/// need a `$SHELL` override pass a fresh `const {...}` map inline (Dart
/// map literals can't be `const`-merged, so we keep this as the empty
/// baseline).
const _posixEnv = <String, String>{'PATH': ''};

void main() {
  group('decodeWslDistroList', () {
    test('UTF-16LE without BOM (current wsl --quiet output)', () {
      final bytes = _utf16le('Ubuntu\r\nDebian\r\n');
      expect(decodeWslDistroList(bytes), ['Ubuntu', 'Debian']);
    });

    test('UTF-16LE with BOM (older wsl --list output)', () {
      final bytes = _utf16le('Ubuntu\r\nDebian\r\n', bom: true);
      expect(decodeWslDistroList(bytes), ['Ubuntu', 'Debian']);
    });

    test('BOM does not shift a BOM-less body by two bytes', () {
      // Regression: an earlier version unconditionally stripped the first
      // two bytes, turning BOM-less "Debian" into "ebian".
      expect(decodeWslDistroList(_utf16le('Debian')), ['Debian']);
    });

    test('trailing "(Default)" tag is stripped', () {
      final bytes = _utf16le('Ubuntu (Default)\r\nDebian\r\n');
      expect(decodeWslDistroList(bytes), ['Ubuntu', 'Debian']);
    });

    test('blank lines and whitespace are dropped', () {
      final bytes = _utf16le('\r\n  Ubuntu  \r\n\r\n\r\nDebian\r\n');
      expect(decodeWslDistroList(bytes), ['Ubuntu', 'Debian']);
    });

    test('empty input → empty list', () {
      expect(decodeWslDistroList([]), isEmpty);
    });
  });

  group('detectShellsFrom', () {
    test(
      'full host: pwsh → powershell → cmd → each distro → bash → nu, in order',
      () {
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {
            _pwshPath,
            _winPsPath,
            _cmdPath,
            _wslPath,
            _gitBashPath,
            _nuWingetPath,
          }),
          environment: _baseEnv,
          listWslDistros: (_) => const ['Ubuntu', 'Debian'],
        );

        // Family order must hold; distro shortNames are lowercased distro names.
        expect(profiles.map((p) => p.shortName).toList(), [
          'pwsh',
          'powershell',
          'cmd',
          'ubuntu',
          'debian',
          'bash',
          'nu',
        ]);
        // Programs/args wired correctly per family.
        expect(
          profiles.firstWhere((p) => p.shortName == 'pwsh').program,
          _pwshPath,
        );
        expect(profiles.firstWhere((p) => p.shortName == 'pwsh').args, [
          '-NoLogo',
        ]);
        expect(profiles.firstWhere((p) => p.shortName == 'cmd').args, isEmpty);
        final bash = profiles.firstWhere((p) => p.shortName == 'bash');
        expect(bash.program, _gitBashPath);
        expect(bash.args, ['--login', '-i']);
        final nu = profiles.firstWhere((p) => p.shortName == 'nu');
        expect(nu.program, _nuWingetPath);
        // Nushell has no `-NoLogo` analog; we deliberately launch with
        // no args so the user's `config.nu` and history files drive
        // the session. (Earlier drafts passed `--no-logo`, which Nu
        // rejects with "Unknown flag '--no-logo'" and exits 1.)
        expect(nu.args, isEmpty);

        // iconAsset wiring: PowerShell 7 gets the badged variant while
        // Windows PowerShell 5 keeps the plain shield; CMD keeps the
        // Material fallback (no asset); Git Bash gets the Git branch-mark;
        // each WSL distro gets its own per-distro SVG; Nushell gets its
        // dedicated SVG.
        expect(
          profiles.firstWhere((p) => p.shortName == 'pwsh').iconAsset,
          'assets/icons/powershell-7.svg',
        );
        expect(
          profiles.firstWhere((p) => p.shortName == 'powershell').iconAsset,
          'assets/icons/powershell.svg',
        );
        expect(
          profiles.firstWhere((p) => p.shortName == 'cmd').iconAsset,
          isNull,
        );
        expect(bash.iconAsset, 'assets/icons/git-bash.svg');
        expect(
          profiles.firstWhere((p) => p.shortName == 'ubuntu').iconAsset,
          'assets/icons/ubuntu.svg',
        );
        expect(
          profiles.firstWhere((p) => p.shortName == 'debian').iconAsset,
          'assets/icons/debian.svg',
        );
        expect(nu.iconAsset, 'assets/icons/nushell.svg');
        // showCwdInTitle is false: the chip title comes from Nushell's
        // OSC 2 (window title), not OSC 7. Cwd persistence is handled
        // via [remembersCwd] + OSC 2 title parsing.
        expect(nu.showCwdInTitle, isFalse);
      },
    );

    test(
      'every WSL distro becomes its own profile with -d <distro> --cd ~',
      () {
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {_wslPath}),
          environment: _baseEnv,
          listWslDistros: (_) => const ['Ubuntu', 'Fedora'],
        );
        final wsl = profiles.where((p) => p.isWsl).toList();
        expect(wsl.length, 2);

        final byDistro = {for (final p in wsl) p.wslDistro: p};
        expect(byDistro.keys.toSet(), {'Ubuntu', 'Fedora'});
        for (final entry in byDistro.entries) {
          expect(entry.value.isWsl, isTrue);
          expect(entry.value.program, _wslPath);
          // `--cd ~` is what makes bash land in $HOME regardless of the
          // parent process's Windows cwd (see `_queryWslHome` for the matching
          // initialCwd query that keeps the tab chip's `~` shortcut in sync).
          expect(entry.value.args, ['-d', entry.key, '--cd', '~']);
          expect(entry.value.showCwdInTitle, isTrue);
        }
        // Distinct distros get distinct shortNames (so the tab chip differs).
        expect(wsl.map((p) => p.shortName).toSet().length, wsl.length);
      },
    );

    test('shortNames stay unique across distros and the static shells', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {
          _pwshPath,
          _winPsPath,
          _cmdPath,
          _wslPath,
          _gitBashPath,
          _nuWingetPath,
        }),
        environment: _baseEnv,
        listWslDistros: (_) => const ['Ubuntu', 'Debian'],
      );
      final names = profiles.map((p) => p.shortName).toList();
      expect(
        names.toSet().length,
        names.length,
        reason: 'Duplicate shortNames would collide in the tab chip',
      );
    });

    test(
      'wsl.exe present but no distro registered → no WSL profiles (no dead entry)',
      () {
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {_wslPath, _cmdPath}),
          environment: _baseEnv,
          listWslDistros: (_) => const [],
        );
        expect(profiles.where((p) => p.isWsl), isEmpty);
      },
    );

    test('wsl.exe absent → listWslDistros is never consulted', () {
      var listerCalled = false;
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath}),
        environment: _baseEnv,
        listWslDistros: (_) {
          listerCalled = true;
          return const ['Ubuntu'];
        },
      );
      expect(profiles.where((p) => p.isWsl), isEmpty);
      expect(
        listerCalled,
        isFalse,
        reason: 'wsl.exe missing must short-circuit before listing distros',
      );
    });

    test('CMD / Windows PowerShell are gated on their executables', () {
      // Simulates Server Core / a debloated image where both are absent:
      // neither family may appear, yet the function still returns cleanly.
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_pwshPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      final names = profiles.map((p) => p.shortName).toSet();
      expect(names.contains('cmd'), isFalse);
      expect(names.contains('powershell'), isFalse);
      expect(names.contains('pwsh'), isTrue);
    });

    test('pwsh is found via PATH when no well-known path exists', () {
      const onPath = r'C:\Tools\bin';
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {r'C:\Tools\bin\pwsh.exe', _cmdPath}),
        environment: const {
          'SystemRoot': r'C:\Windows',
          'USERPROFILE': r'C:\Users\tester',
          'PATH': onPath,
        },
        listWslDistros: (_) => const [],
      );
      final pwsh = profiles.where((p) => p.shortName == 'pwsh').single;
      expect(pwsh.program, r'C:\Tools\bin\pwsh.exe');
    });

    test(
      'PowerShell 7 via Microsoft Store App Execution Alias is detected',
      () {
        // The Store install drops a reparse-point alias at
        // `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`. On the host,
        // `File.existsSync()` returns false for it; the production probe
        // `_hostPathExists` ORs in `Link.existsSync()` so it's seen. At the
        // `detectShellsFrom` level the probe is injected, so this test pins
        // the path-list contract: the WindowsApps alias path is enumerated
        // explicitly (not just via PATH), and when it's the only pwsh
        // candidate that exists, a pwsh profile is emitted from it.
        const storeAlias =
            r'C:\Users\tester\AppData\Local\Microsoft\WindowsApps\pwsh.exe';
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {storeAlias, _winPsPath, _cmdPath}),
          environment: const {
            'SystemRoot': r'C:\Windows',
            'USERPROFILE': r'C:\Users\tester',
            'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
            'ProgramFiles': r'C:\Program Files',
            // No PATH entry — proves the alias is caught by the explicit
            // WindowsApps path in the enumerate list, not by PATH lookup.
            'PATH': '',
          },
          listWslDistros: (_) => const [],
        );
        final pwsh = profiles.where((p) => p.shortName == 'pwsh').single;
        expect(pwsh.program, storeAlias);
        expect(pwsh.label, 'PowerShell 7');
      },
    );

    test(
      'PowerShell 7 via per-user MSI is detected when per-machine is absent',
      () {
        // winget --scope user / per-user MSI lands at
        // `%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe`. When no
        // per-machine path exists, the per-user entry must surface pwsh.
        const perUserMsi =
            r'C:\Users\tester\AppData\Local\Microsoft\PowerShell\7\pwsh.exe';
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {perUserMsi, _cmdPath}),
          environment: const {
            'SystemRoot': r'C:\Windows',
            'USERPROFILE': r'C:\Users\tester',
            'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
            'ProgramFiles': r'C:\Program Files',
            'PATH': '',
          },
          listWslDistros: (_) => const [],
        );
        final pwsh = profiles.where((p) => p.shortName == 'pwsh').single;
        expect(pwsh.program, perUserMsi);
      },
    );

    test(
      'per-machine pwsh wins over per-user when both exist (no duplicates)',
      () {
        // First-match-wins: the Program Files entry is enumerated ahead of
        // the per-user entry, so when both resolve only one profile is
        // emitted and it points at the per-machine binary.
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {
            _pwshPath,
            r'C:\Users\tester\AppData\Local\Microsoft\PowerShell\7\pwsh.exe',
            _cmdPath,
          }),
          environment: _baseEnv,
          listWslDistros: (_) => const [],
        );
        final pwshs = profiles.where((p) => p.shortName == 'pwsh').toList();
        expect(pwshs.length, 1);
        expect(pwshs.single.program, _pwshPath);
      },
    );

    test(
      'Windows PowerShell entry is labelled "PowerShell 5" for parity with PS7',
      () {
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {_winPsPath, _cmdPath}),
          environment: _baseEnv,
          listWslDistros: (_) => const [],
        );
        final ps5 = profiles.where((p) => p.shortName == 'powershell').single;
        expect(ps5.label, 'PowerShell 5');
        expect(ps5.program, _winPsPath);
      },
    );

    test('pwsh absent everywhere → no pwsh profile', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      expect(profiles.where((p) => p.shortName == 'pwsh'), isEmpty);
    });

    test(
      'Git Bash is NOT picked up from a bare bash.exe on PATH (WSL launcher guard)',
      () {
        // The historical bug: `_findOnPath('bash.exe')` resolved to
        // C:\Windows\System32\bash.exe (the WSL launcher) on every WSL box.
        // That PATH fallback is gone; only the Git/Scoop well-known paths count.
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {
            _cmdPath,
            r'C:\Windows\System32\bash.exe', // present, but NOT Git Bash
          }),
          environment: const {
            'SystemRoot': r'C:\Windows',
            'USERPROFILE': r'C:\Users\tester',
            'PATH': r'C:\Windows\System32', // would have matched the old lookup
          },
          listWslDistros: (_) => const [],
        );
        expect(profiles.where((p) => p.shortName == 'bash'), isEmpty);
      },
    );

    test('Git for Windows at the well-known path is detected', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath, _gitBashPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      final bash = profiles.where((p) => p.shortName == 'bash').single;
      expect(bash.program, _gitBashPath);
    });

    test(
      'Nushell via winget per-user Programs layout (the modern install)',
      () {
        // `winget install Nushell.Nushell` drops nu.exe at
        // %LOCALAPPDATA%\Programs\nu\bin\nu.exe on a per-user install.
        // No PATH entry is created, so this is the only probe that
        // must succeed for the dropdown to surface Nushell on a
        // freshly-installed box.
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {_cmdPath, _nuWingetPath}),
          environment: _baseEnv,
          listWslDistros: (_) => const [],
        );
        final nu = profiles.where((p) => p.shortName == 'nu').single;
        expect(nu.program, _nuWingetPath);
        expect(nu.label, 'Nushell');
        // Nushell has no `-NoLogo` analog; we deliberately launch with
        // no args so the user's `config.nu` and history files drive
        // the session. (Earlier drafts passed `--no-logo`, which Nu
        // rejects with "Unknown flag '--no-logo'" and exits 1.)
        expect(nu.args, isEmpty);
      },
    );

    test(
      'Nushell args must never include --no-logo (regression for early-exit bug)',
      () {
        // `nu --no-logo` errors out with "Unknown flag '--no-logo'"
        // and exits with code 1, which makes the spawned shell
        // immediately die in the PTY (16 bytes of error output, then
        // exit). Pin the contract here: a Nushell launch from octodo
        // MUST NOT add `--no-logo` (or any other unknown flag) to the
        // args.
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {_cmdPath, _nuWingetPath}),
          environment: _baseEnv,
          listWslDistros: (_) => const [],
        );
        final nu = profiles.where((p) => p.shortName == 'nu').single;
        expect(
          nu.args,
          isNot(contains('--no-logo')),
          reason:
              "nu rejects --no-logo as an unknown flag; the profile must "
              "launch bare so the user's config.nu drives startup.",
        );
        expect(
          nu.args,
          isNot(contains('-NoLogo')),
          reason:
              "Nushell uses single-dash long options; do not borrow the "
              "PowerShell-style -NoLogo flag.",
        );
      },
    );

    test('Nushell via cargo install is detected at .cargo\\bin', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath, _nuCargoPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      final nu = profiles.where((p) => p.shortName == 'nu').single;
      expect(nu.program, _nuCargoPath);
    });

    test('Nushell via scoop shim is detected at scoop\\shims', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath, _nuScoopPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      final nu = profiles.where((p) => p.shortName == 'nu').single;
      expect(nu.program, _nuScoopPath);
    });

    test('Nushell via per-machine Programs\\nu\\bin layout is detected', () {
      // Older winget manifests and the MSI installer put nu.exe
      // directly under Program Files in `nu\bin\nu.exe`.
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath, _nuProgramFilesPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      final nu = profiles.where((p) => p.shortName == 'nu').single;
      expect(nu.program, _nuProgramFilesPath);
    });

    test(
      'Nushell via legacy Nu MSI layout is detected at Program Files\\Nushell',
      () {
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {_cmdPath, _nuLegacyPath}),
          environment: _baseEnv,
          listWslDistros: (_) => const [],
        );
        final nu = profiles.where((p) => p.shortName == 'nu').single;
        expect(nu.program, _nuLegacyPath);
      },
    );

    test('Nushell on PATH is detected when no well-known path matches', () {
      // Mimic a portable copy dropped into C:\Tools\nu\bin\nu.exe
      // (a directory present on PATH, but not in our enumerate list).
      const onPathDir = r'C:\Tools\nu\bin';
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath, r'C:\Tools\nu\bin\nu.exe'}),
        environment: const {
          'SystemRoot': r'C:\Windows',
          'USERPROFILE': r'C:\Users\tester',
          'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
          'ProgramFiles': r'C:\Program Files',
          'PATH': onPathDir,
        },
        listWslDistros: (_) => const [],
      );
      final nu = profiles.where((p) => p.shortName == 'nu').single;
      expect(nu.program, r'C:\Tools\nu\bin\nu.exe');
    });

    test(
      'preferring the winget path avoids double-detecting nu.exe on PATH',
      () {
        // Both well-known and PATH candidates resolve; only one
        // profile must be emitted.
        final profiles = detectShellsFrom(
          fileExists: _existsFor(const {
            _cmdPath,
            _nuWingetPath,
            r'C:\Tools\nu\bin\nu.exe',
          }),
          environment: const {
            'SystemRoot': r'C:\Windows',
            'USERPROFILE': r'C:\Users\tester',
            'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
            'ProgramFiles': r'C:\Program Files',
            'PATH': r'C:\Tools\nu\bin',
          },
          listWslDistros: (_) => const [],
        );
        expect(profiles.where((p) => p.shortName == 'nu').length, 1);
        expect(
          profiles.firstWhere((p) => p.shortName == 'nu').program,
          _nuWingetPath,
        );
      },
    );

    test('no Nushell profile when nu.exe is absent everywhere', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      expect(profiles.where((p) => p.shortName == 'nu'), isEmpty);
    });

    test('respects SystemRoot from the environment', () {
      // If SystemRoot is relocated, the System32-derived paths must follow it.
      const customRoot = r'D:\Win';
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {r'D:\Win\System32\cmd.exe'}),
        environment: const {
          'SystemRoot': customRoot,
          'USERPROFILE': r'C:\Users\tester',
          'PATH': '',
        },
        listWslDistros: (_) => const [],
      );
      expect(profiles.single.program, r'D:\Win\System32\cmd.exe');
    });
  });

  group('detectShellsPosixFrom', () {
    test(
      'macOS: \$SHELL=/bin/zsh + /bin/zsh exists → zsh (from \$SHELL), then /bin/bash, deduped',
      () {
        // The canonical macOS case: $SHELL is /bin/zsh (the system default
        // since Catalina), and both /bin/zsh and /bin/bash exist. The
        // $SHELL-derived zsh must come first, the static /bin/zsh probe
        // must NOT double it, and /bin/bash follows.
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {_zshPath, _bashPath}),
          environment: const {'SHELL': _zshPath},
          isMacOSHost: true,
        );
        expect(profiles.map((p) => p.shortName).toList(), ['zsh', 'bash']);
        // Dedup: only one zsh entry despite $SHELL and the static probe
        // both pointing at /bin/zsh.
        expect(profiles.where((p) => p.shortName == 'zsh').length, 1);
        expect(profiles.first.program, _zshPath);
        // POSIX profiles launch as interactive login shells (-l -i) so the
        // user's dotfiles AND prompt helpers actually run. The `-l` flag
        // sources .zprofile/.zshrc/.bash_profile/.profile; the `-i` flag
        // forces .bashrc sourcing (the standard
        // `[ -f ~/.bashrc ] && . ~/.bashrc` chain in .bash_profile only
        // fires when bash is interactive) AND makes PROMPT_COMMAND actually
        // execute (PROMPT_COMMAND is ignored in non-interactive shells —
        // that's how -i triggers starship / _cmux_prompt_command / mise
        // hooks). Mirrors Git Bash on Windows (`['--login', '-i']`).
        expect(profiles.first.args, const ['-l', '-i']);
        // macOS/Linux zsh/bash emit OSC 7 reliably — no ConPTY mangling.
        expect(profiles.first.showCwdInTitle, isTrue);
        // No shell-specific Material glyph or SVG asset for zsh/bash.
        expect(profiles.first.iconAsset, isNull);
        expect(profiles.first.wslDistro, isNull);
      },
    );

    test('macOS: \$SHELL unset, only /bin/zsh exists → just /bin/zsh', () {
      // Simulates a host where $SHELL is not exported (rare but possible
      // when launched from a non-login parent). With only /bin/zsh on
      // disk, the dropdown surfaces exactly one entry.
      final profiles = detectShellsPosixFrom(
        fileExists: _existsFor(const {_zshPath}),
        environment: _posixEnv,
        isMacOSHost: true,
      );
      expect(profiles.map((p) => p.shortName).toList(), ['zsh']);
      expect(profiles.single.program, _zshPath);
    });

    test(
      'macOS: \$SHELL=/bin/bash + /bin/zsh also exists → bash (from \$SHELL) first, then zsh',
      () {
        // $SHELL takes priority over the static probe order, so a user who
        // `chsh`'d to bash sees bash first even though /bin/zsh is probed
        // before /bin/bash in the static list.
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {_zshPath, _bashPath}),
          environment: const {'SHELL': _bashPath},
          isMacOSHost: true,
        );
        expect(profiles.map((p) => p.shortName).toList(), ['bash', 'zsh']);
        expect(profiles.first.program, _bashPath);
      },
    );

    test('Linux: \$SHELL=/bin/bash, isMacOSHost=false → bash first', () {
      // The Linux contract: isMacOSHost=false must not change the probe
      // set (both /bin/zsh and /bin/bash are probed on Linux too), but
      // $SHELL still wins. Pinning isMacOSHost=false here guards against
      // a future regression that accidentally gates probes on the flag.
      final profiles = detectShellsPosixFrom(
        fileExists: _existsFor(const {_bashPath}),
        environment: const {'SHELL': _bashPath},
        isMacOSHost: false,
      );
      expect(profiles.first.shortName, 'bash');
      expect(profiles.first.program, _bashPath);
    });

    test(
      'fish at /opt/homebrew/bin/fish is detected (Apple Silicon Homebrew)',
      () {
        // The first fish probe path (Apple Silicon Homebrew prefix) must
        // surface a fish profile when present, alongside the zsh/bash
        // entries. Only one fish entry — the three fish paths are deduped
        // by shortName in the dropdown (and by resolved path when they
        // coincide).
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {_zshPath, _bashPath, _fishArmHomebrew}),
          environment: const {'SHELL': _zshPath},
          isMacOSHost: true,
        );
        final fish = profiles.where((p) => p.shortName == 'fish').single;
        expect(fish.program, _fishArmHomebrew);
        expect(fish.showCwdInTitle, isTrue);
      },
    );

    test(
      'fish at /usr/local/bin/fish is detected (Intel Homebrew / Linux manual)',
      () {
        // Second fish probe path — Intel Homebrew on macOS and the common
        // manual-install prefix on Linux.
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {_bashPath, _fishIntelHomebrew}),
          environment: const {'SHELL': _bashPath},
          isMacOSHost: false,
        );
        final fish = profiles.where((p) => p.shortName == 'fish').single;
        expect(fish.program, _fishIntelHomebrew);
      },
    );

    test('fish at /usr/bin/fish is detected (system package manager)', () {
      // Third fish probe path — apt/dnf system install.
      final profiles = detectShellsPosixFrom(
        fileExists: _existsFor(const {_bashPath, _fishUsrBin}),
        environment: const {'SHELL': _bashPath},
        isMacOSHost: false,
      );
      final fish = profiles.where((p) => p.shortName == 'fish').single;
      expect(fish.program, _fishUsrBin);
    });

    test('all shells missing → empty list (no crash)', () {
      // Nothing on disk and $SHELL pointing at a non-existent path: the
      // function must return an empty list, not throw. The workspace's
      // _defaultShell guard synthesizes a fallback profile from this.
      final profiles = detectShellsPosixFrom(
        fileExists: _existsFor(const {}),
        environment: const {'SHELL': _zshPath},
        isMacOSHost: true,
      );
      expect(profiles, isEmpty);
    });

    test(
      'resolveExecutable PATH fallback surfaces fish when no explicit path matches',
      () {
        // A fish binary at a non-standard location (e.g. ~/.local/bin/fish)
        // is only reachable via the optional resolveExecutable seam. When
        // the caller injects a resolver, the function must consult it as a
        // last resort after the three explicit fish paths miss.
        const customFish = '/home/tester/.local/bin/fish';
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {_zshPath, _bashPath, customFish}),
          environment: const {'SHELL': _zshPath},
          isMacOSHost: true,
          resolveExecutable: (name) => name == 'fish' ? customFish : '',
        );
        final fish = profiles.where((p) => p.shortName == 'fish').single;
        expect(fish.program, customFish);
      },
    );

    test('shortNames are derived as basename without extension', () {
      // Pin the shortName derivation contract: p.basename(programPath)
      // with a trailing .exe stripped (defensive — POSIX paths never
      // carry .exe, but the helper is symmetric with the Windows side).
      final profiles = detectShellsPosixFrom(
        fileExists: _existsFor(const {_zshPath, _bashPath}),
        environment: const {'SHELL': _zshPath},
        isMacOSHost: true,
      );
      expect(profiles.map((p) => p.shortName).toList(), ['zsh', 'bash']);
      // Labels are title-cased basenames.
      expect(profiles.map((p) => p.label).toList(), ['Zsh', 'Bash']);
    });

    test(
      'basename dedup: \$SHELL=/opt/homebrew/bin/bash + /bin/bash exists → one bash',
      () {
        // The user has both Homebrew bash (5.x) at /opt/homebrew/bin/bash
        // AND Apple's bash (3.2) at /bin/bash. Both are real binaries (not
        // symlinks). With $SHELL pointing at the Homebrew one, only it
        // should appear in the dropdown — the static /bin/bash probe must
        // be suppressed because it shares the basename "bash".
        const homebrewBash = '/opt/homebrew/bin/bash';
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {homebrewBash, _bashPath}),
          environment: const {'SHELL': homebrewBash},
          isMacOSHost: true,
        );
        expect(
          profiles.where((p) => p.shortName == 'bash').length,
          1,
          reason:
              'Homebrew bash and Apple bash share a basename — '
              'only one entry should appear in the dropdown.',
        );
        expect(
          profiles.singleWhere((p) => p.shortName == 'bash').program,
          homebrewBash,
          reason:
              r'The $SHELL-derived Homebrew bash wins over the static '
              r'/bin/bash probe because $SHELL is processed first.',
        );
      },
    );

    test(
      'basename dedup: \$SHELL=/opt/homebrew/bin/zsh + /bin/zsh exists → one zsh',
      () {
        // Same contract for zsh: if the user switched to a Homebrew zsh,
        // the system /bin/zsh probe is suppressed so the dropdown doesn't
        // show both.
        const homebrewZsh = '/opt/homebrew/bin/zsh';
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {homebrewZsh, _zshPath}),
          environment: const {'SHELL': homebrewZsh},
          isMacOSHost: true,
        );
        expect(profiles.where((p) => p.shortName == 'zsh').length, 1);
        expect(
          profiles.singleWhere((p) => p.shortName == 'zsh').program,
          homebrewZsh,
        );
      },
    );

    test(
      'basename dedup: \$SHELL unset, only Homebrew bash exists (no /bin/bash) → still emits it',
      () {
        // Without $SHELL the first static probe wins. On a stripped macOS
        // (no /bin/bash, only Homebrew bash) the Homebrew path is the only
        // one we know to probe — and we don't probe /opt/homebrew/bin/bash
        // explicitly. This case verifies the function doesn't get stuck
        // trying to dedup against a probe it never made.
        const homebrewBash = '/opt/homebrew/bin/bash';
        final profiles = detectShellsPosixFrom(
          fileExists: _existsFor(const {homebrewBash}),
          environment: _posixEnv, // no SHELL key
          isMacOSHost: true,
        );
        expect(
          profiles,
          isEmpty,
          reason:
              r'Without $SHELL and with no /bin/bash to probe, '
              r'detectShellsPosixFrom never sees the Homebrew path.',
        );
      },
    );

    test('all POSIX profiles use -l -i (interactive login shell)', () {
      // Regression guard: every POSIX profile MUST launch with both
      // flags. `-l` alone makes bash a login shell that sources
      // .bash_profile but NOT .bashrc (the standard `[ -f ~/.bashrc ] &&
      // . ~/.bashrc` chain in .bash_profile only fires when bash is
      // interactive); `-i` alone makes bash interactive but doesn't
      // source .bash_profile (so PATH tweaks from .zprofile / .bash_profile
      // are missed). The `-i` flag is also what makes PROMPT_COMMAND
      // actually execute — without it, the user's
      // `PROMPT_COMMAND='_mise_hook_prompt_command;_cmux_prompt_command;
      // starship_precmd;__ghostty_hook'` is a silent no-op and the
      // bootstrap function never gets defined.
      //
      // Mirrors Git Bash on Windows: `['--login', '-i']` (line 508 of
      // shell_profiles.dart). The POSIX flag spelling is `['-l', '-i']`.
      for (final profile in detectShellsPosixFrom(
        fileExists: _existsFor(const {
          _zshPath,
          _bashPath,
          _fishArmHomebrew,
          _fishUsrBin,
        }),
        environment: const {'SHELL': _zshPath},
        isMacOSHost: true,
      )) {
        expect(
          profile.args,
          const ['-l', '-i'],
          reason:
              '${profile.shortName} did not launch as an interactive '
              'login shell — PROMPT_COMMAND helpers (starship, '
              '_cmux_prompt_command, mise) will silently no-op.',
        );
      }
    });
  });

  group('resolveWslIconAsset', () {
    test('maps known distros to their SVG asset', () {
      expect(resolveWslIconAsset('Ubuntu'), 'assets/icons/ubuntu.svg');
      expect(resolveWslIconAsset('Debian'), 'assets/icons/debian.svg');
      expect(resolveWslIconAsset('Fedora Linux'), 'assets/icons/fedora.svg');
      expect(resolveWslIconAsset('Arch'), 'assets/icons/arch.svg');
      expect(
        resolveWslIconAsset('openSUSE Leap-15.5'),
        'assets/icons/opensuse.svg',
      );
      expect(resolveWslIconAsset('kali-linux'), 'assets/icons/kali.svg');
      expect(resolveWslIconAsset('Alpine'), 'assets/icons/alpine.svg');
      expect(resolveWslIconAsset('CentOS Stream'), 'assets/icons/centos.svg');
      expect(resolveWslIconAsset('OracleLinux'), 'assets/icons/oracle.svg');
      expect(resolveWslIconAsset('NixOS'), 'assets/icons/nixos.svg');
    });

    test('matches case-insensitively against the leading token', () {
      expect(resolveWslIconAsset('ubuntu-22.04'), 'assets/icons/ubuntu.svg');
      expect(resolveWslIconAsset('KALI-LINUX'), 'assets/icons/kali.svg');
      expect(
        resolveWslIconAsset('OPENSUSE-Tumbleweed'),
        'assets/icons/opensuse.svg',
      );
    });

    test('matches version-suffixed distros by their leading token', () {
      // Regression for the Debian-11/12/13 case: `wsl --list` reports
      // version-suffixed names for user-imported distros, and we
      // resolve them by the leading token so a single icon serves all
      // major versions. Critical: 'Debian' must win ahead of any
      // generic fallback path.
      expect(resolveWslIconAsset('Debian-11'), 'assets/icons/debian.svg');
      expect(resolveWslIconAsset('Debian-12'), 'assets/icons/debian.svg');
      expect(
        resolveWslIconAsset('Debian GNU/Linux'),
        'assets/icons/debian.svg',
      );
      expect(resolveWslIconAsset('Ubuntu-22.04'), 'assets/icons/ubuntu.svg');
      expect(resolveWslIconAsset('Arch-2024.05.01'), 'assets/icons/arch.svg');
      expect(resolveWslIconAsset('Alpine-3.20'), 'assets/icons/alpine.svg');
    });

    test('falls back to the WSL fallback asset for unknown distros', () {
      expect(resolveWslIconAsset('PenguinOS'), 'assets/icons/wsl-fallback.svg');
      expect(resolveWslIconAsset(''), 'assets/icons/wsl-fallback.svg');
      expect(resolveWslIconAsset('  '), 'assets/icons/wsl-fallback.svg');
    });

    test('aliases related distros to the closest shipped icon', () {
      // Rocky / Alma / RHEL don't have their own icons — fall back to
      // CentOS, which is visually closest.
      expect(resolveWslIconAsset('Rocky Linux'), 'assets/icons/centos.svg');
      expect(resolveWslIconAsset('AlmaLinux-9'), 'assets/icons/centos.svg');
      expect(resolveWslIconAsset('RHEL-9'), 'assets/icons/centos.svg');
      // SUSE Linux Enterprise shares the openSUSE chameleon.
      expect(resolveWslIconAsset('SLES-15'), 'assets/icons/opensuse.svg');
    });
  });

  group('needsPromptCommandForOsc7', () {
    test('wsl.exe → true', () {
      final p = ShellProfile(
        label: 'Ubuntu',
        program: _wslPath,
        args: const ['-d', 'Ubuntu', '--cd', '~'],
        icon: Icons.laptop_chromebook,
        color: Colors.green,
        shortName: 'ubuntu',
        showCwdInTitle: true,
      );
      expect(p.needsPromptCommandForOsc7, isTrue);
    });

    test('bash.exe → true', () {
      final p = ShellProfile(
        label: 'Git Bash',
        program: _gitBashPath,
        args: const ['--login', '-i'],
        icon: Icons.call_split,
        color: Colors.orange,
        shortName: 'bash',
        showCwdInTitle: true,
      );
      expect(p.needsPromptCommandForOsc7, isTrue);
    });

    test('nu.exe → false (Nushell does not use PROMPT_COMMAND)', () {
      final p = ShellProfile(
        label: 'Nushell',
        program: _nuWingetPath,
        args: const [],
        icon: Icons.terminal,
        color: Colors.teal,
        shortName: 'nu',
        showCwdInTitle: true,
      );
      expect(p.needsPromptCommandForOsc7, isFalse);
    });

    test('pwsh.exe → false', () {
      final p = ShellProfile(
        label: 'PowerShell 7',
        program: _pwshPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'pwsh',
      );
      expect(p.needsPromptCommandForOsc7, isFalse);
    });

    test(
      '/bin/bash (POSIX) → true (stock macOS/Linux bash emits no OSC 7)',
      () {
        // POSIX bash has no vte.sh-style default on macOS (or Debian), so
        // the env-var PROMPT_COMMAND injection is what activates the cwd
        // channel there at all.
        final p = ShellProfile(
          label: 'Bash',
          program: _bashPath,
          args: const ['-l', '-i'],
          icon: Icons.terminal,
          color: Colors.grey,
          shortName: 'bash',
          showCwdInTitle: true,
        );
        expect(p.needsPromptCommandForOsc7, isTrue);
      },
    );

    test('/bin/zsh (POSIX) → false (zsh reads no PROMPT_COMMAND)', () {
      // zsh gets its OSC 7 injection via the ZDOTDIR .zshenv shim in
      // TerminalWorkspace, not via PROMPT_COMMAND.
      final p = ShellProfile(
        label: 'Zsh',
        program: _zshPath,
        args: const ['-l', '-i'],
        icon: Icons.terminal,
        color: Colors.grey,
        shortName: 'zsh',
        showCwdInTitle: true,
      );
      expect(p.needsPromptCommandForOsc7, isFalse);
    });

    test('fish (POSIX) → false (fish reads no PROMPT_COMMAND)', () {
      // fish gets its OSC 7 injection via --init-command in
      // TerminalWorkspace, not via PROMPT_COMMAND.
      final p = ShellProfile(
        label: 'Fish',
        program: _fishUsrBin,
        args: const ['-l', '-i'],
        icon: Icons.terminal,
        color: Colors.grey,
        shortName: 'fish',
        showCwdInTitle: true,
      );
      expect(p.needsPromptCommandForOsc7, isFalse);
    });
  });

  group('isPosixZsh / isPosixFish', () {
    ShellProfile profileFor(String program) => ShellProfile(
      label: 'shell',
      program: program,
      args: const ['-l', '-i'],
      icon: Icons.terminal,
      color: Colors.grey,
      shortName: 'shell',
    );

    test('/bin/zsh → isPosixZsh, not isPosixFish', () {
      final p = profileFor(_zshPath);
      expect(p.isPosixZsh, isTrue);
      expect(p.isPosixFish, isFalse);
    });

    test('/opt/homebrew/bin/fish → isPosixFish, not isPosixZsh', () {
      final p = profileFor(_fishArmHomebrew);
      expect(p.isPosixFish, isTrue);
      expect(p.isPosixZsh, isFalse);
    });

    test('/bin/bash → neither', () {
      final p = profileFor(_bashPath);
      expect(p.isPosixZsh, isFalse);
      expect(p.isPosixFish, isFalse);
    });

    test('Windows-style zsh.exe / fish.exe (hypothetical) → neither', () {
      // Basenames with .exe are Windows programs; the POSIX injections
      // (ZDOTDIR shim / --init-command) must never fire for them.
      expect(profileFor(r'C:\Tools\zsh.exe').isPosixZsh, isFalse);
      expect(profileFor(r'C:\Tools\fish.exe').isPosixFish, isFalse);
    });
  });

  group('basename checks are host-independent (backslash-aware)', () {
    // Regression: these getters used p.basename, which picks its
    // separator style from the HOST — on macOS/Linux CI the backslash
    // paths below resolved as single giant filenames and every check
    // failed. The helpers must split on BOTH separators regardless of
    // host.
    ShellProfile profileFor(String program) => ShellProfile(
      label: 'shell',
      program: program,
      args: const [],
      icon: Icons.terminal,
      color: Colors.grey,
      shortName: 'shell',
    );

    test('isWsl with a Windows path → true on every host', () {
      expect(profileFor(_wslPath).isWsl, isTrue);
    });

    test('isPowerShell with Windows paths → true on every host', () {
      expect(profileFor(_pwshPath).isPowerShell, isTrue);
      expect(profileFor(_winPsPath).isPowerShell, isTrue);
    });

    test('isNushell with a Windows path → true on every host', () {
      expect(profileFor(_nuWingetPath).isNushell, isTrue);
    });

    test(
      'forward-slash basenames still match (WSL through MSYS-style path)',
      () {
        expect(profileFor('C:/Windows/System32/wsl.exe').isWsl, isTrue);
      },
    );

    test('empty program (fallback profile) matches nothing', () {
      final p = profileFor('');
      expect(p.isWsl, isFalse);
      expect(p.isPowerShell, isFalse);
      expect(p.isNushell, isFalse);
      expect(p.isPosixZsh, isFalse);
      expect(p.isPosixFish, isFalse);
      expect(p.needsPromptCommandForOsc7, isFalse);
    });
  });

  group('remembersCwd', () {
    test('wsl.exe → true (showCwdInTitle)', () {
      final p = ShellProfile(
        label: 'Ubuntu',
        program: _wslPath,
        args: const ['-d', 'Ubuntu', '--cd', '~'],
        icon: Icons.laptop_chromebook,
        color: Colors.green,
        shortName: 'ubuntu',
        showCwdInTitle: true,
      );
      expect(p.remembersCwd, isTrue);
    });

    test('bash.exe → true (showCwdInTitle)', () {
      final p = ShellProfile(
        label: 'Git Bash',
        program: _gitBashPath,
        args: const ['--login', '-i'],
        icon: Icons.call_split,
        color: Colors.orange,
        shortName: 'bash',
        showCwdInTitle: true,
      );
      expect(p.remembersCwd, isTrue);
    });

    test('nu.exe → true (isNushell, even though showCwdInTitle is false)', () {
      final p = ShellProfile(
        label: 'Nushell',
        program: _nuWingetPath,
        args: const [],
        icon: Icons.terminal,
        color: Colors.teal,
        shortName: 'nu',
        showCwdInTitle: false,
      );
      expect(p.remembersCwd, isTrue);
    });

    test('pwsh.exe → false (default showCwdInTitle: false)', () {
      final p = ShellProfile(
        label: 'PowerShell 7',
        program: _pwshPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'pwsh',
      );
      expect(p.remembersCwd, isFalse);
    });

    test('pwsh.exe with showCwdInTitle: true → true '
        '(injected prompt emits OSC 2)', () {
      final p = ShellProfile(
        label: 'PowerShell 7',
        program: _pwshPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'pwsh',
        showCwdInTitle: true,
      );
      expect(p.remembersCwd, isTrue);
    });

    test('powershell.exe with showCwdInTitle: true → true', () {
      final p = ShellProfile(
        label: 'PowerShell 5',
        program: _winPsPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'powershell',
        showCwdInTitle: true,
      );
      expect(p.remembersCwd, isTrue);
    });
  });

  group('isPowerShell', () {
    test('pwsh.exe → true', () {
      final p = ShellProfile(
        label: 'PowerShell 7',
        program: _pwshPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'pwsh',
      );
      expect(p.isPowerShell, isTrue);
    });

    test('powershell.exe → true', () {
      final p = ShellProfile(
        label: 'PowerShell 5',
        program: _winPsPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'powershell',
      );
      expect(p.isPowerShell, isTrue);
    });

    test('case-insensitive basename matching', () {
      final p = ShellProfile(
        label: 'PS Upper',
        program: r'C:\PWSH.EXE',
        args: const [],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'pwsh',
      );
      expect(p.isPowerShell, isTrue);
    });

    test('nu.exe → false', () {
      final p = ShellProfile(
        label: 'Nushell',
        program: _nuWingetPath,
        args: const [],
        icon: Icons.terminal,
        color: Colors.teal,
        shortName: 'nu',
      );
      expect(p.isPowerShell, isFalse);
    });

    test('wsl.exe → false', () {
      final p = ShellProfile(
        label: 'Ubuntu',
        program: _wslPath,
        args: const ['-d', 'Ubuntu', '--cd', '~'],
        icon: Icons.laptop_chromebook,
        color: Colors.green,
        shortName: 'ubuntu',
      );
      expect(p.isPowerShell, isFalse);
    });

    test('bash.exe → false', () {
      final p = ShellProfile(
        label: 'Git Bash',
        program: _gitBashPath,
        args: const ['--login', '-i'],
        icon: Icons.call_split,
        color: Colors.orange,
        shortName: 'bash',
      );
      expect(p.isPowerShell, isFalse);
    });
  });

  group('needsPowerShellPromptOverride', () {
    test('pwsh.exe + showCwdInTitle:true → true', () {
      final p = ShellProfile(
        label: 'PowerShell 7',
        program: _pwshPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'pwsh',
        showCwdInTitle: true,
      );
      expect(p.needsPowerShellPromptOverride, isTrue);
    });

    test('powershell.exe + showCwdInTitle:true → true', () {
      final p = ShellProfile(
        label: 'PowerShell 5',
        program: _winPsPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'powershell',
        showCwdInTitle: true,
      );
      expect(p.needsPowerShellPromptOverride, isTrue);
    });

    test('pwsh.exe without showCwdInTitle → false (opt-out)', () {
      final p = ShellProfile(
        label: 'PowerShell 7',
        program: _pwshPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        color: Colors.blue,
        shortName: 'pwsh',
      );
      expect(p.needsPowerShellPromptOverride, isFalse);
    });

    test(
      'nu.exe + showCwdInTitle:true → false (Nushell is not PowerShell)',
      () {
        final p = ShellProfile(
          label: 'Nushell',
          program: _nuWingetPath,
          args: const [],
          icon: Icons.terminal,
          color: Colors.teal,
          shortName: 'nu',
          showCwdInTitle: true,
        );
        expect(p.needsPowerShellPromptOverride, isFalse);
      },
    );

    test('wsl.exe + showCwdInTitle:true → false', () {
      final p = ShellProfile(
        label: 'Ubuntu',
        program: _wslPath,
        args: const ['-d', 'Ubuntu', '--cd', '~'],
        icon: Icons.laptop_chromebook,
        color: Colors.green,
        shortName: 'ubuntu',
        showCwdInTitle: true,
      );
      expect(p.needsPowerShellPromptOverride, isFalse);
    });
  });
}
