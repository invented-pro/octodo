/// Extract the path component from a `file://` URI emitted by OSC 7.
///
/// The Alacritty engine stores the raw OSC 7 payload (`file://host/path`)
/// in `workingDir` without parsing the URI, so callers that need the bare
/// path must strip the scheme + authority themselves.
///
///   `file://hostname/home/user` → `/home/user`
///   `file:///home/user`         → `/home/user` (empty host = localhost)
///   `file:///C:/Users/x`        → `C:/Users/x` (Windows drive — leading
///                                           `/` is a URI artifact)
///   `/home/user`                 → `/home/user` (already a bare path)
///   `C:\Users`                   → `C:\Users`   (Windows path, unchanged)
String stripFileUri(String cwd) {
  if (!cwd.startsWith('file://')) return cwd;
  // Skip "file://" (7 chars), then find the first "/" which marks the
  // start of the path (everything before it is the hostname).
  final afterScheme = cwd.substring(7);
  final slashIdx = afterScheme.indexOf('/');
  if (slashIdx >= 0) {
    final path = afterScheme.substring(slashIdx);
    // A `file://` URI always begins its path with `/`. For POSIX paths
    // (`/home/user`, `/mnt/c/…`) that `/` is part of the real path and
    // must stay. For a Windows drive path the `/` is a URI artifact —
    // `/C:/Users/x` is not a valid Windows path — so strip it when the
    // char after the leading `/` is a drive letter followed by `:`.
    return path.replaceFirstMapped(
      _leadingSlashDriveRe,
      (m) => m.group(1)!,
    );
  }
  return cwd;
}

final RegExp _leadingSlashDriveRe = RegExp(r'^/([A-Za-z]:)');

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

/// Reverse of [translateCwdForShell]: converts a POSIX-style path
/// reported by OSC 7 back to a Windows path, for spawning a new shell
/// in the remembered directory.
///
///   `/mnt/c/Users/x`  →  `C:\Users\x`   (WSL)
///   `/c/Users/x`      →  `C:\Users\x`   (MSYS / Git Bash)
///   `C:\Users\x`      →  `C:\Users\x`   (already Windows — passthrough)
///   `/home/user`      →  `null`         (pure POSIX — no Windows form)
///   `/usr/bin`        →  `null`         (MSYS internal — no Windows form)
///
/// Returns `null` when the path has no Windows equivalent, so callers
/// can fall back to the user home. Classification is by the executable's
/// basename, matching [translateCwdForShell].
String? reverseTranslateCwd({
  required String cwd,
  required String program,
}) {
  if (cwd.isEmpty) return null;
  // Already a Windows drive path — return as-is (handles both `\` and `/`).
  if (_drivePathRe.hasMatch(cwd)) return cwd;
  final base = _basename(program.toLowerCase());
  if (base == 'wsl.exe') {
    final m = _wslMountRe.firstMatch(cwd);
    if (m != null) {
      return _toWindowsDrive(m.group(1)!, m.group(2));
    }
    return null;
  }
  if (base == 'bash.exe' || base == 'sh.exe') {
    final m = _msysMountRe.firstMatch(cwd);
    if (m != null) {
      return _toWindowsDrive(m.group(1)!, m.group(2));
    }
    return null;
  }
  return null;
}

final RegExp _wslMountRe = RegExp(r'^/mnt/([a-z])(?:/(.*))?$');
final RegExp _msysMountRe = RegExp(r'^/([a-z])(?:/(.*))?$');

String _toWindowsDrive(String driveLower, String? rest) {
  final drive = driveLower.toUpperCase();
  if (rest == null || rest.isEmpty) return '$drive:\\';
  return '$drive:\\${rest.replaceAll('/', '\\')}';
}
