// Tests for `install_paths.dart` — pure path resolution; no I/O.
// Compares via endsWith / contains to dodge the Windows/Posix path
// separator question; the substring of path components is what we
// care about.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:octodo/src/update/installer/install_paths.dart';

void main() {
  group('InstallerPaths.fromVersion', () {
    test('derives install dir as dirname of the resolved executable', () {
      final paths = InstallerPaths.fromVersion(
        version: '1.2.3',
        resolvedExecutable: '/opt/Octodo/octodo',
        overrideLocalAppData: Directory('/tmp'),
      );

      // Cross-platform: the installDir ends with the parent
      // directory of the exe, regardless of separator.
      expect(p.basename(paths.installDir.path), 'Octodo');
    });

    test('builds expected staging+zip+extract structure', () {
      final paths = InstallerPaths.fromVersion(
        version: '1.2.3',
        resolvedExecutable: '/opt/Octodo/octodo',
        overrideLocalAppData: Directory('/tmp/loc'),
      );

      // Staging: <override>/updates/<version>/
      expect(paths.stagingDir.path, endsWith(p.join('updates', '1.2.3')));

      // Zip: <staging>/octodo-v<version>-windows-x64.zip
      expect(paths.zipFile.path,
          endsWith('octodo-v1.2.3-windows-x64.zip'));
      expect(p.isWithin(paths.stagingDir.path, paths.zipFile.path), isTrue);

      // Extract: <staging>/extracted/
      expect(paths.extractDir.path, endsWith('extracted'));
      expect(
          p.isWithin(paths.stagingDir.path, paths.extractDir.path), isTrue);
    });

    test('sanitizes version tokens that include unsafe characters', () {
      // Versions shouldn't normally have these, but the resolver is
      // called from outside the strict semver gate, so be defensive.
      final paths = InstallerPaths.fromVersion(
        version: '1.2.3/../escape',
        resolvedExecutable: '/opt/Octodo/octodo',
        overrideLocalAppData: Directory('/tmp'),
      );

      // The unsafe characters are replaced by `_` rather than
      // preserved verbatim — so we never see a "/.." sequence in
      // the final path.
      expect(
        paths.stagingDir.path,
        isNot(contains('/..')),
      );
      expect(
        paths.stagingDir.path,
        isNot(contains(r'\..')),
      );
      expect(
        paths.zipFile.path,
        isNot(contains('/..')),
      );
    });

    test('executableBasename returns the platform-appropriate name', () {
      if (Platform.isWindows) {
        expect(InstallerPaths.executableBasename(), 'octodo.exe');
      } else {
        expect(InstallerPaths.executableBasename(), 'octodo');
      }
    });
  });
}
