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
PathProbe _existsFor(Set<String> paths) => (p) => paths.contains(p);

// Well-known paths detectShellsFrom probes — captured here so tests stay in
// sync with the implementation and don't hardcode the developer's machine.
const _pwshPath = r'C:\Program Files\PowerShell\7\pwsh.exe';
const _winPsPath =
    r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
const _cmdPath = r'C:\Windows\System32\cmd.exe';
const _wslPath = r'C:\Windows\System32\wsl.exe';
const _gitBashPath = r'C:\Program Files\Git\bin\bash.exe';

const _baseEnv = <String, String>{
  'SystemRoot': r'C:\Windows',
  'USERPROFILE': r'C:\Users\tester', // test placeholder, never a real user
  'PATH': '',
};

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
    test('full host: pwsh → powershell → cmd → each distro → bash, in order', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {
          _pwshPath, _winPsPath, _cmdPath, _wslPath, _gitBashPath,
        }),
        environment: _baseEnv,
        listWslDistros: (_) => const ['Ubuntu', 'Debian'],
      );

      // Family order must hold; distro shortNames are lowercased distro names.
      expect(
        profiles.map((p) => p.shortName).toList(),
        ['pwsh', 'powershell', 'cmd', 'ubuntu', 'debian', 'bash'],
      );
      // Programs/args wired correctly per family.
      expect(profiles.firstWhere((p) => p.shortName == 'pwsh').program,
          _pwshPath);
      expect(profiles.firstWhere((p) => p.shortName == 'pwsh').args,
          ['-NoLogo']);
      expect(profiles.firstWhere((p) => p.shortName == 'cmd').args, isEmpty);
      final bash = profiles.firstWhere((p) => p.shortName == 'bash');
      expect(bash.program, _gitBashPath);
      expect(bash.args, ['--login', '-i']);

      // iconAsset wiring: PowerShell 7 + Windows PowerShell share one
      // SVG; CMD keeps the Material fallback (no asset); Git Bash gets
      // the Git branch-mark; each WSL distro gets its own per-distro SVG.
      expect(profiles.firstWhere((p) => p.shortName == 'pwsh').iconAsset,
          'assets/icons/powershell.svg');
      expect(profiles.firstWhere((p) => p.shortName == 'powershell')
          .iconAsset,
          'assets/icons/powershell.svg');
      expect(profiles.firstWhere((p) => p.shortName == 'cmd').iconAsset,
          isNull);
      expect(bash.iconAsset, 'assets/icons/git-bash.svg');
      expect(profiles.firstWhere((p) => p.shortName == 'ubuntu').iconAsset,
          'assets/icons/ubuntu.svg');
      expect(profiles.firstWhere((p) => p.shortName == 'debian').iconAsset,
          'assets/icons/debian.svg');
    });

    test('every WSL distro becomes its own profile with -d <distro>', () {
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
        expect(entry.value.args, ['-d', entry.key]);
        expect(entry.value.showCwdInTitle, isTrue);
      }
      // Distinct distros get distinct shortNames (so the tab chip differs).
      expect(wsl.map((p) => p.shortName).toSet().length, wsl.length);
    });

    test('shortNames stay unique across distros and the static shells', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(
            const {_pwshPath, _winPsPath, _cmdPath, _wslPath, _gitBashPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const ['Ubuntu', 'Debian'],
      );
      final names = profiles.map((p) => p.shortName).toList();
      expect(names.toSet().length, names.length,
          reason: 'Duplicate shortNames would collide in the tab chip');
    });

    test('wsl.exe present but no distro registered → no WSL profiles (no dead entry)', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_wslPath, _cmdPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      expect(profiles.where((p) => p.isWsl), isEmpty);
    });

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
      expect(listerCalled, isFalse,
          reason: 'wsl.exe missing must short-circuit before listing distros');
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
        fileExists: _existsFor(const {
          r'C:\Tools\bin\pwsh.exe',
          _cmdPath,
        }),
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

    test('pwsh absent everywhere → no pwsh profile', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      expect(profiles.where((p) => p.shortName == 'pwsh'), isEmpty);
    });

    test('Git Bash is NOT picked up from a bare bash.exe on PATH (WSL launcher guard)', () {
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
    });

    test('Git for Windows at the well-known path is detected', () {
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {_cmdPath, _gitBashPath}),
        environment: _baseEnv,
        listWslDistros: (_) => const [],
      );
      final bash = profiles.where((p) => p.shortName == 'bash').single;
      expect(bash.program, _gitBashPath);
    });

    test('respects SystemRoot from the environment', () {
      // If SystemRoot is relocated, the System32-derived paths must follow it.
      const customRoot = r'D:\Win';
      final profiles = detectShellsFrom(
        fileExists: _existsFor(const {
          r'D:\Win\System32\cmd.exe',
        }),
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

  group('resolveWslIconAsset', () {
    test('maps known distros to their SVG asset', () {
      expect(resolveWslIconAsset('Ubuntu'), 'assets/icons/ubuntu.svg');
      expect(resolveWslIconAsset('Debian'), 'assets/icons/debian.svg');
      expect(resolveWslIconAsset('Fedora Linux'), 'assets/icons/fedora.svg');
      expect(resolveWslIconAsset('Arch'), 'assets/icons/arch.svg');
      expect(resolveWslIconAsset('openSUSE Leap-15.5'),
          'assets/icons/opensuse.svg');
      expect(resolveWslIconAsset('kali-linux'), 'assets/icons/kali.svg');
      expect(resolveWslIconAsset('Alpine'), 'assets/icons/alpine.svg');
      expect(resolveWslIconAsset('CentOS Stream'),
          'assets/icons/centos.svg');
      expect(resolveWslIconAsset('OracleLinux'), 'assets/icons/oracle.svg');
      expect(resolveWslIconAsset('NixOS'), 'assets/icons/nixos.svg');
    });

    test('matches case-insensitively against the leading token', () {
      expect(resolveWslIconAsset('ubuntu-22.04'), 'assets/icons/ubuntu.svg');
      expect(resolveWslIconAsset('KALI-LINUX'),
          'assets/icons/kali.svg');
      expect(resolveWslIconAsset('OPENSUSE-Tumbleweed'),
          'assets/icons/opensuse.svg');
    });

    test('matches version-suffixed distros by their leading token', () {
      // Regression for the Debian-11/12/13 case: `wsl --list` reports
      // version-suffixed names for user-imported distros, and we
      // resolve them by the leading token so a single icon serves all
      // major versions. Critical: 'Debian' must win ahead of any
      // generic fallback path.
      expect(resolveWslIconAsset('Debian-11'), 'assets/icons/debian.svg');
      expect(resolveWslIconAsset('Debian-12'),
          'assets/icons/debian.svg');
      expect(resolveWslIconAsset('Debian GNU/Linux'),
          'assets/icons/debian.svg');
      expect(resolveWslIconAsset('Ubuntu-22.04'),
          'assets/icons/ubuntu.svg');
      expect(resolveWslIconAsset('Arch-2024.05.01'),
          'assets/icons/arch.svg');
      expect(resolveWslIconAsset('Alpine-3.20'),
          'assets/icons/alpine.svg');
    });

    test('falls back to the WSL fallback asset for unknown distros', () {
      expect(resolveWslIconAsset('PenguinOS'),
          'assets/icons/wsl-fallback.svg');
      expect(resolveWslIconAsset(''), 'assets/icons/wsl-fallback.svg');
      expect(resolveWslIconAsset('  '), 'assets/icons/wsl-fallback.svg');
    });

    test('aliases related distros to the closest shipped icon', () {
      // Rocky / Alma / RHEL don't have their own icons — fall back to
      // CentOS, which is visually closest.
      expect(resolveWslIconAsset('Rocky Linux'),
          'assets/icons/centos.svg');
      expect(resolveWslIconAsset('AlmaLinux-9'),
          'assets/icons/centos.svg');
      expect(resolveWslIconAsset('RHEL-9'),
          'assets/icons/centos.svg');
      // SUSE Linux Enterprise shares the openSUSE chameleon.
      expect(resolveWslIconAsset('SLES-15'),
          'assets/icons/opensuse.svg');
    });
  });
}
