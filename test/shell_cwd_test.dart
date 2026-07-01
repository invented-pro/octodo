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
}
