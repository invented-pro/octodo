// Path resolvers for the in-app upgrade installer. Pure functions —
// no I/O, just directory construction. The caller (StagedApply) is
// responsible for actually reading or writing.
//
// The "install dir" depends on the apply strategy:
//
//   * [ApplyStrategy.perFileCopy] (Windows portable layout) — the
//     directory the running executable lives in:
//     `dirname(Platform.resolvedExecutable)`. Every payload file is
//     copied over the existing tree in place.
//
//   * [ApplyStrategy.bundleSwap] (macOS .app layout) — the PARENT
//     of the running `.app` bundle (typically `/Applications`). The
//     payload zip contains a whole `Octodo.app` at its root, and the
//     apply swaps the old bundle out for the new one with two
//     renames. POSIX lets the (exited) app's files be renamed and
//     deleted freely, so no per-file copy dance is needed.
//
// The strategy is derived from the layout, not the raw OS flag: if
// the executable sits inside a `*.app` bundle we swap the bundle;
// otherwise we fall back to per-file copy. `flutter run` and
// release builds on macOS both run from inside `Octodo.app`, so
// production macOS always resolves bundleSwap, while a plain
// `/opt/octodo/octodo` path (tests, hypothetical Linux portable)
// resolves perFileCopy.
//
// The "staging dir" is where the downloaded zip sits. [version] is
// the tag-version (e.g. "1.2.3") used as a folder name; the zip
// inside is named after the release asset
// (`octodo-v1.2.3-windows-x64.zip`, `octodo-v1.2.3-macos-arm64.zip`,
// …). Safe characters only, to keep us off the rocks of Windows'
// case-preserving-but-case-insensitive filesystem.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../release_resolver.dart';

/// How [StagedApply] replaces the current install with the staged
/// payload. See the library comment for the per-platform rationale.
enum ApplyStrategy {
  /// Extract the zip and copy each file over the install dir
  /// (Windows portable layout; the running exe's directory).
  perFileCopy,

  /// Extract the zip and swap the whole `.app` bundle into place
  /// with rename-aside (macOS bundle layout).
  bundleSwap,
}

class InstallerPaths {
  /// The directory payload files get applied into. For
  /// [ApplyStrategy.perFileCopy] this is the directory the running
  /// `octodo.exe` lives in; for [ApplyStrategy.bundleSwap] it is
  /// the parent of the running `.app` bundle.
  final Directory installDir;

  /// Where the downloaded zip is staged before install.
  final Directory stagingDir;

  /// The .zip file, fully resolved.
  final File zipFile;

  /// A transient dir used to extract the zip before applying.
  /// Created on demand by [StagedApply].
  final Directory extractDir;

  /// Which apply replacement strategy [StagedApply] should use.
  final ApplyStrategy applyStrategy;

  /// The running app's `.app` bundle root (e.g.
  /// `/Applications/Octodo.app`), or null on the per-file-copy
  /// layout. When non-null, [installDir] is its parent.
  final Directory? appBundleRoot;

  const InstallerPaths({
    required this.installDir,
    required this.stagingDir,
    required this.zipFile,
    required this.extractDir,
    this.applyStrategy = ApplyStrategy.perFileCopy,
    this.appBundleRoot,
  });

  /// Build paths from [resolvedExecutable] (default: `Platform.
  /// resolvedExecutable`) and a [version] tag. Useful for tests
  /// that want to drive a sandbox install.
  ///
  /// [assetToken] names the zip (`octodo-v<ver>-<token>.zip`);
  /// defaults to [kDefaultAssetToken] so historical callers keep
  /// the Windows name. Production passes [currentAssetToken].
  ///
  /// [applyStrategy] is derived from the executable's layout
  /// (inside a `.app` bundle → [ApplyStrategy.bundleSwap]) unless
  /// explicitly pinned for tests.
  factory InstallerPaths.fromVersion({
    required String version,
    String? resolvedExecutable,
    Directory? overrideLocalAppData,
    String assetToken = kDefaultAssetToken,
    ApplyStrategy? applyStrategy,
  }) {
    final exe = resolvedExecutable ?? Platform.resolvedExecutable;
    final bundleRoot = _findBundleRoot(exe);
    // Layout-driven, deliberately NOT a raw Platform check: a
    // `*.app` ancestor means bundle layout regardless of host OS
    // (which also keeps unit tests deterministic on any CI host).
    // An explicit [applyStrategy] pin wins — except that
    // bundleSwap without a bundle root is a contradiction.
    final strategy = applyStrategy ??
        (bundleRoot != null
            ? ApplyStrategy.bundleSwap
            : ApplyStrategy.perFileCopy);
    if (strategy == ApplyStrategy.bundleSwap && bundleRoot == null) {
      throw ArgumentError(
        'applyStrategy=bundleSwap requires the executable to live '
        'inside a .app bundle (got "$exe")',
      );
    }
    // On the bundle layout the swap target is the directory that
    // HOLDS the .app (e.g. /Applications); StagedApply renames the
    // old bundle aside within it. Otherwise the install dir is the
    // executable's own directory.
    final installDir = strategy == ApplyStrategy.bundleSwap
        ? Directory(p.dirname(bundleRoot!))
        : Directory(p.dirname(exe));
    final staging = _resolveStagingDir(version, overrideLocalAppData);
    final baseName = _sanitize('octodo-v$version-$assetToken.zip');
    final zipFile = File(p.join(staging.path, baseName));
    final extract = Directory(p.join(staging.path, 'extracted'));
    return InstallerPaths(
      installDir: installDir,
      stagingDir: staging,
      zipFile: zipFile,
      extractDir: extract,
      applyStrategy: strategy,
      appBundleRoot: strategy == ApplyStrategy.bundleSwap
          ? Directory(bundleRoot!)
          : null,
    );
  }

  /// The innermost `*.app` ancestor directory of [exe], or null
  /// when the executable is not inside a bundle. Shared with the
  /// MAS-receipt detection in distribution.dart via its own copy —
  /// kept local so this file stays I/O- and platform-gate-free.
  static String? _findBundleRoot(String exe) {
    var current = p.dirname(exe);
    for (var i = 0; i < 10; i++) {
      if (p.basename(current).endsWith('.app')) return current;
      final parent = p.dirname(current);
      if (parent == current) return null;
      current = parent;
    }
    return null;
  }

  static Directory _resolveStagingDir(
    String version,
    Directory? override,
  ) {
    if (override != null) {
      return Directory(p.join(override.path, 'updates', _sanitize(version)));
    }
    final env = Platform.environment;
    if (Platform.isMacOS) {
      // Idiomatic macOS home for app-managed support files. Used
      // for update staging + the skip-list so a user inspecting
      // ~/Library sees the expected layout.
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return Directory(p.join(home, 'Library', 'Application Support',
            'Octodo', 'updates', _sanitize(version)));
      }
    }
    if (Platform.isWindows) {
      final local = env['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        return Directory(p.join(local, 'octodo', 'updates', _sanitize(version)));
      }
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(p.join(home, '.octodo', 'updates', _sanitize(version)));
    }
    return Directory.systemTemp.createTempSync('octodo_updates_');
  }

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');

  /// The basename of the running executable on the current
  /// platform. Used to ensure we don't copy a non-`octodo` file
  /// named `octodo.exe` from a malicious zip; in practice the
  /// install dir's own `octodo.exe` is what we replace.
  static String executableBasename() =>
      Platform.isWindows ? 'octodo.exe' : 'octodo';
}
