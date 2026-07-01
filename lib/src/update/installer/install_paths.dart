// Path resolvers for the in-app upgrade installer. Pure functions —
// no I/O, just directory construction. The caller (StagedApply) is
// responsible for actually reading or writing.
//
// The "install dir" is the directory the running executable lives in.
// On Windows it's `dirname(Platform.resolvedExecutable)`. We compute
// this lazily and pin to whatever the helper process saw at startup,
// so the helper-mode copy and the regular copy agree on the same
// destination.
//
// The "staging dir" is where the downloaded zip sits. [version] is
// the tag-version (e.g. "1.2.3") used as a folder name; the zip
// inside is named after the GitHub asset (`octodo-v1.2.3-windows-
// x64.zip`). Safe characters only, to keep us off the rocks of
// Windows' case-preserving-but-case-insensitive filesystem.

import 'dart:io';

import 'package:path/path.dart' as p;

class InstallerPaths {
  /// The directory the running `octodo.exe` lives in. All payload
  /// files get copied here.
  final Directory installDir;

  /// Where the downloaded zip is staged before install.
  final Directory stagingDir;

  /// The .zip file, fully resolved.
  final File zipFile;

  /// A transient dir used to extract the zip before copying.
  /// Created on demand by [StagedApply].
  final Directory extractDir;

  const InstallerPaths({
    required this.installDir,
    required this.stagingDir,
    required this.zipFile,
    required this.extractDir,
  });

  /// Build paths from [resolvedExecutable] (default: `Platform.
  /// resolvedExecutable`) and a [version] tag. Useful for tests
  /// that want to drive a sandbox install.
  factory InstallerPaths.fromVersion({
    required String version,
    String? resolvedExecutable,
    Directory? overrideLocalAppData,
  }) {
    final exe = resolvedExecutable ?? Platform.resolvedExecutable;
    final installDir = Directory(p.dirname(exe));
    final staging = _resolveStagingDir(version, overrideLocalAppData);
    final baseName = _sanitize('octodo-v$version-windows-x64.zip');
    final zipFile = File(p.join(staging.path, baseName));
    final extract = Directory(p.join(staging.path, 'extracted'));
    return InstallerPaths(
      installDir: installDir,
      stagingDir: staging,
      zipFile: zipFile,
      extractDir: extract,
    );
  }

  static Directory _resolveStagingDir(
    String version,
    Directory? override,
  ) {
    if (override != null) {
      return Directory(p.join(override.path, 'updates', _sanitize(version)));
    }
    final env = Platform.environment;
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
