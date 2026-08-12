import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/shell_cwd.dart';

void main() {
  group('translateCwdForShell', () {
    const winPath = r'C:\Users\alice\projects';

    test('wsl.exe → /mnt/<drive>/… mount', () {
      expect(
        translateCwdForShell(
          cwd: winPath,
          program: r'C:\Windows\System32\wsl.exe',
        ),
        '/mnt/c/Users/alice/projects',
      );
    });

    test('wsl.exe path with spaces still classified by basename', () {
      expect(
        translateCwdForShell(
          cwd: r'D:\repo',
          program: r'C:\some where\wsl.exe',
        ),
        '/mnt/d/repo',
      );
    });

    test('bash.exe → MSYS /<drive>/… mount', () {
      expect(
        translateCwdForShell(
          cwd: winPath,
          program: r'C:\Program Files\Git\bin\bash.exe',
        ),
        '/c/Users/alice/projects',
      );
    });

    test('sh.exe → MSYS mount (same as bash)', () {
      expect(
        translateCwdForShell(
          cwd: winPath,
          program: r'C:\msys64\usr\bin\sh.exe',
        ),
        '/c/Users/alice/projects',
      );
    });

    test('pwsh.exe → unchanged (Windows path as-is)', () {
      expect(
        translateCwdForShell(
          cwd: winPath,
          program: r'C:\Program Files\PowerShell\7\pwsh.exe',
        ),
        winPath,
      );
    });

    test('Windows PowerShell → unchanged', () {
      expect(
        translateCwdForShell(
          cwd: winPath,
          program:
              r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        ),
        winPath,
      );
    });

    test('cmd.exe → unchanged', () {
      expect(
        translateCwdForShell(
          cwd: winPath,
          program: r'C:\Windows\System32\cmd.exe',
        ),
        winPath,
      );
    });

    test('empty cwd short-circuits to empty', () {
      expect(
        translateCwdForShell(
          cwd: '',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        '',
      );
    });

    test('already-POSIX cwd left untouched (wsl)', () {
      expect(
        translateCwdForShell(
          cwd: '/home/alice',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        '/home/alice',
      );
    });

    test('already-POSIX cwd left untouched (bash)', () {
      expect(
        translateCwdForShell(
          cwd: '/c/Users/alice',
          program: r'C:\Program Files\Git\bin\bash.exe',
        ),
        '/c/Users/alice',
      );
    });

    test('UNC path left untouched', () {
      const unc = r'\\server\share\dir';
      expect(
        translateCwdForShell(
          cwd: unc,
          program: r'C:\Windows\System32\wsl.exe',
        ),
        unc,
      );
    });

    test('lower-case drive letter is used in mount', () {
      expect(
        translateCwdForShell(
          cwd: r'Z:\Data',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        '/mnt/z/Data',
      );
    });

    test('backslashes in the tail become forward slashes', () {
      expect(
        translateCwdForShell(
          cwd: r'C:\a\b\c',
          program: r'C:\Program Files\Git\bin\bash.exe',
        ),
        '/c/a/b/c',
      );
    });
  });

  // Regression guard for the wsl-vs-bash classification: the two shells use
  // DIFFERENT mount layouts (/mnt/c vs /c), so a path passed to the wrong
  // family produces a cwd the shell cannot understand. Locking the mapping
  // here keeps detectShells' "no PATH lookup for bash.exe" guard meaningful.
  test('wsl and bash mounts are never identical for the same drive path', () {
    const cwd = r'C:\Users\alice';
    final wsl = translateCwdForShell(
      cwd: cwd,
      program: r'C:\Windows\System32\wsl.exe',
    );
    final bash = translateCwdForShell(
      cwd: cwd,
      program: r'C:\Program Files\Git\bin\bash.exe',
    );
    expect(wsl, '/mnt/c/Users/alice');
    expect(bash, '/c/Users/alice');
    expect(wsl, isNot(equals(bash)));
  });

  group('reverseTranslateCwd', () {
    test('wsl.exe /mnt/<drive>/… → Windows', () {
      expect(
        reverseTranslateCwd(
          cwd: '/mnt/c/Users/alice/projects',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        r'C:\Users\alice\projects',
      );
    });

    test('bash.exe /<drive>/… → Windows', () {
      expect(
        reverseTranslateCwd(
          cwd: '/c/Users/alice/projects',
          program: r'C:\Program Files\Git\bin\bash.exe',
        ),
        r'C:\Users\alice\projects',
      );
    });

    test('sh.exe /<drive>/… → Windows (same as bash)', () {
      expect(
        reverseTranslateCwd(
          cwd: '/d/repo',
          program: r'C:\msys64\usr\bin\sh.exe',
        ),
        r'D:\repo',
      );
    });

    test('already-Windows path passes through', () {
      expect(
        reverseTranslateCwd(
          cwd: r'C:\Users\alice',
          program: r'C:\Program Files\PowerShell\7\pwsh.exe',
        ),
        r'C:\Users\alice',
      );
    });

    test('wsl drive root → drive:\\', () {
      expect(
        reverseTranslateCwd(
          cwd: '/mnt/c/',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        r'C:\',
      );
    });

    test('msys drive root → drive:\\', () {
      expect(
        reverseTranslateCwd(
          cwd: '/c/',
          program: r'C:\Program Files\Git\bin\bash.exe',
        ),
        r'C:\',
      );
    });

    test('pure POSIX /home → null (no Windows equivalent)', () {
      expect(
        reverseTranslateCwd(
          cwd: '/home/alice',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        isNull,
      );
    });

    test('MSYS internal /usr/bin → null', () {
      expect(
        reverseTranslateCwd(
          cwd: '/usr/bin',
          program: r'C:\Program Files\Git\bin\bash.exe',
        ),
        isNull,
      );
    });

    test('empty cwd → null', () {
      expect(
        reverseTranslateCwd(
          cwd: '',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        isNull,
      );
    });

    test('upper-case drive letter in result', () {
      expect(
        reverseTranslateCwd(
          cwd: '/mnt/z/data',
          program: r'C:\Windows\System32\wsl.exe',
        ),
        r'Z:\data',
      );
    });

    test('round-trip: translate then reverse yields original Windows path', () {
      const original = r'D:\projects\octodo';
      final posix = translateCwdForShell(
        cwd: original,
        program: r'C:\Windows\System32\wsl.exe',
      );
      final back = reverseTranslateCwd(
        cwd: posix,
        program: r'C:\Windows\System32\wsl.exe',
      );
      expect(back, original);
    });

    test('pwsh.exe with POSIX cwd → null (no mount mapping)', () {
      expect(
        reverseTranslateCwd(
          cwd: '/mnt/c/Users',
          program: r'C:\Program Files\PowerShell\7\pwsh.exe',
        ),
        isNull,
      );
    });
  });

  group('stripFileUri', () {
    test('file://hostname/path → /path', () {
      expect(
        stripFileUri('file://HP66/home/alice/projects'),
        '/home/alice/projects',
      );
    });

    test('file:///path (localhost) → /path', () {
      expect(
        stripFileUri('file:///home/alice'),
        '/home/alice',
      );
    });

    test('bare POSIX path unchanged', () {
      expect(
        stripFileUri('/mnt/c/Users/alice'),
        '/mnt/c/Users/alice',
      );
    });

    test('Windows path unchanged', () {
      expect(
        stripFileUri(r'C:\Users\alice'),
        r'C:\Users\alice',
      );
    });

    test('empty string unchanged', () {
      expect(stripFileUri(''), '');
    });

    test('file:// with no path after hostname', () {
      expect(
        stripFileUri('file://hostname'),
        'file://hostname',
      );
    });

    test('file:///C:/… → C:/… (Windows drive, leading `/` stripped)', () {
      expect(
        stripFileUri('file:///C:/Users/alice'),
        'C:/Users/alice',
      );
    });

    test('file://host/C:/… → C:/… (Windows drive via hostname)', () {
      expect(
        stripFileUri('file://HP66/C:/Users/alice/projects'),
        'C:/Users/alice/projects',
      );
    });

    test('POSIX path unaffected by drive-letter heuristic', () {
      // `/home/alice` — `h` is a letter but no `:` follows, so the
      // drive regex does not match and the leading `/` stays.
      expect(
        stripFileUri('file:///home/alice'),
        '/home/alice',
      );
      // `/mnt/c/Users/alice` — same: `/m` has no colon after.
      expect(
        stripFileUri('file:///mnt/c/Users/alice'),
        '/mnt/c/Users/alice',
      );
    });
  });
}
