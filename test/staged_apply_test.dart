// Tests for `staged_apply.dart` — extract the staged zip and copy
// it over the install dir, with zip-slip defence.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:octodo/src/update/installer/install_paths.dart';
import 'package:octodo/src/update/installer/staged_apply.dart';

/// Writes a small zip containing two real files at root to [dir].
Future<File> _writeSyntheticZip({
  required Directory dir,
  required String zipName,
  required Map<String, String> entries,
}) async {
  await dir.create(recursive: true);
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value));
  }
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) {
    throw StateError('ZipEncoder returned null');
  }
  final f = File(p.join(dir.path, zipName));
  await f.writeAsBytes(encoded);
  return f;
}

/// Writes a single-file zip with one entry whose [entryName] has
/// `..` (used to drive the zip-slip defence path).
Future<File> _writeEscapeZip({
  required Directory dir,
  required String zipName,
  required String entryName,
  required String content,
}) async {
  await dir.create(recursive: true);
  final archive = Archive();
  archive.addFile(ArchiveFile.string(entryName, content));
  final encoded = ZipEncoder().encode(archive)!;
  final f = File(p.join(dir.path, zipName));
  await f.writeAsBytes(encoded);
  return f;
}

/// Resolves the real `dart` executable for `dart compile exe`.
///
/// Under `flutter test`, [Platform.resolvedExecutable] is the
/// `flutter_tester` host binary, not the Dart CLI — invoking it with
/// `compile exe` args hangs (flutter_tester waits on stdin and the
/// test's `setUpAll` never completes). Prefer a real `dart` on the
/// resolved path; otherwise walk up from flutter_tester to find the
/// Dart SDK bundled inside the Flutter SDK
/// (`<flutterRoot>/bin/cache/dart-sdk/bin/dart(.exe)`); last resort
/// is a bare `dart` from PATH.
Future<String> _resolveDartExecutable() async {
  final resolved = Platform.resolvedExecutable;
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  if (p.basename(resolved).toLowerCase() == exeName) {
    return resolved;
  }
  var dir = File(resolved).parent;
  for (var i = 0; i < 10 && dir.path != dir.parent.path; i++) {
    final candidate = File(p.join(dir.path, 'bin', 'cache', 'dart-sdk',
        'bin', exeName));
    if (await candidate.exists()) {
      return candidate.path;
    }
    dir = dir.parent;
  }
  return 'dart';
}

