// AppImage environment containment for spawned shells.
//
// Octodo's AppRun launcher exports
//
//   LD_LIBRARY_PATH="<mount>/usr/lib:<mount>/usr/bin/lib:<inherited>"
//
// so the app binary resolves the linuxdeploy-bundled GTK stack from
// inside the squashfs mount. flutter_alacritty's `resolveShellSpec`
// spreads the app process's ENTIRE environment into every spawned
// shell, so that value would leak into the user's tabs — and there it
// shadows host libraries for ordinary system tools. On Debian 13,
// procps' `w` links the system libsystemd (needs `LIBSYSTEMD_254`)
// but resolves the AppImage's older bundled `libsystemd.so.0` first
// and dies with:
//
//   w: /tmp/.mount_octodoXXXX/usr/lib/libsystemd.so.0: version
//   `LIBSYSTEMD_254' not found (required by w)
//
// [sanitizeAppImageLdLibraryPath] strips the mount-relative entries,
// restoring whatever LD_LIBRARY_PATH (if any) the user had before
// launching the AppImage. Detection uses `APPIMAGE` — exported by
// the type-2 runtime in both FUSE and --appimage-extract-and-run
// modes, and the same signal the updater's AppImage flow keys on —
// so dev builds, deb installs, and tarballs are untouched. The mount
// root is the AppRun-exported `APPDIR` when available (authoritative
// — it is exactly the prefix the AppRun injects), falling back to
// the running executable's own path (`<root>/usr/bin/octodo`) for
// repacks whose AppRun skips the export. Preferring APPDIR also
// keeps a nested non-AppImage launch (an octodo tarball started from
// inside an AppImage-spawned tab, where APPIMAGE leaks through) from
// guessing a wrong root and stripping the user's own entries.

/// Returns the `LD_LIBRARY_PATH` value a spawned shell should see, or
/// null when no override is needed (not an AppImage run, nothing
/// inherited, or no mount-relative entries to strip).
///
/// An empty-string return is meaningful: it means the inherited value
/// consisted ONLY of the AppImage's bundled-lib entries, and the
/// caller must still override (an empty LD_LIBRARY_PATH adds no
/// search dirs — the same empty-string-override seam the
/// PROMPT_COMMAND suppression uses).
String? sanitizeAppImageLdLibraryPath({
  required Map<String, String> environment,
  required String resolvedExecutable,
}) {
  final appImage = environment['APPIMAGE'];
  if (appImage == null || appImage.isEmpty) return null;
  final inherited = environment['LD_LIBRARY_PATH'];
  if (inherited == null || inherited.isEmpty) return null;
  final appDir = environment['APPDIR'];
  String mountRoot;
  if (appDir != null && appDir.isNotEmpty) {
    mountRoot = appDir;
  } else {
    final binMarker = resolvedExecutable.lastIndexOf('/usr/bin/');
    if (binMarker <= 0) return null;
    mountRoot = resolvedExecutable.substring(0, binMarker);
  }
  final entries = inherited.split(':');
  final kept = entries
      .where((e) => e != mountRoot && !e.startsWith('$mountRoot/'))
      .toList();
  if (kept.length == entries.length) return null;
  return kept.join(':');
}
