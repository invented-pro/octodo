// Tests for `distribution.dart` — pure resolver logic; the Win32
// package-identity probe is injected so the suite is deterministic
// and platform-agnostic (no real `kernel32.dll` lookup).

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/update/distribution.dart';

void main() {
  group('resolveInstallDistribution', () {
    test('override wins over every other signal', () {
      final result = resolveInstallDistribution(
        override: InstallDistribution.portable,
        resolvedExecutable: r'C:\Program Files\WindowsApps\foo\octodo.exe',
        probe: () => '43D421A8.Octodo_1.0.13.0_x64__mr0as8erd2vmy',
      );
      expect(result, InstallDistribution.portable);
    });

    test('store when probe returns this app package full name', () {
      final result = resolveInstallDistribution(
        resolvedExecutable: r'C:\arbitrary\octodo.exe',
        probe: () => '43D421A8.Octodo_1.0.13.0_x64__mr0as8erd2vmy',
      );
      expect(result, InstallDistribution.store);
    });

    test('portable when probe returns null (no package identity)', () {
      final result = resolveInstallDistribution(
        resolvedExecutable: r'C:\Users\me\Octodo\octodo.exe',
        probe: () => null,
      );
      expect(result, InstallDistribution.portable);
    });

    test('portable when probe returns an unrelated package', () {
      // A different MSIX on the machine must not mis-route us —
      // we only trust names that start with this app's identity.
      final result = resolveInstallDistribution(
        resolvedExecutable: r'C:\Users\me\Octodo\octodo.exe',
        probe: () => 'SomeOther.App_1.0.0.0_x64__abcdefghij',
      );
      expect(result, InstallDistribution.portable);
    });

    test('portable when probe returns empty string', () {
      final result = resolveInstallDistribution(
        resolvedExecutable: r'C:\Users\me\Octodo\octodo.exe',
        probe: () => '',
      );
      expect(result, InstallDistribution.portable);
    });

    test('path heuristic → store when exe lives under WindowsApps', () {
      final result = resolveInstallDistribution(
        resolvedExecutable:
            r'C:\Program Files\WindowsApps\43D421A8.Octodo_1.0.13.0_x64__mr0as8erd2vmy\octodo.exe',
        probe: () => null,
      );
      expect(result, InstallDistribution.store);
    });

    test('path heuristic is case-insensitive on the WindowsApps segment', () {
      final result = resolveInstallDistribution(
        resolvedExecutable:
            r'c:\program files\WINDOWSAPPS\43D421A8.Octodo_1.0.13.0_x64__mr0as8erd2vmy\octodo.exe',
        probe: () => null,
      );
      expect(result, InstallDistribution.store);
    });

    test('probe signal beats the path heuristic (both agree anyway)', () {
      final result = resolveInstallDistribution(
        resolvedExecutable:
            r'C:\Program Files\WindowsApps\43D421A8.Octodo_1.0.13.0_x64__mr0as8erd2vmy\octodo.exe',
        probe: () => '43D421A8.Octodo_1.0.13.0_x64__mr0as8erd2vmy',
      );
      expect(result, InstallDistribution.store);
    });

    group('macOS MAS receipt heuristic', () {
      const bundleExe = '/Applications/Octodo.app/Contents/MacOS/Octodo';

      test('store when the bundle carries an MAS receipt', () {
        final result = resolveInstallDistribution(
          resolvedExecutable: bundleExe,
          probe: () => null,
          masReceiptExists: (path) => path.endsWith('_MASReceipt/receipt'),
        );
        expect(result, InstallDistribution.store);
      });

      test('portable when the bundle has no receipt', () {
        final result = resolveInstallDistribution(
          resolvedExecutable: bundleExe,
          probe: () => null,
          masReceiptExists: (_) => false,
        );
        expect(result, InstallDistribution.portable);
      });

      test('receipt probe only consulted for paths inside a bundle', () {
        var probed = false;
        final result = resolveInstallDistribution(
          resolvedExecutable: '/opt/octodo/bin/octodo',
          probe: () => null,
          masReceiptExists: (_) {
            probed = true;
            return true;
          },
        );
        expect(result, InstallDistribution.portable);
        expect(probed, isFalse,
            reason: 'non-bundle executables never carry a receipt');
      });

      test('receipt path is built inside the detected bundle root', () {
        late String seen;
        resolveInstallDistribution(
          resolvedExecutable: bundleExe,
          probe: () => null,
          masReceiptExists: (path) {
            seen = path;
            return false;
          },
        );
        expect(seen, '/Applications/Octodo.app/Contents/_MASReceipt/receipt');
      });

      test('nested .app-looking filenames do not confuse the walk', () {
        // A directory named like a bundle *below* the executable
        // must not be picked as the root — we walk UP only.
        final result = resolveInstallDistribution(
          resolvedExecutable:
              '/Users/me/applications/Octodo.app-dmg/Octodo.app/Contents/MacOS/Octodo',
          probe: () => null,
          masReceiptExists: (_) => false,
        );
        expect(result, InstallDistribution.portable);
      });
    });

    group('macAppBundleRoot', () {
      test('resolves the innermost .app ancestor', () {
        expect(
          macAppBundleRoot('/Applications/Octodo.app/Contents/MacOS/Octodo'),
          '/Applications/Octodo.app',
        );
      });

      test('null for non-bundle paths', () {
        expect(macAppBundleRoot('/opt/octodo/octodo'), isNull);
        expect(macAppBundleRoot('/usr/local/bin/dart'), isNull);
      });

      test('null for a bare .app path itself', () {
        // The executable can't BE the bundle dir; dirname is
        // Contents/MacOS — walking up from there must find the
        // bundle only when one truly encloses it.
        expect(macAppBundleRoot('/Applications/Octodo.app'), isNull);
      });
    });
  });

  group('appImageFromEnvironment', () {
    test('returns the value when APPIMAGE is set non-empty', () {
      expect(
        appImageFromEnvironment(
            const <String, String>{'APPIMAGE': '/home/u/Octodo.AppImage'}),
        '/home/u/Octodo.AppImage',
      );
    });

    test('returns null when APPIMAGE is absent', () {
      expect(appImageFromEnvironment(const <String, String>{}), isNull);
    });

    test('returns null when APPIMAGE is empty', () {
      expect(
        appImageFromEnvironment(const <String, String>{'APPIMAGE': ''}),
        isNull,
      );
    });

    test('ignores the sibling AppImage-runtime variables', () {
      // APPDIR/OWNS exist in every AppImage process; only APPIMAGE
      // carries the file path the apply step swaps.
      expect(
        appImageFromEnvironment(const <String, String>{
          'APPDIR': '/tmp/mount',
          'OWNS': 'yes',
        }),
        isNull,
      );
    });
  });
}
