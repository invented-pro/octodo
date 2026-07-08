// Tests for `staged_apply.dart` — extract the staged zip and copy
// it over the install dir, with zip-slip defence.

import 'dart:io';

import 'package:archive/archive.dart';
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
}
