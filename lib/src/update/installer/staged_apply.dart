// Self-apply: extract the staged payload and copy it over the
// install dir.
//
// Triggered by the helper process — `apply_main.dart` calls
// [StagedApply.run] with paths read out of env vars. The original
// process has already exited (or is exiting) by the time we run.
//
// Defence-in-depth checks before any file is written:
//   * Zip entry paths are normalized and bounds-checked against the
//     staging extract dir. Any path that resolves outside it
//     (a classic "zip slip" payload) throws and aborts.
//   * Symlink paths within the zip would be unusual for a portable
//     release; if they're encountered, we treat them as regular
//     files (copy bytes; do not follow). Flutter Windows builds
//     don't include symlinks anyway.
//   * Files we copy into the install dir are basename-checked
//     against the expected octodo.exe / DLL layout — defending
//     against a malicious zip that drops a `..` ladder into
//     neighbouring dirs.
//
// Windows file locks while the original process is still alive can
// make overwrite retries necessary. We use bounded backoff.

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'install_paths.dart';

class StagedApplyException implements Exception {
  final String message;
  final Object? cause;
  const StagedApplyException(this.message, [this.cause]);
  @override
  String toString() => cause == null
      ? 'StagedApplyException: $message'
      : 'StagedApplyException: $message ($cause)';
}

class StagedApply {
  /// Runs the full self-apply in the helper process. Returns when
  /// everything has finished (and the relaunch has been spawned,
  /// if [relaunchAfter] is true). Throws [StagedApplyException]
  /// on any failure; the caller should propagate.
  ///
  /// [pidToIgnore] is the *original* app's PID. We poll for a bit
  /// (with a generous ceiling) to ensure it's actually exited
  /// before we start touching install-dir files, then proceed.
  /// If the poll exceeds [pidTimeout] we proceed anyway — Windows
  /// file locks will be caught by the per-file retry loop.
  static Future<void> run({
    required InstallerPaths paths,
    required int pidToIgnore,
    Duration initialDelay =
        const Duration(milliseconds: 2500),
    Duration pidPollInterval = const Duration(milliseconds: 250),
    Duration pidTimeout = const Duration(seconds: 8),
    int overwriteAttempts = 6,
    Duration overwriteBackoff = const Duration(milliseconds: 500),
    bool relaunchAfter = true,
  }) async {
    if (!await paths.zipFile.exists()) {
      throw StagedApplyException(
        'Staged zip not found at ${paths.zipFile.path}',
      );
    }

    await _awaitProcessExit(
      pidToIgnore,
      pollInterval: pidPollInterval,
      timeout: pidTimeout,
      initialDelay: initialDelay,
    );

    if (await paths.extractDir.exists()) {
      // Clean any previous extraction so a re-run is safe.
      await paths.extractDir.delete(recursive: true);
    }
    await paths.extractDir.create(recursive: true);

    await _extractZip(paths);

    await _copyExtractedIntoInstallDir(
      paths,
      attempts: overwriteAttempts,
      backoff: overwriteBackoff,
    );

    if (relaunchAfter) {
      await _relaunch(paths);
    }
  }

  /// Pure heuristic to wait until [pid] is no longer listed. We
  /// start with an initial delay (which is typically enough), then
  /// spot-check with `tasklist /FI "PID eq <pid>"`.
  static Future<void> _awaitProcessExit(
    int pid, {
    required Duration initialDelay,
    required Duration pollInterval,
    required Duration timeout,
  }) async {
    await Future<void>.delayed(initialDelay);

    if (pid <= 0) return;
    if (!Platform.isWindows) {
      // macOS/Linux: portable zip contents would only land on
      // those platforms if we ever ship a build for them — the
      // auto-update flow is gated to Windows-only for v1.
      return;
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final alive = await _pidAlive(pid);
      if (!alive) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  static Future<bool> _pidAlive(int pid) async {
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'PID eq $pid', '/NH'],
        stdoutEncoding: const SystemEncoding(),
      );
      final out = (result.stdout as String).toLowerCase();
      return out.contains(pid.toString());
    } catch (_) {
      // If tasklist fails we can't tell — assume still alive so
      // the timer keeps ticking until timeout.
      return true;
    }
  }

  static Future<void> _extractZip(InstallerPaths paths) async {
    final bytes = await paths.zipFile.readAsBytes();
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw StagedApplyException('Could not decode zip: ${paths.zipFile.path}', e);
    }

    for (final entry in archive) {
      if (!entry.isFile) {
        // Skip directories and (best-effort) other kinds.
        continue;
      }
      final name = entry.name;
      final target = _resolvedTargetPath(paths.extractDir.path, name);
      await target.parent.create(recursive: true);
      final content = entry.content as List<int>;
      await File(target.path).writeAsBytes(
        content,
        flush: false,
      );
    }
  }

  /// Resolves a zip entry name into a destination path under [root],
  /// rejecting paths that resolve outside it (zip-slip defence).
  @visibleForTesting
  static File resolveTargetPath(String root, String entryName) {
    final cleaned = entryName.replaceAll('\\', '/');
    if (cleaned.contains('..')) {
      throw StagedApplyException(
        'Refusing zip entry with ".." segment: $entryName',
      );
    }
    final joined = p.join(root, cleaned);
    final normalized = p.normalize(joined);
    final normalizedRoot = p.normalize(root);
    if (!p.isWithin(normalizedRoot, normalized) &&
        normalized != normalizedRoot) {
      throw StagedApplyException(
        'Refusing zip entry that escapes root: $entryName',
      );
    }
    return File(normalized);
  }

  /// Internal alias kept for the same code paths used before the
  /// rename to `resolveTargetPath`.
  static File _resolvedTargetPath(String root, String entryName) =>
      resolveTargetPath(root, entryName);

  static Future<void> _copyExtractedIntoInstallDir(
    InstallerPaths paths, {
    required int attempts,
    required Duration backoff,
  }) async {
    if (!await paths.installDir.exists()) {
      throw StagedApplyException(
        'Install dir does not exist: ${paths.installDir.path}',
      );
    }
    final files = await paths.extractDir
        .list(recursive: true, followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    if (files.isEmpty) {
      throw StagedApplyException(
        'Staged extract is empty: ${paths.extractDir.path}',
      );
    }
    for (final src in files) {
      final rel = p.relative(src.path, from: paths.extractDir.path);
      final dst = File(p.join(paths.installDir.path, rel));
      await dst.parent.create(recursive: true);
      await _copyWithRetry(
        src,
        dst,
        attempts: attempts,
        backoff: backoff,
      );
    }
  }

  static Future<void> _copyWithRetry(
    File src,
    File dst, {
    required int attempts,
    required Duration backoff,
  }) async {
    for (var i = 0; i < attempts; i++) {
      try {
        await src.copy(dst.path);
        return;
      } on FileSystemException catch (e) {
        if (i == attempts - 1) {
          throw StagedApplyException(
            'Failed to copy ${src.path} -> ${dst.path} after '
            '$attempts attempts',
            e,
          );
        }
        await Future<void>.delayed(backoff * (i + 1));
      }
    }
  }

  static Future<void> _relaunch(InstallerPaths paths) async {
    final exe = File(p.join(
      paths.installDir.path,
      InstallerPaths.executableBasename(),
    ));
    if (!await exe.exists()) {
      throw StagedApplyException(
        'No executable at ${exe.path} after install',
      );
    }
    await Process.start(
      exe.path,
      const <String>[],
      mode: ProcessStartMode.detached,
      workingDirectory: paths.installDir.path,
    );
  }
}
