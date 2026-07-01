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
}