void main() {
  group('resolveTargetPath (zip-slip defence)', () {
    const root = '/staging';
    test('accepts plain filenames inside root', () {
      final f = StagedApply.resolveTargetPath(root, 'octodo.exe');
      // Use suffix match instead of full string equality — the
      // path package emits `\`-separated paths on Windows hosts,
      // so `expect(p.join('/staging', 'octodo.exe'), f.path)` is
      // not portable.
      expect(
        f.path.replaceAll('\\', '/'),
        endsWith('/staging/octodo.exe'),
      );
    });

    test('accepts nested paths inside root', () {
      final f =
          StagedApply.resolveTargetPath(root, 'data/foo/bar.txt');
      expect(
        f.path.replaceAll('\\', '/'),
        endsWith('/staging/data/foo/bar.txt'),
      );
    });

    test('rejects entries with .. segments', () {
      expect(
        () => StagedApply.resolveTargetPath(root, '../../etc/passwd'),
        throwsA(isA<StagedApplyException>()),
      );
      expect(
        () => StagedApply.resolveTargetPath(root, 'sub/../../escape'),
        throwsA(isA<StagedApplyException>()),
      );
    });
  });

  group('StagedApply.run end-to-end', () {
    late Directory workDir;
    late Directory installDir;
    late InstallerPaths paths;

    setUp(() async {
      workDir = await Directory.systemTemp.createTemp('apply_test_');
      installDir = Directory(p.join(workDir.path, 'install'))
        ..createSync();
      // Lay down a stub octodo.exe so the relaunch step has
      // something to call (we disable relaunchAfter, but the
      // check still runs on extract).
      await File(p.join(installDir.path, 'octodo.exe'))
          .writeAsBytes(<int>[0x4D, 0x5A]); // MZ stub.

      final staging = Directory(p.join(workDir.path, 'updates', '1.2.3'))
        ..createSync(recursive: true);
      final zip = await _writeSyntheticZip(
        dir: staging,
        zipName: 'octodo-v1.2.3-windows-x64.zip',
        entries: {
          'octodo.exe': 'fresh-binary-contents',
          'data/version.json': '{"v":"1.2.3"}',
        },
      );
      paths = InstallerPaths(
        installDir: installDir,
        stagingDir: staging,
        zipFile: zip,
        extractDir: Directory(p.join(staging.path, 'extracted')),
      );
    });

    tearDown(() async {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    });

    test('extracts + copies into install dir, with relaunch disabled',
        () async {
      await StagedApply.run(
        paths: paths,
        pidToIgnore: 0,
        initialDelay: Duration.zero,
        pidTimeout: const Duration(milliseconds: 100),
        overwriteAttempts: 2,
        overwriteBackoff: const Duration(milliseconds: 50),
        relaunchAfter: false,
      );

      final newExe = File(p.join(installDir.path, 'octodo.exe'));
      expect(newExe.existsSync(), isTrue);
      // Old MZ stub header is overwritten by synthetic contents.
      expect(await newExe.readAsString(), 'fresh-binary-contents');

      final v = File(p.join(installDir.path, 'data', 'version.json'));
      expect(v.existsSync(), isTrue);
      expect(await v.readAsString(), '{"v":"1.2.3"}');
    });

    test('throws when staged zip is missing', () async {
      await paths.zipFile.delete();
      await expectLater(
        StagedApply.run(paths: paths, pidToIgnore: 0),
        throwsA(isA<StagedApplyException>()),
      );
    });

    test('expectedDigestHex mismatch refuses before extraction (TOCTOU)',
        () async {
      // GH issue #5 item 4: the digest verified at download time
      // must still match at apply time. A swapped staged zip aborts
      // BEFORE any extraction or install-dir mutation, and the
      // install dir keeps its original contents.
      final wrong = 'ff' * 32;
      await expectLater(
        StagedApply.run(
          paths: paths,
          pidToIgnore: 0,
          expectedDigestHex: wrong,
          initialDelay: Duration.zero,
          pidTimeout: const Duration(milliseconds: 100),
          relaunchAfter: false,
        ),
        throwsA(isA<StagedApplyException>().having(
          (e) => e.message,
          'message',
          contains('digest changed'),
        )),
      );

      // Install dir untouched — the old MZ stub is still there.
      final exe = File(p.join(installDir.path, 'octodo.exe'));
      final bytes = await exe.readAsBytes();
      expect(bytes, <int>[0x4D, 0x5A]);

      // Nothing was extracted either.
      expect(paths.extractDir.existsSync(), isFalse);
    });

    test('expectedDigestHex match applies normally', () async {
      final bytes = await paths.zipFile.readAsBytes();
      final good = sha256.convert(bytes).toString();
      await StagedApply.run(
        paths: paths,
        pidToIgnore: 0,
        expectedDigestHex: good,
        initialDelay: Duration.zero,
        pidTimeout: const Duration(milliseconds: 100),
        overwriteAttempts: 2,
        overwriteBackoff: const Duration(milliseconds: 50),
        relaunchAfter: false,
      );
      final newExe = File(p.join(installDir.path, 'octodo.exe'));
      expect(await newExe.readAsString(), 'fresh-binary-contents');
    });

    test('malformed expectedDigestHex fails closed', () async {
      await expectLater(
        StagedApply.run(
          paths: paths,
          pidToIgnore: 0,
          expectedDigestHex: 'not-hex',
          initialDelay: Duration.zero,
          pidTimeout: const Duration(milliseconds: 100),
          relaunchAfter: false,
        ),
        throwsA(isA<StagedApplyException>()),
      );
      final exe = File(p.join(installDir.path, 'octodo.exe'));
      expect(await exe.readAsBytes(), <int>[0x4D, 0x5A]);
    });

    test('throws when install dir is missing', () async {
      await paths.installDir.delete(recursive: true);
      await expectLater(
        StagedApply.run(paths: paths, pidToIgnore: 0),
        throwsA(isA<StagedApplyException>()),
      );
    });

    test('refuses zip entries that escape the extract root', () async {
      await _writeEscapeZip(
        dir: paths.stagingDir,
        zipName: 'octodo-v1.2.3-windows-x64.zip',
        entryName: '../../sneaky.txt',
        content: 'haha',
      );
      await expectLater(
        StagedApply.run(paths: paths, pidToIgnore: 0),
        throwsA(isA<StagedApplyException>()),
      );

      // Install dir should be untouched (still has MZ header, not
      // been replaced by the zip's content).
      final exe = File(p.join(installDir.path, 'octodo.exe'));
      final bytes = await exe.readAsBytes();
      expect(bytes.length, 2);
      expect(bytes, <int>[0x4D, 0x5A]);

      // Defensive: the escaped entry did NOT land outside root.
      expect(File(p.join(workDir.path, 'sneaky.txt')).existsSync(), isFalse);
    });
  });

  group('_replaceRunningImage (rename-aside self-replace)', () {
    // Regression for the "files swapped but app not auto-started"
    // bug: octodo_helper.exe ships inside the update zip, and the
    // running helper cannot File.copy over its own locked image.
    // The fix renames the running image aside then copies the fresh
    // one into its place. These tests exercise that path with
    // regular (non-locked) files — Windows' sharing restriction
    // only affects the direct-copy step, which is precisely what the
    // rename-aside avoids.

    late Directory workDir;

    setUp(() async {
      workDir = await Directory.systemTemp.createTemp('replace_test_');
    });

    tearDown(() async {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    });

    test('replaces an existing image file with the fresh payload', () async {
      final dst = File(p.join(workDir.path, 'helper.exe'));
      await dst.writeAsString('OLD-IMAGE');
      final src = File(p.join(workDir.path, 'fresh.exe'));
      await src.writeAsString('NEW-IMAGE');

      await StagedApply.replaceRunningImageForTest(
        src,
        dst,
        attempts: 2,
        backoff: const Duration(milliseconds: 10),
      );

      expect(await dst.readAsString(), 'NEW-IMAGE');
      // The file is unlocked here (no process mapped from it), so the
      // best-effort aside delete succeeds and leaves nothing behind.
      expect(File('${dst.path}.old').existsSync(), isFalse);
    });

    test('leaves the original in place when the fresh copy fails', () async {
      // Source does not exist -> _copyWithRetry throws on the first
      // attempt. The rename-aside must restore the original so the
      // install dir keeps a usable helper at its canonical name.
      final dst = File(p.join(workDir.path, 'helper.exe'));
      await dst.writeAsString('OLD-IMAGE');
      final missingSrc = File(p.join(workDir.path, 'does-not-exist.exe'));

      await expectLater(
        StagedApply.replaceRunningImageForTest(
          missingSrc,
          dst,
          attempts: 2,
          backoff: const Duration(milliseconds: 10),
        ),
        throwsA(isA<StagedApplyException>()),
      );

      // Original restored byte-for-byte.
      expect(await dst.readAsString(), 'OLD-IMAGE');
      // And no dangling aside left behind by the failed run.
      expect(File('${dst.path}.old').existsSync(), isFalse);
    });
  });

  group('_installFile (copy with rename-aside fallback)', () {
    // Regression for the "won't restart / still prompts" bug: when
    // the user re-launches octodo.exe mid-apply, the loader locks the
    // exe + DLLs against WRITE, so a plain File.copy throws and used
    // to abort the apply partway. _installFile falls back to the
    // rename-aside path so the file is still swapped. These tests
    // exercise the decision with regular (non-locked) files — the
    // locked behaviour itself is identical to _replaceRunningImage.

    late Directory workDir;

    setUp(() async {
      workDir = await Directory.systemTemp.createTemp('install_file_test_');
    });

    tearDown(() async {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    });

    test('plain-copies when the destination is unlocked (fast path)',
        () async {
      final dst = File(p.join(workDir.path, 'plain.dll'));
      await dst.writeAsString('OLD');
      final src = File(p.join(workDir.path, 'fresh.bin'));
      await src.writeAsString('NEW');

      await StagedApply.installFileForTest(
        src,
        dst,
        attempts: 2,
        backoff: const Duration(milliseconds: 10),
      );

      expect(await dst.readAsString(), 'NEW');
    });

    test('falls back to rename-aside and restores dst on copy failure',
        () async {
      // A missing src makes _copyWithRetry throw StagedApplyException,
      // so _installFile delegates to _replaceRunningImage — which also
      // fails (same missing src) and restores the original. Proves the
      // fallback is taken and dst is never left missing or truncated.
      final dst = File(p.join(workDir.path, 'locked.dll'));
      await dst.writeAsString('OLD-DLL');
      final missingSrc = File(p.join(workDir.path, 'does-not-exist.bin'));

      await expectLater(
        StagedApply.installFileForTest(
          missingSrc,
          dst,
          attempts: 2,
          backoff: const Duration(milliseconds: 10),
        ),
        throwsA(isA<StagedApplyException>()),
      );

      expect(await dst.readAsString(), 'OLD-DLL');
      expect(File('${dst.path}.old').existsSync(), isFalse);
    });
  });

  group('_relaunch helper-env override (regression for recursion bug)', () {
    late Directory relayWorkDir;

    // Compiled once per test suite. `dart compile exe` takes a
    // few seconds; caching keeps the suite fast on re-runs.
    setUpAll(() async {
      final src = File('test/_support/relay_env.dart');
      final exe = File('test/_support/relay_env.exe');
      if (!exe.existsSync() ||
          exe.statSync().modified.isBefore(src.statSync().modified)) {
        final result = await Process.run(
          await _resolveDartExecutable(),
          ['compile', 'exe', src.path, '-o', exe.path],
        );
        if (result.exitCode != 0) {
          throw StateError(
            'Failed to compile relay_env.dart (exit '
            '${result.exitCode}):\n${result.stderr}',
          );
        }
      }
    });

    setUp(() async {
      relayWorkDir = await Directory.systemTemp.createTemp('relay_test_');
    });

    tearDown(() async {
      // Sweep any pid-scoped relay outputs we wrote. The basename
      // prefix `octodo_relay_` already disambiguates concurrent
      // runs of the same test by PID, so we don't need to also
      // scope by relayWorkDir — earlier code attempted that via a
      // `.contains(...)` clause that always evaluated to true
      // (`String.contains('')` is a tautology), so it was a no-op
      // in practice.
      final tmp = Directory(Directory.systemTemp.path);
      if (await tmp.exists()) {
        await for (final ent in tmp.list(followLinks: false)) {
          if (ent is File &&
              p.basename(ent.path).startsWith('octodo_relay_')) {
            try {
              await ent.delete();
            } catch (_) {}
          }
        }
      }
      if (await relayWorkDir.exists()) {
        await relayWorkDir.delete(recursive: true);
      }
    });

    test('spawned child sees helper env vars as empty (no recursion)',
        () async {
      // We don't need a real staging dir for this test — `_relaunch`
      // only reads `paths.installDir.path` (used as workingDirectory).
      final installDir =
          Directory(p.join(relayWorkDir.path, 'install'))..createSync();
      final paths = InstallerPaths(
        installDir: installDir,
        stagingDir: Directory(p.join(relayWorkDir.path, 'unused_staging')),
        zipFile: File(p.join(relayWorkDir.path, 'unused.zip')),
        extractDir: Directory(p.join(relayWorkDir.path, 'unused_extracted')),
      );

      final relayExe = File('test/_support/relay_env.exe').absolute.path;
      final proc = await StagedApply.relaunchForTest(
        paths,
        exePathForTest: relayExe,
      );

      // The relay writes its env snapshot to
      // `<systemTemp>/octodo_relay_<pid>.log` and exits. Poll until
      // it appears, then read it back.
      final outputFile = File(
        p.join(
          Directory.systemTemp.path,
          'octodo_relay_${proc.pid}.log',
        ),
      );
      var appeared = false;
      for (var i = 0; i < 50; i++) {
        if (outputFile.existsSync()) {
          appeared = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(appeared, isTrue,
          reason: 'relay did not write ${outputFile.path} within 5s');

      final snapshot = await outputFile.readAsString();
      // The helper env vars must be CLEARED. The override in
      // _relaunch sets them to '' so `isHelperMode` is false. If the
      // override is removed (or includeParentEnvironment leaks them
      // through) the snapshot would contain `OCTODO_UPDATE_HELPER=1`
      // and the new exe would re-enter helper mode at the top of
      // main(), recursing forever instead of showing the GUI window.
      expect(snapshot, contains('OCTODO_UPDATE_HELPER=\n'));
      expect(snapshot, contains('OCTODO_UPDATE_PAYLOAD=\n'));
      expect(snapshot, contains('OCTODO_UPDATE_PID=\n'));
      expect(snapshot, isNot(contains('OCTODO_UPDATE_HELPER=1')));
    });
  });

  group('_awaitProcessExit (POSIX signal-0 poll)', () {
    // Windows has its own tasklist path exercised only on Windows
    // hosts; the POSIX branch is the new code under test.
    test('returns promptly once the pid is gone', () async {
      if (Platform.isWindows) return;
      final proc = await Process.start('/bin/sleep', ['0']);
      await proc.exitCode;
      final sw = Stopwatch()..start();
      await StagedApply.awaitProcessExitForTest(
        proc.pid,
        initialDelay: Duration.zero,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 2),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('gives up after the timeout for a live pid (no throw)', () async {
      if (Platform.isWindows) return;
      final proc = await Process.start('/bin/sleep', ['30']);
      try {
        final sw = Stopwatch()..start();
        await StagedApply.awaitProcessExitForTest(
          proc.pid,
          initialDelay: Duration.zero,
          pollInterval: const Duration(milliseconds: 10),
          timeout: const Duration(milliseconds: 200),
        );
        sw.stop();
        expect(sw.elapsed, greaterThan(const Duration(milliseconds: 150)));
      } finally {
        proc.kill();
        await proc.exitCode;
      }
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('_extractArchive (symlinks + exec bits)', () {
    late Directory target;

    setUp(() async {
      target = await Directory.systemTemp.createTemp('extract_test_');
    });

    tearDown(() async {
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
    });

    ArchiveFile makeFile(String name, String content, {int mode = 0x81A4}) {
      final bytes = content.codeUnits;
      return ArchiveFile(name, bytes.length, bytes)..mode = mode;
    }

    ArchiveFile makeSymlink(String name, String linkTarget) {
      final bytes = linkTarget.codeUnits;
      return ArchiveFile(name, bytes.length, bytes)
        ..isSymbolicLink = true
        ..nameOfLinkedFile = linkTarget
        ..mode = 0xA1FF;
    }

    test('recreates relative symlinks and exec bits (POSIX)', () async {
      if (Platform.isWindows) return; // NTFS symlink needs privileges
      final archive = Archive()
        ..addFile(makeFile('Octodo.app/Contents/MacOS/Octodo', 'BIN',
            mode: 0x81ED))
        ..addFile(makeFile('Octodo.app/Contents/Frameworks/F.framework'
            '/Versions/A/F', 'FW', mode: 0x81ED))
        ..addFile(makeSymlink('Octodo.app/Contents/Frameworks/F.framework'
            '/Versions/Current', 'A'))
        ..addFile(makeSymlink('Octodo.app/Contents/Frameworks/F.framework'
            '/Resources', 'Versions/Current/Resources'));

      await StagedApply.extractArchiveForTest(archive, target);

      final root = target.path;
      final current =
          Link(p.join(root, 'Octodo.app/Contents/Frameworks/F.framework'
              '/Versions/Current'));
      expect(current.existsSync(), isTrue);
      expect(await current.target(), 'A');

      final resources = Link(p.join(
          root, 'Octodo.app/Contents/Frameworks/F.framework/Resources'));
      expect(resources.existsSync(), isTrue);
      expect(await resources.target(), 'Versions/Current/Resources');

      final bin = File(p.join(root, 'Octodo.app/Contents/MacOS/Octodo'));
      expect((await bin.stat()).mode & 0x49, isNot(0),
          reason: 'payload binaries must keep their exec bit');
      final fw = File(p.join(root,
          'Octodo.app/Contents/Frameworks/F.framework/Versions/A/F'));
      expect((await fw.stat()).mode & 0x49, isNot(0));
    });

    test('refuses absolute symlink targets', () async {
      final archive = Archive()
        ..addFile(makeSymlink('Octodo.app/evil', '/etc/passwd'));
      await expectLater(
        StagedApply.extractArchiveForTest(archive, target),
        throwsA(isA<StagedApplyException>()),
      );
    });

    test('refuses symlink targets escaping the extract root', () async {
      final archive = Archive()
        ..addFile(makeSymlink('Octodo.app/evil', '../../../etc/passwd'));
      await expectLater(
        StagedApply.extractArchiveForTest(archive, target),
        throwsA(isA<StagedApplyException>()),
      );
    });
  });

  group('StagedApply.run bundle swap (macOS layout)', () {
    // End-to-end through the real zip path: a ditto-created zip
    // (symlinks + modes preserved, Unix creator bytes) is decoded,
    // extracted, and swapped over a fake install. Tests that shell
    // out to macOS-only tools (ditto, Launch Services `open`) skip
    // on non-macOS hosts — ditto doesn't exist there, and Linux
    // aliases /usr/bin/open to xdg-open, which exits 0 without
    // launching the bundle. The archive-package-built tests below
    // run cross-platform, and the per-file path is covered above.
    late Directory workDir;
    late Directory appsDir;

    setUp(() async {
      workDir = await Directory.systemTemp.createTemp('bundle_swap_');
      appsDir = Directory(p.join(workDir.path, 'apps'))
        ..createSync();
    });

    tearDown(() async {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    });

    Future<File> buildPayloadZip(String zipName) async {
      final payloadRoot = Directory(p.join(workDir.path, 'payload'));
      final bundle = Directory(p.join(payloadRoot.path, 'Octodo.app'));
      final macosDir = Directory(p.join(bundle.path, 'Contents', 'MacOS'));
      await macosDir.create(recursive: true);
      final bin = File(p.join(macosDir.path, 'Octodo'));
      await bin.writeAsString('#!/bin/sh\necho new-bin\n');
      final helper = File(p.join(macosDir.path, 'octodo_helper'));
      await helper.writeAsString('#!/bin/sh\necho helper\n');
      // A framework-ish tree with the two canonical symlinks.
      final fw = Directory(p.join(
          bundle.path, 'Contents', 'Frameworks', 'F.framework'));
      final versionsA =
          Directory(p.join(fw.path, 'Versions', 'A', 'Resources'));
      await versionsA.create(recursive: true);
      final fwBin = File(p.join(fw.path, 'Versions', 'A', 'F'));
      await fwBin.writeAsString('#!/bin/sh\necho fw\n');
      await File(p.join(versionsA.path, 'info.txt')).writeAsString('hi');
      await Link(p.join(fw.path, 'Versions', 'Current')).create('A');
      await Link(p.join(fw.path, 'Resources'))
          .create('Versions/Current/Resources');
      // Exec bits for everything that needs them.
      for (final f in [bin, helper, fwBin]) {
        final r = await Process.run('chmod', ['+x', f.path]);
        if (r.exitCode != 0) throw StateError('chmod failed');
      }

      final staging = Directory(p.join(workDir.path, 'staging'))
        ..createSync();
      final zipPath = p.join(staging.path, zipName);
      final r = await Process.run('ditto',
          ['-c', '-k', '--sequesterRsrc', '--keepParent', bundle.path, zipPath]);
      if (r.exitCode != 0) {
        throw StateError('ditto failed: ${r.stderr}');
      }
      return File(zipPath);
    }

    Future<InstallerPaths> buildPaths(File zip) async {
      final oldBundle =
          Directory(p.join(appsDir.path, 'Octodo.app', 'Contents', 'MacOS'));
      await oldBundle.create(recursive: true);
      await File(p.join(oldBundle.path, 'Octodo'))
          .writeAsString('old-bin-contents');
      return InstallerPaths(
        installDir: appsDir,
        stagingDir: Directory(p.join(workDir.path, 'staging')),
        zipFile: zip,
        extractDir:
            Directory(p.join(workDir.path, 'staging', 'extracted')),
        applyStrategy: ApplyStrategy.bundleSwap,
        appBundleRoot: Directory(p.join(appsDir.path, 'Octodo.app')),
      );
    }

    test('swaps the bundle, restores symlinks + exec bits, cleans aside',
        () async {
      if (!Platform.isMacOS) return;
      final zip = await buildPayloadZip('octodo-v1.2.3-macos-arm64.zip');
      final paths = await buildPaths(zip);

      await StagedApply.run(
        paths: paths,
        pidToIgnore: 0,
        initialDelay: Duration.zero,
        pidTimeout: const Duration(milliseconds: 100),
        relaunchAfter: false,
      );

      final bundle = p.join(appsDir.path, 'Octodo.app');
      final bin = File(p.join(bundle, 'Contents', 'MacOS', 'Octodo'));
      expect(await bin.readAsString(), contains('new-bin'));
      expect((await bin.stat()).mode & 0x49, isNot(0));

      final current =
          Link(p.join(bundle, 'Contents', 'Frameworks', 'F.framework',
              'Versions', 'Current'));
      expect(current.existsSync(), isTrue);
      expect(await current.target(), 'A');

      final resources = Link(p.join(
          bundle, 'Contents', 'Frameworks', 'F.framework', 'Resources'));
      expect(resources.existsSync(), isTrue);

      // No rename-aside left behind.
      final entries = appsDir.listSync(followLinks: false).map(
          (e) => p.basename(e.path));
      expect(entries, equals(['Octodo.app']));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('refuses a payload without an .app at the zip root', () async {
      if (Platform.isWindows) return;
      // A zip of loose files (per-file-copy shape) hitting the
      // bundle-swap strategy must fail loudly, not guess.
      final staging = Directory(p.join(workDir.path, 'staging'))
        ..createSync();
      final archive = Archive()
        ..addFile(ArchiveFile.string('octodo.exe', 'loose'));
      final zipFile = File(p.join(staging.path, 'octodo-v1.2.3-macos-arm64.zip'));
      await zipFile.writeAsBytes(ZipEncoder().encode(archive)!);

      final paths = await buildPaths(zipFile);
      await expectLater(
        StagedApply.run(
          paths: paths,
          pidToIgnore: 0,
          initialDelay: Duration.zero,
          pidTimeout: const Duration(milliseconds: 100),
          relaunchAfter: false,
        ),
        throwsA(isA<StagedApplyException>()),
      );

      // Old bundle untouched.
      final bin = File(p.join(
          appsDir.path, 'Octodo.app', 'Contents', 'MacOS', 'Octodo'));
      expect(await bin.readAsString(), 'old-bin-contents');
      final entries = appsDir.listSync(followLinks: false).map(
          (e) => p.basename(e.path));
      expect(entries, equals(['Octodo.app']),
          reason: 'rollback must leave no aside behind');
    }, timeout: const Timeout(Duration(seconds: 30)));

    // Phase C — code-signature gate tests. Run cross-platform (the
    // gate is requirement-driven, not Platform-gated; the legacy
    // macOS path is the production target but verifying the gate
    // logic on the Windows test host keeps coverage where we have
    // working extractors and CI runs).
    group('code signature gate (Phase C)', () {
      /// Build a minimal-but-valid bundle-swap payload zip: a single
      /// `Octodo.app/Contents/MacOS/Octodo` file inside the zip.
      /// Cross-platform — uses the `archive` package, not ditto.
      Future<File> buildMinimalBundleZip() async {
        final staging = Directory(p.join(workDir.path, 'gate-staging'))
          ..createSync(recursive: true);
        final archive = Archive()
          ..addFile(ArchiveFile.string(
            'Octodo.app/Contents/MacOS/Octodo',
            'fresh-binary',
          ));
        final zipFile = File(
          p.join(staging.path, 'octodo-v1.2.3-macos-arm64.zip'),
        );
        await zipFile.writeAsBytes(ZipEncoder().encode(archive)!);
        return zipFile;
      }

      const requirement =
          'anchor apple generic and certificate leaf[subject.OU] = '
              '"P2HUSGVD3W"';

      test('null requirement → verifier never invoked, swap proceeds',
          () async {
        // Legacy callers / forks with the gate disabled: no codesign
        // process is started, the swap runs as it did before Phase C.
        final zip = await buildMinimalBundleZip();
        final paths = await buildPaths(zip);
        var calls = 0;
        await StagedApply.run(
          paths: paths,
          pidToIgnore: 0,
          initialDelay: Duration.zero,
          pidTimeout: const Duration(milliseconds: 100),
          relaunchAfter: false,
          codeSignRequirement: null,
          codeSignVerifier: (req, _) {
            calls += 1;
            return Future.value(true);
          },
        );
        expect(calls, 0);
        final bin = File(p.join(
            appsDir.path, 'Octodo.app', 'Contents', 'MacOS', 'Octodo'));
        expect(await bin.readAsString(), 'fresh-binary');
      });

      test('verifier passes → swap completes (verifier sees REQ + path)',
          () async {
        final zip = await buildMinimalBundleZip();
        final paths = await buildPaths(zip);
        String? seenReq;
        String? seenBundle;
        await StagedApply.run(
          paths: paths,
          pidToIgnore: 0,
          initialDelay: Duration.zero,
          pidTimeout: const Duration(milliseconds: 100),
          relaunchAfter: false,
          codeSignRequirement: requirement,
          codeSignVerifier: (req, bundlePath) {
            seenReq = req;
            seenBundle = bundlePath;
            return Future.value(true);
          },
        );
        expect(seenReq, requirement);
        expect(seenBundle, contains(r'Octodo.app'));
        final bin = File(p.join(
            appsDir.path, 'Octodo.app', 'Contents', 'MacOS', 'Octodo'));
        expect(await bin.readAsString(), 'fresh-binary');
      });

      test('verifier fails → fail-closed, old bundle intact', () async {
        final zip = await buildMinimalBundleZip();
        final paths = await buildPaths(zip);
        await expectLater(
          StagedApply.run(
            paths: paths,
            pidToIgnore: 0,
            initialDelay: Duration.zero,
            pidTimeout: const Duration(milliseconds: 100),
            relaunchAfter: false,
            codeSignRequirement: requirement,
            codeSignVerifier: (req, bundle) => Future.value(false),
          ),
          throwsA(isA<StagedApplyException>().having(
            (e) => e.message,
            'message',
            contains('code signature'),
          )),
        );

        // The OLD bundle's Contents/MacOS/Octodo is untouched —
        // neither renamed nor replaced.
        final bin = File(p.join(
            appsDir.path, 'Octodo.app', 'Contents', 'MacOS', 'Octodo'));
        expect(await bin.readAsString(), 'old-bin-contents');
        final entries = appsDir.listSync(followLinks: false).map(
            (e) => p.basename(e.path));
        expect(entries, equals(['Octodo.app']),
            reason: 'no aside + no swapped bundle');
      });
    });

    test('relaunches the swapped bundle via Launch Services (open)',
        () async {
      if (!Platform.isMacOS) return;
      // A stub .app whose "binary" is a shell script that drops
      // marker files. relaunchBundleForTest must hand the bundle to
      // Launch Services with a scrubbed environment — modern macOS
      // `open` forwards the CALLER's env to the launched app, so
      // the scrub (includeParentEnvironment: false) is what keeps
      // the helper's OCTODO_UPDATE_* vars out of the relaunched
      // process (the polluted-caller case is additionally covered
      // by an `env -i open` shell check at implementation time).
      final stub = Directory(p.join(workDir.path, 'Stub.app'));
      final macosDir = Directory(p.join(stub.path, 'Contents', 'MacOS'));
      await macosDir.create(recursive: true);
      final marker = File(p.join(workDir.path, 'launched.marker'));
      final envMarker = File(p.join(workDir.path, 'env.marker'));
      final script = File(p.join(macosDir.path, 'Stub'));
      await script.writeAsString('''
#!/bin/sh
echo launched > "${marker.path}"
env | grep -c '^OCTODO_UPDATE' > "${envMarker.path}" || echo 0 > "${envMarker.path}"
''');
      final r = await Process.run('chmod', ['+x', script.path]);
      if (r.exitCode != 0) throw StateError('chmod failed');
      await File(p.join(stub.path, 'Contents', 'Info.plist'))
          .writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Stub</string>
  <key>CFBundleIdentifier</key><string>com.octodo.stub</string>
  <key>CFBundleName</key><string>Stub</string>
</dict>
</plist>
''');

      await StagedApply.relaunchBundleForTest(stub.path);

      var appeared = false;
      for (var i = 0; i < 50; i++) {
        if (await marker.exists()) {
          appeared = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(appeared, isTrue,
          reason: 'stub bundle did not launch within 10 s');
      var envCount = '';
      for (var i = 0; i < 50 && envCount.isEmpty; i++) {
        if (await envMarker.exists()) {
          envCount = (await envMarker.readAsString()).trim();
        }
        if (envCount.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      expect(envCount, '0',
          reason: 'helper env vars must not leak into the LS-launched app');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
