// Self-apply: extract the staged payload and replace the current
// install with it.
//
// Production apply paths:
//   * Windows — this file, driven by the standalone
//     octodo_helper.exe (per-file copy).
//   * macOS — the /bin/sh orchestrator in posix_apply_script.dart
//     (bundle swap via ditto + mv + open). The Dart bundleSwap
//     below is kept as the legacy/compatibility path for older
//     installed builds that still spawn their bundled
//     octodo_helper; a `dart compile exe` binary under Hardened
//     Runtime gets killed by the kernel's W^X enforcement, which
//     is why production moved off it.
//
// Triggered by the helper process — `apply_main.dart` calls
// [StagedApply.run] with paths read out of env vars. The original
// process has already exited (or is exiting) by the time we run.
//
// Two apply strategies share this entry point (see
// [ApplyStrategy] in install_paths.dart):
//
//   * perFileCopy (Windows portable layout) — extract the zip and
//     copy every file over the install dir, with per-file retry +
//     rename-aside fallbacks for Windows loader locks.
//
//   * bundleSwap (macOS .app layout) — extract the zip (recreating
//     framework symlinks and exec bits), then swap the whole
//     `Octodo.app` bundle into place with two renames: old bundle
//     aside, new bundle into its name, best-effort aside cleanup.
//     POSIX never write-locks a running binary, so no per-file
//     dance is needed; the rename-aside keeps the window without a
//     valid bundle at the target path to a single rename.
//
// Defence-in-depth checks before any file is written:
//   * Zip entry paths are normalized and bounds-checked against the
//     staging extract dir. Any path that resolves outside it
//     (a classic "zip slip" payload) throws and aborts.
//   * Symlinks within the zip are recreated only on POSIX, only
//     with targets that resolve inside the extract root, and only
//     as relative links (macOS framework layouts —
//     `Versions/Current -> A` etc. — never need more). On Windows
//     they are skipped (Flutter Windows builds contain none).
//   * Executable bits from the zip's unix mode are restored on
//     POSIX (`ditto`-created zips carry them); a failed chmod on a
//     +x entry is fatal so a broken payload never replaces a
//     working install silently.
//   * Files we copy into the install dir are basename-checked
//     against the expected octodo.exe / DLL layout — defending
//     against a malicious zip that drops a `..` ladder into
//     neighbouring dirs.
//
// Windows file locks while the original process is still alive can
// make overwrite retries necessary. We use bounded backoff.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'apply_main.dart';
import 'crash_sentinel.dart';
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
  /// file locks will be caught by the per-file retry loop, and on
  /// POSIX an still-alive original doesn't lock anything anyway.
  ///
  /// [appExecutableName] names the GUI binary inside a swapped-in
  /// macOS bundle (`Octodo.app/Contents/MacOS/<name>`). The
  /// controller passes the basename of the *original* app's
  /// executable because the helper's own `resolvedExecutable`
  /// basename is `octodo_helper`, not the app binary name. Only
  /// used by the bundleSwap strategy.
  static Future<void> run({
    required InstallerPaths paths,
    required int pidToIgnore,
    String? appExecutableName,
    Duration initialDelay =
        const Duration(milliseconds: 2500),
    Duration pidPollInterval = const Duration(milliseconds: 250),
    Duration pidTimeout = const Duration(seconds: 8),
    int overwriteAttempts = 6,
    Duration overwriteBackoff = const Duration(milliseconds: 500),
    bool relaunchAfter = true,
  }) async {
    try {
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

      if (paths.applyStrategy == ApplyStrategy.bundleSwap) {
        await _applyBundleSwap(
          paths,
          relaunchAfter: relaunchAfter,
          appExecutableName: appExecutableName,
        );
      } else {
        await _copyExtractedIntoInstallDir(
          paths,
          attempts: overwriteAttempts,
          backoff: overwriteBackoff,
        );

        if (relaunchAfter) {
          await _relaunch(paths);
        }
      }
    } catch (e) {
      // Best-effort forensic signal. We're either about to throw
      // (top-level `run` exception) or — more worrying — we made
      // it partway through the apply, in which case the install is
      // in an inconsistent state (per-file layout: some payload
      // files replaced; bundle layout: restored to the old bundle
      // by the rollback in _applyBundleSwap). Either way the
      // caller can't observe logs in release/profile builds.
      await writeHelperCrashSentinel(
        'StagedApply.run failed mid-flight for ${paths.stagingDir.path}: '
        '${e.runtimeType}: $e',
      );
      rethrow;
    }
  }

  /// Wait until [pid] is no longer alive. Windows polls via
  /// `tasklist`; POSIX probes with signal 0 (`kill -0`), which the
  /// kernel answers with success for a live PID and ESRCH for a
  /// dead one. A permission error on a live foreign-owned PID is
  /// indistinguishable from "dead" — acceptable, because POSIX
  //  never locks install files, so proceeding early is harmless.
  static Future<void> _awaitProcessExit(
    int pid, {
    required Duration initialDelay,
    required Duration pollInterval,
    required Duration timeout,
  }) async {
    await Future<void>.delayed(initialDelay);

    if (pid <= 0) return;
    final deadline = DateTime.now().add(timeout);
    if (Platform.isWindows) {
      while (DateTime.now().isBefore(deadline)) {
        final alive = await _windowsPidAlive(pid);
        if (!alive) return;
        await Future<void>.delayed(pollInterval);
      }
      return;
    }
    while (DateTime.now().isBefore(deadline)) {
      if (!_posixPidAlive(pid)) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Test-only hook: drives [_awaitProcessExit] so the POSIX
  /// signal-0 poll can be exercised on any host.
  @visibleForTesting
  static Future<void> awaitProcessExitForTest(
    int pid, {
    Duration initialDelay = Duration.zero,
    Duration pollInterval = const Duration(milliseconds: 10),
    Duration timeout = const Duration(seconds: 2),
  }) =>
      _awaitProcessExit(
        pid,
        initialDelay: initialDelay,
        pollInterval: pollInterval,
        timeout: timeout,
      );

  /// Signal-0 liveness probe via POSIX `kill(2)`: returns 0 iff
  /// [pid] exists (and is signalable by us), -1 otherwise. We
  /// can't distinguish ESRCH (dead) from EPERM (alive, foreign
  /// owner) without errno — treating both as "dead" is fine here
  /// because POSIX never write-locks install files, so proceeding
  /// early is harmless.
  static bool _posixPidAlive(int pid) {
    try {
      final kill = DynamicLibrary.process().lookupFunction<
          Int32 Function(Int32, Int32),
          int Function(int, int)>('kill');
      return kill(pid, 0) == 0;
    } catch (_) {
      // FFI unavailable (shouldn't happen on a POSIX host) —
      // optimistically report dead so the bounded wait ends.
      return false;
    }
  }

  static Future<bool> _windowsPidAlive(int pid) async {
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
    await _extractArchive(archive, paths.extractDir);
  }

  /// Test-only hook: drives the extraction core with a
  /// hand-constructed [Archive] so symlink / exec-bit behavior can
  /// be asserted without shelling out to `ditto`.
  @visibleForTesting
  static Future<void> extractArchiveForTest(Archive archive, Directory target) =>
      _extractArchive(archive, target);

  static Future<void> _extractArchive(Archive archive, Directory target) async {
    for (final entry in archive) {
      final name = entry.name;
      if (entry.isSymbolicLink) {
        // Validate on EVERY platform — a hostile link (absolute /
        // escaping target) is a malformed payload even where we
        // skip creation below.
        _validateSymlinkPayload(target, name, entry.nameOfLinkedFile);
        // POSIX: recreate the link (ditto zips from the macOS
        // release workflow carry framework-layout symlinks like
        // `Versions/Current -> A`). Windows: skip — Flutter
        // Windows builds contain no symlinks and NTFS symlink
        // creation needs privileges we don't want to require.
        if (!Platform.isWindows) {
          await _createSymlink(target, name, entry.nameOfLinkedFile);
        }
        continue;
      }
      if (!entry.isFile) {
        // Skip directories and (best-effort) any other
        // non-regular entries.
        continue;
      }
      final destination = resolveTargetPath(target.path, name);
      await destination.parent.create(recursive: true);
      final content = entry.content as List<int>;
      await File(destination.path).writeAsBytes(
        content,
        flush: false,
      );
      // Restore the executable bit on POSIX. `writeAsBytes` yields
      // mode 0644; the ditto zip carries the real unix mode and
      // the relaunched binary (plus framework dylibs) need +x.
      if (!Platform.isWindows && (entry.unixPermissions & 0x49) != 0) {
        await _chmodExec(destination.path);
      }
    }
  }

  /// Validate a zip symlink entry against the extract-root
  /// contract: relative targets only, resolving inside [root].
  /// Real .app bundles only ever contain relative, inside-bundle
  /// links (`Versions/Current`, `Resources -> Versions/Current/
  /// Resources`), so anything else is treated as a hostile
  /// payload. Runs on every platform — Windows skips link
  /// creation but must still refuse a malformed payload.
  static void _validateSymlinkPayload(
    Directory root,
    String linkName,
    String linkTarget,
  ) {
    if (p.isAbsolute(linkTarget)) {
      throw StagedApplyException(
        'Refusing absolute symlink target: $linkName -> $linkTarget',
      );
    }
    final linkPath = resolveTargetPath(root.path, linkName).path;
    final resolvedTarget = p.normalize(
      p.join(p.dirname(linkPath), linkTarget),
    );
    if (!p.isWithin(p.normalize(root.path), resolvedTarget)) {
      throw StagedApplyException(
        'Refusing symlink that escapes extract root: '
        '$linkName -> $linkTarget',
      );
    }
  }

  /// Recreate the validated relative symlink [linkName] ->
  /// [linkTarget] under [root]. Callers must run
  /// [_validateSymlinkPayload] first.
  static Future<void> _createSymlink(
    Directory root,
    String linkName,
    String linkTarget,
  ) async {
    final linkPath = resolveTargetPath(root.path, linkName).path;
    final link = Link(linkPath);
    if (await link.exists()) {
      await link.delete();
    }
    // The link's parent directory may not exist yet — zip entry
    // order is not top-down (ditto interleaves files and links),
    // and a plain file entry elsewhere under the same ancestor is
    // what usually materializes it.
    await link.parent.create(recursive: true);
    await link.create(linkTarget, recursive: false);
  }

  /// Set the owner-executable bits on [path]. Fatal on failure:
  /// a payload whose binaries can't be made executable would
  /// produce an app that relaunches into nothing.
  static Future<void> _chmodExec(String path) async {
    final result = await Process.run('chmod', ['+x', path]);
    if (result.exitCode != 0) {
      throw StagedApplyException(
        'chmod +x failed for $path (exit ${result.exitCode})',
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

  // ------------------------------------------------------------------
  // macOS bundle swap
  // ------------------------------------------------------------------

  /// Swap the freshly extracted `.app` bundle into the running
  /// bundle's location:
  ///
  ///   1. strip quarantine-ish xattrs from the new bundle (bytes
  ///      downloaded in-app never get one, but a user-forwarded
  ///      zip could; belt-and-braces against Gatekeeper EPERM at
  ///      relaunch),
  ///   2. sweep stale `<bundle>.old-*` asides from earlier runs,
  ///   3. rename the old bundle aside,
  ///   4. rename (or, cross-volume, recursively copy — preserving
  ///      symlinks + exec bits) the new bundle into the old name,
  ///      restoring the aside on failure,
  ///   5. relaunch the new binary with the helper env vars cleared,
  ///   6. best-effort delete of the aside (POSIX keeps the running
  ///      helper alive over its own unlinked image).
  static Future<void> _applyBundleSwap(
    InstallerPaths paths, {
    required bool relaunchAfter,
    String? appExecutableName,
  }) async {
    final current = paths.appBundleRoot;
    if (current == null) {
      throw StagedApplyException(
        'bundleSwap strategy selected but appBundleRoot is null',
      );
    }
    final newBundle = await _findSingleAppBundle(paths.extractDir);

    if (Platform.isMacOS) {
      await _runBestEffort('xattr', ['-cr', newBundle.path]);
    }

    await _sweepStaleAsides(current);

    final asidePath =
        '${current.path}.old-${DateTime.now().millisecondsSinceEpoch}';
    try {
      await current.rename(asidePath);
    } catch (e) {
      throw StagedApplyException(
        'Could not set aside running bundle ${current.path}: $e',
        e,
      );
    }

    try {
      try {
        await newBundle.rename(current.path);
      } on FileSystemException {
        // Cross-device (staging on another volume): fall back to a
        // recursive copy that recreates symlinks and exec bits —
        // File.copy alone would materialize link targets as plain
        // files and drop +x, producing a broken bundle.
        try {
          await _copyBundleRecursive(newBundle, Directory(current.path));
        } catch (e) {
          // Drop the partial copy so the restore below starts from
          // a clean slate.
          try {
            if (await Directory(current.path).exists()) {
              await Directory(current.path).delete(recursive: true);
            }
          } catch (_) {}
          rethrow;
        }
      }
    } catch (e) {
      // Restore the old bundle at its canonical name; the failed
      // swap propagates to the caller via the rethrow.
      try {
        await Directory(asidePath).rename(current.path);
      } catch (_) {}
      throw StagedApplyException(
        'Could not move new bundle ${newBundle.path} into place at '
        '${current.path}: $e',
        e,
      );
    }

    if (relaunchAfter) {
      final exeName =
          appExecutableName ?? p.basename(Platform.resolvedExecutable);
      final exe = File(p.join(current.path, 'Contents', 'MacOS', exeName));
      if (!await exe.exists()) {
        throw StagedApplyException(
          'No executable at ${exe.path} after bundle swap',
        );
      }
      await _relaunchAppBundle(current.path);
    }

    // Best-effort: delete the aside. Our own helper image lives in
    // it, but POSIX keeps a running process's pages alive over an
    // unlinked file — this is expected to succeed on macOS. If it
    // fails (foreign-owned Applications dir), the next update's
    // stale-aside sweep clears it.
    try {
      await Directory(asidePath).delete(recursive: true);
    } catch (_) {}
  }

  /// Locate the single `*.app` directory the payload zip extracted
  /// at the extract root. More than one, or none, means the zip
  /// doesn't match the bundle-swap contract — refuse rather than
  /// guess.
  static Future<Directory> _findSingleAppBundle(Directory extractDir) async {
    final apps = <Directory>[];
    await for (final entity
        in extractDir.list(followLinks: false)) {
      if (entity is Directory && p.basename(entity.path).endsWith('.app')) {
        apps.add(entity);
      }
    }
    if (apps.length != 1) {
      throw StagedApplyException(
        'Expected exactly one *.app at extract root '
        '(${extractDir.path}), found ${apps.length}',
      );
    }
    return apps.first;
  }

  /// Delete sibling `<bundle>.old-*` directories left behind by
  /// earlier swaps whose cleanup failed (e.g. the machine powered
  /// off between rename and delete). Best-effort per entry.
  static Future<void> _sweepStaleAsides(Directory bundle) async {
    final parent = Directory(p.dirname(bundle.path));
    final prefix = '${p.basename(bundle.path)}.old-';
    try {
      await for (final entity in parent.list(followLinks: false)) {
        if (entity is Directory && p.basename(entity.path).startsWith(prefix)) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {
      // Unreadable parent — nothing we can sweep; the rename below
      // will surface any real problem.
    }
  }

  /// Recursive copy that preserves the bundle invariants: relative
  /// symlinks recreated as links (bounds-checked against the
  /// destination root), file modes restored where the source
  /// carries exec bits.
  static Future<void> _copyBundleRecursive(
    Directory src,
    Directory dst,
  ) async {
    await dst.create(recursive: true);
    await for (final entity in src.list(followLinks: false)) {
      final target = p.join(dst.path, p.basename(entity.path));
      if (entity is Link) {
        final linkTarget = await entity.target();
        if (p.isAbsolute(linkTarget)) {
          throw StagedApplyException(
            'Refusing absolute symlink during copy: ${entity.path}',
          );
        }
        await Link(target).create(linkTarget);
      } else if (entity is Directory) {
        await _copyBundleRecursive(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
        final mode = (await entity.stat()).mode;
        if (!Platform.isWindows && (mode & 0x49) != 0) {
          await _chmodExec(target);
        }
      }
    }
  }

  /// Relaunch the swapped-in app bundle through Launch Services
  /// (`open`). Two reasons not to exec the bundle binary directly:
  ///
  ///   * activation semantics — LS restores the app's Dock icon,
  ///     focus, and window layering the way a user-launched app
  ///     gets them; a raw exec lands outside that flow (this is
  ///     why Sparkle et al. relaunch via LS),
  ///   * environment hygiene — BUT modern macOS `open` forwards
  ///     the *caller's* environment to the launched app, so `open`
  ///     itself must be invoked with a scrubbed environment
  ///     (verified empirically: `env -i open` → launched app sees
  ///     zero helper vars). [includeParentEnvironment] false +
  ///     a minimal PATH/HOME accomplishes the same from Dart;
  ///     the helper's `OCTODO_UPDATE_*` vars therefore cannot
  ///     reach the relaunched app.
  ///
  /// `open` returns once the launch is handed to Launch Services
  /// (not when the app exits), so this doesn't block on the app
  /// lifetime.
  static Future<void> _relaunchAppBundle(String bundlePath) async {
    final result = await Process.run(
      '/usr/bin/open',
      [bundlePath],
      includeParentEnvironment: false,
      environment: const <String, String>{
        'PATH': '/usr/bin:/bin',
        'HOME': '/',
      },
    );
    if (result.exitCode != 0) {
      throw StagedApplyException(
        'Could not relaunch $bundlePath via open '
        '(exit ${result.exitCode}): ${result.stderr}',
      );
    }
  }

  /// Test-only hook: drives [_relaunchAppBundle] against a stub
  /// bundle so the Launch Services path is exercised in tests.
  @visibleForTesting
  static Future<void> relaunchBundleForTest(String bundlePath) =>
      _relaunchAppBundle(bundlePath);

  /// Run [executable] with [args], swallowing every failure — used
  /// for best-effort hygiene steps (xattr stripping) whose failure
  /// must never abort an apply.
  static Future<void> _runBestEffort(
    String executable,
    List<String> args,
  ) async {
    try {
      await Process.run(executable, args);
    } catch (_) {}
  }

  // ------------------------------------------------------------------
  // Windows per-file copy
  // ------------------------------------------------------------------

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
    final runningExe = Platform.resolvedExecutable;
    for (final src in files) {
      final rel = p.relative(src.path, from: paths.extractDir.path);
      final dst = File(p.join(paths.installDir.path, rel));
      await dst.parent.create(recursive: true);
      if (_isRunningImage(dst, runningExe)) {
        // The standalone helper exe is locked by Windows while it
        // runs (the loader maps it without FILE_SHARE_WRITE), so a
        // plain File.copy fails with ERROR_SHARING_VIOLATION on every
        // retry and would abort the whole apply before [_relaunch].
        // Route it through a rename-aside instead — see
        // [_replaceRunningImage].
        await _replaceRunningImage(
          src,
          dst,
          attempts: attempts,
          backoff: backoff,
        );
      } else {
        await _installFile(src, dst, attempts: attempts, backoff: backoff);
      }
    }
  }

  /// Copy [src] to [dst], falling back to a rename-aside when a
  /// plain copy is denied.
  ///
  /// [_copyWithRetry] recovers from *transient* locks (antivirus
  /// briefly scanning a just-written file, the original process's
  /// handles not fully released yet). It cannot beat a *held* lock:
  /// if the user re-launched `octodo.exe` while the helper is still
  /// copying, the loader maps the exe and its plugin DLLs with
  /// `FILE_SHARE_READ | FILE_SHARE_DELETE` and no `WRITE`, so
  /// `File.copy` (which needs `GENERIC_WRITE`) fails on every retry
  /// for the lifetime of that process.
  ///
  /// The fallback is [_replaceRunningImage]: rename the locked
  /// destination aside — NTFS permits this because the loader grants
  /// `FILE_SHARE_DELETE` — and drop the fresh payload into the freed
  /// name. Restore-on-failure is built in, so the install dir keeps a
  /// valid file at [dst]'s name even if the fresh copy also fails.
  /// This is the same mechanism already used for the helper's own
  /// image, generalised to any file the user's relaunch re-locked
  /// mid-apply. Without it, a single locked file aborts the apply
  /// partway, leaving the install dir half-updated (new `data/`, old
  /// `octodo.exe`) and skipping [_relaunch] — the exact regression
  /// where the app "won't restart" yet "still prompts to update".
  static Future<void> _installFile(
    File src,
    File dst, {
    required int attempts,
    required Duration backoff,
  }) async {
    try {
      await _copyWithRetry(src, dst, attempts: attempts, backoff: backoff);
    } on StagedApplyException {
      await _replaceRunningImage(
        src,
        dst,
        attempts: attempts,
        backoff: backoff,
      );
    }
  }

  /// Test-only hook: drives [_installFile] with regular (non-locked)
  /// files so the fast-path / fallback decision can be exercised
  /// deterministically. Windows' sharing restriction only affects
  /// the direct-copy step, which the rename-aside fallback avoids.
  @visibleForTesting
  static Future<void> installFileForTest(
    File src,
    File dst, {
    int attempts = 6,
    Duration backoff = const Duration(milliseconds: 500),
  }) =>
      _installFile(src, dst, attempts: attempts, backoff: backoff);

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

  /// True when [dst] refers to the file this process is executing
  /// from — i.e. the standalone helper's own image. A plain
  /// [File.copy] over it fails because Windows holds the running exe
  /// write-locked; the copy loop routes such a file through
  /// [_replaceRunningImage] instead. [FileSystemEntity.identicalSync]
  /// resolves symlinks, casing, and 8.3 short-name aliases so the
  /// match is robust against the install dir's on-disk form. A
  /// missing [dst] (a brand-new payload file) throws and we return
  /// false, letting the normal copy path handle it.
  static bool _isRunningImage(File dst, String runningExe) {
    try {
      return FileSystemEntity.identicalSync(dst.path, runningExe);
    } catch (_) {
      return false;
    }
  }

  /// Replace the currently-executing image at [dst] with [src].
  ///
  /// A direct copy is impossible: Windows maps the running exe
  /// without FILE_SHARE_WRITE, so [File.copy] returns
  /// ERROR_SHARING_VIOLATION on every retry. Instead we rename the
  /// locked image aside (a same-volume rename updates only the
  /// directory entry, which NTFS permits even on a mapped file), drop
  /// the fresh payload into the freed name, then best-effort delete
  /// the aside.
  ///
  /// This is the only way to update the helper exe while it is the
  /// one performing the update. Without it, the copy loop throws at
  /// `octodo_helper.exe` and [_relaunch] never runs — so the freshly
  /// installed app is never auto-started, exactly the regression this
  /// method exists to prevent.
  ///
  /// Restore-on-failure: if the fresh copy fails we move the aside
  /// back to [dst]'s name so the install dir is not left without a
  /// helper exe at its canonical path.
  static Future<void> _replaceRunningImage(
    File src,
    File dst, {
    required int attempts,
    required Duration backoff,
  }) async {
    final aside = File('${dst.path}.old');
    // Sweep a stale aside left by a previous run. By the time we get
    // here that run's helper has exited, so the image section is gone
    // and the delete succeeds; if it is somehow still locked we let
    // the rename below surface the error rather than masking it.
    if (await aside.exists()) {
      try {
        await aside.delete();
      } catch (_) {
        // Non-fatal; the rename will fail with a clear error if the
        // aside is genuinely unreachable.
      }
    }
    try {
      await dst.rename(aside.path);
    } catch (e) {
      throw StagedApplyException(
        'Could not set aside running image ${dst.path} '
        'for replacement: $e',
        e,
      );
    }
    try {
      await _copyWithRetry(src, dst, attempts: attempts, backoff: backoff);
    } catch (e) {
      // Put the original back so the install dir still has the file
      // at its canonical name; the failed payload copy propagates to
      // the caller via the rethrow. Drop any partial destination
      // first — a rename won't replace an existing file, so without
      // this an I/O error mid-copy (disk full, etc.) would leave a
      // truncated helper at the canonical name while the good
      // original sat unused at .old.
      try {
        if (await dst.exists()) await dst.delete();
      } catch (_) {}
      try {
        await aside.rename(dst.path);
      } catch (_) {}
      rethrow;
    }
    // Best-effort cleanup of the old image. This commonly fails
    // because we are still running from it; the stale-aside sweep at
    // the top of the next update run clears it once this process has
    // exited.
    try {
      await aside.delete();
    } catch (_) {
      // Expected while the image is mapped; leave for the next run.
    }
  }

  /// Test-only hook: drives [_replaceRunningImage] with regular
  /// (non-locked) files so the rename-aside + copy + cleanup logic
  /// can be exercised deterministically. The locked-file behaviour
  /// itself is identical — Windows' sharing restriction only affects
  /// the direct-copy step, which we never perform here.
  @visibleForTesting
  static Future<void> replaceRunningImageForTest(
    File src,
    File dst, {
    int attempts = 6,
    Duration backoff = const Duration(milliseconds: 500),
  }) =>
      _replaceRunningImage(src, dst, attempts: attempts, backoff: backoff);

  /// Test-only hook: drives [_relaunch] with a custom exe path.
  /// Production callers leave [exePathForTest] null and the helper
  /// resolves `octodo.exe` next to the install dir as usual. Tests
  /// inject a stub binary that records its environment, so we can
  /// assert the helper env vars are cleared (regression for the
  /// "new exe re-enters helper mode and the chain recurses"
  /// bug fixed in this file). Returns the spawned [Process] so the
  /// test can read back its [Process.pid] and locate its output.
  @visibleForTesting
  static Future<Process> relaunchForTest(
    InstallerPaths paths, {
    required String exePathForTest,
  }) =>
      _relaunch(paths, exePathForTest: exePathForTest);

  static Future<Process> _relaunch(
    InstallerPaths paths, {
    String? exePathForTest,
  }) async {
    final exe = File(exePathForTest ?? p.join(
      paths.installDir.path,
      InstallerPaths.executableBasename(),
    ));
    if (!await exe.exists()) {
      throw StagedApplyException(
        'No executable at ${exe.path} after install',
      );
    }
    return _startRelaunchedProcess(
      exe.path,
      workingDirectory: paths.installDir.path,
    );
  }

  /// Spawn the freshly-applied executable detached, with the helper
  /// env vars explicitly blanked. Shared by the Windows per-file
  /// relaunch and the macOS bundle-swap relaunch — the env scrub is
  /// what stops the relaunched app from re-entering helper mode at
  /// the top of `main()`.
  static Future<Process> _startRelaunchedProcess(
    String exePath, {
    required String workingDirectory,
  }) async {
    final proc = await Process.start(
      exePath,
      const <String>[],
      // Clear the helper env vars so the newly-spawned exe does NOT
      // re-enter helper mode via the `isHelperMode` check at the
      // top of `main()`. Process.start defaults to
      // includeParentEnvironment: true, so without these overrides
      // the child inherits OCTODO_UPDATE_HELPER=1 from the helper.
      // In the legacy in-process path that routes back into
      // runUpdateHelper and the chain recurses forever (no GUI
      // window ever appears); in the current build main() exits
      // with a crash sentinel instead, but the spawn is still
      // pointless. Overriding with empty strings is enough because
      // the helper-mode predicate is
      // `Platform.environment[kHelperFlagEnv] == '1'`.
      environment: <String, String>{
        kHelperFlagEnv: '',
        kHelperPayloadEnv: '',
        kHelperPidEnv: '',
        kHelperAppExeEnv: '',
      },
      mode: ProcessStartMode.detached,
      workingDirectory: workingDirectory,
    );
    // Detached starts are fire-and-forget, so we can't observe the
    // exit synchronously. We attach a non-blocking exit watcher
    // that only fires on *early* failures: if the freshly-replaced
    // exe dies within [_kEarlyExitWindow] (missing DLL, installer
    // hook failure, etc.) write a sentinel so the user has a
    // forensic signal — release/profile builds silence all logging,
    // so this is the only way the failure is observable. A clean
    // exit much later (user closed the app, OS-initiated shutdown,
    // etc.) is normal and must NOT pollute the sentinel log.
    final spawnedAt = DateTime.now();
    // Detached processes don't expose `exitCode` — accessing it
    // throws `Bad state: Process is detached`. The watcher below
    // is therefore unreachable for detached spawns (which is what
    // _relaunch always uses). Wrapping in try/on StateError keeps
    // the watcher available for any future non-detached caller
    // without crashing the helper when the child is detached.
    try {
      // ignore: unawaited_futures
      proc.exitCode.then((code) {
        final elapsed = DateTime.now().difference(spawnedAt);
        if (code != 0 && elapsed < _kEarlyExitWindow) {
          // ignore: unawaited_futures
          writeHelperCrashSentinel(
            'relaunched $exePath exited with code $code '
            'after ${elapsed.inMilliseconds}ms',
          );
        }
      });
    } on StateError {
      // Detached process — exitCode is unavailable; the early-exit
      // sentinel path is unreachable. This is the normal case for
      // _relaunch.
    }
    return proc;
  }
}

/// How long after spawn a non-zero exit is still treated as a
/// forensic signal of an immediate post-install failure, rather
/// than a normal user-closed app. Tuned generously — real startup
/// is well under this on any hardware the project targets — but
/// short enough that a user closing the app 30 seconds in doesn't
/// pollute the log.
const Duration _kEarlyExitWindow = Duration(seconds: 10);
