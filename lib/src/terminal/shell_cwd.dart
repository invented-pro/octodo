/// Convert a Windows path to the format the given shell expects for
/// its `lpCurrentDirectory` (and the format its OSC 7 reports back).
///
/// Most shells (PowerShell, Windows PowerShell, cmd.exe) use Windows
/// paths as-is. POSIX-flavoured shells hosted on top of Win32 — i.e.
/// WSL's `wsl.exe` and Git Bash's `bash.exe` — translate the path to
/// their own mount-point style:
///
///   `C:\Users\<user>`   →  `/mnt/c/Users/<user>`  (WSL)
///   `C:\Users\<user>`   →  `/c/Users/<user>`      (MSYS / Git Bash)
///   `\\server\share`    →  unchanged              (no regex match; UNC)
///   `/home/<user>`      →  unchanged              (already POSIX)
///   `""`                →  `""`                   (no-op)
///
/// Classification is by the executable's basename (`wsl.exe` /
/// `bash.exe` / `sh.exe`), so pass the shell's [program] path directly —
/// not a serialized command line. The heuristic is best-effort: anything
/// the regex can't recognize is returned unchanged so we never corrupt a
/// path the shell might actually understand.
String translateCwdForShell({
  required String cwd,
  required String program,
}) {
  if (cwd.isEmpty) return cwd;
  final base = _basename(program.toLowerCase());
  if (base == 'wsl.exe') {
    return _windowsToWslMount(cwd);
  }
  if (base == 'bash.exe' || base == 'sh.exe') {
    return _windowsToMsys(cwd);
  }
  return cwd;
}

String _basename(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

final RegExp _drivePathRe = RegExp(r'^([A-Za-z]):[\\/](.*)$');

String _windowsToWslMount(String p) {
  // WSL's default mount maps C:\ → /mnt/c. The reverse path is the
  // rare case (caller passed `/mnt/c/…`); leave it untouched.
  if (p.startsWith('/')) return p;
  final m = _drivePathRe.firstMatch(p);
  if (m == null) return p;
  final drive = m.group(1)!.toLowerCase();
  final rest = m.group(2)!.replaceAll('\\', '/');
  return '/mnt/$drive/$rest';
}

String _windowsToMsys(String p) {
  // MSYS2 / Git Bash map C:\ → /c/. Same caveat as above.
  if (p.startsWith('/')) return p;
  final m = _drivePathRe.firstMatch(p);
  if (m == null) return p;
  final drive = m.group(1)!.toLowerCase();
  final rest = m.group(2)!.replaceAll('\\', '/');
  return '/$drive/$rest';
}
