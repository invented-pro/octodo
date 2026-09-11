// AppImage environment containment for spawned shells.
//
// Octodo's AppRun launcher exports
//
//   LD_LIBRARY_PATH="<mount>/usr/lib:<mount>/usr/bin/lib[:<inherited>]"
//   GIO_MODULE_DIR="<mount>/usr/lib/gio/modules"   (empty dir)
//
// (the inherited suffix is appended only when the variable was set —
// a bare trailing ":" would be an empty entry, which ld treats as
// "search the current working directory")
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
//
// The AppRun additionally pins `GIO_MODULE_DIR` to the bundle's
// empty gio-modules dir, so the bundled (22.04, GLib 2.72) never
// dlopens the host's gio modules — built against a newer GLib, they
// die with "undefined symbol: g_task_set_static_name" noise (GH
// #12). That pin must NOT leak into spawned shells: inherited by
// host gio tools in tabs it would silently disable their modules
// (gvfs, `gio open`). [sanitizeAppImageGioModuleDir] detects the
// pin and replaces it with the host's own modules dir when locatable
// (the running arch's Debian/Ubuntu multiarch dir first, then
// Fedora/SUSE lib64, then Arch-style /usr/lib — existence-checked),
// else '' (loads no modules — containment, never wrong-modules).

import 'dart:ffi' show Abi;
import 'dart:io';


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

/// Host gio-modules dirs probed when restoring the child-shell
/// value: Debian/Ubuntu multiarch (per common arches), Fedora/SUSE
/// lib64, then Arch-style /usr/lib. The running architecture's
/// multiarch entry is moved to the FRONT at probe time (see
/// [_orderedGioModuleDirCandidates]) — existence alone is not a
/// safe selector, because a multiarch host (amd64 glib installed on
/// arm64, e.g. for Wine/box64) has BOTH multiarch dirs, and handing
/// an arm64 shell the x86-64 one disables gio modules all over
/// again (wrong ELF class).
const List<String> kHostGioModuleDirCandidates = [
  '/usr/lib/x86_64-linux-gnu/gio/modules',
  '/usr/lib/aarch64-linux-gnu/gio/modules',
  '/usr/lib64/gio/modules',
  '/usr/lib/gio/modules',
];

/// Reorders [kHostGioModuleDirCandidates] so the entry matching
/// [hostAbi]'s multiarch triplet is probed first. Non-Linux ABIs
/// (and unrecognized triplets) keep the static order — the function
/// is only ever called from the Linux spawn path.
List<String> _orderedGioModuleDirCandidates(
  Abi? hostAbi,
  List<String> base,
) {
  final triplet = switch (hostAbi ?? Abi.current()) {
    Abi.linuxX64 => 'x86_64-linux-gnu',
    Abi.linuxArm64 => 'aarch64-linux-gnu',
    _ => null,
  };
  if (triplet == null) return base;
  final preferred = '/usr/lib/$triplet/gio/modules';
  return [preferred, ...base.where((c) => c != preferred)];
}

/// Returns the `GIO_MODULE_DIR` a spawned shell should see, or null
/// when no override is needed (not an AppImage run, no pin present,
/// or the current value is not the AppRun's pin — a user-set value
/// is left alone).
///
/// An empty-string return is meaningful: no locatable host modules
/// dir, so the child loads NO gio modules — the same containment the
/// pin gives the app, and never a wrong-modules load.
String? sanitizeAppImageGioModuleDir({
  required Map<String, String> environment,
  required String resolvedExecutable,
  List<String> hostCandidates = kHostGioModuleDirCandidates,
  bool Function(String path)? pathExists,
  Abi? hostAbi,
}) {
  final appImage = environment['APPIMAGE'];
  if (appImage == null || appImage.isEmpty) return null;
  final pinned = environment['GIO_MODULE_DIR'];
  if (pinned == null || pinned.isEmpty) return null;
  final appDir = environment['APPDIR'];
  String mountRoot;
  if (appDir != null && appDir.isNotEmpty) {
    mountRoot = appDir;
  } else {
    final binMarker = resolvedExecutable.lastIndexOf('/usr/bin/');
    if (binMarker <= 0) return null;
    mountRoot = resolvedExecutable.substring(0, binMarker);
  }
  // Only the AppRun's pin is replaced: it equals or lives under the
  // mount root. Anything else is the user's own value — pass through.
  if (pinned != mountRoot && !pinned.startsWith('$mountRoot/')) {
    return null;
  }
  final exists = pathExists ?? (path) => Directory(path).existsSync();
  final candidates = _orderedGioModuleDirCandidates(hostAbi, hostCandidates);
  for (final candidate in candidates) {
    if (exists(candidate)) return candidate;
  }
  return '';
}
