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
  });
}
