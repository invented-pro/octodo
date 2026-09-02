// Tests for `macos_codesign.dart` — Phase C of the update trust
// hardening (GH issue #5, item 2): the macOS payload code-signature
// gate and the inheritance rule.
//
// The two production surfaces (the /bin/sh apply script, the
// legacy in-process bundleSwap path) consume the pieces tested here:
//   * the `kMacUpdateTeamId` const + `macCodeSignRequirementFor`
//     build the strings the controller forwards into argv / -R=,
//   * `resolveEnforcedCodeSignRequirement` implements the
//     inheritance rule (running bundle fails pin → gate skipped),
//   * `verifyBundleCodeSignature` is the default verifier.
//
// All Process.run / Platform.isMacOS touchpoints are injectable so
// these tests run identically on the Linux/Windows dev host and on
// CI; they don't shell out, don't touch codesign.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/update/installer/macos_codesign.dart';

void main() {
  group('macCodeSignRequirementFor', () {
    test('pins the designated requirement to the Team ID', () {
      expect(
        macCodeSignRequirementFor('P2HUSGVD3W'),
        'anchor apple generic and certificate leaf[subject.OU] = "P2HUSGVD3W"',
      );
    });

    test('default const pins the official octodo Team ID', () {
      expect(kMacUpdateTeamId, 'P2HUSGVD3W');
      expect(
        macCodeSignRequirementFor(kMacUpdateTeamId),
        macCodeSignRequirementFor('P2HUSGVD3W'),
      );
    });
  });

  group('resolveEnforcedCodeSignRequirement', () {
    // Production-shaped fake codesign invocation: the resolver calls
    // `/usr/bin/codesign --verify --deep --strict -R=<req> <bundle>`
    // against the running bundle; whatever the fake returns, the
    // resolver passes through.
    bool fakeMac() => true;
    bool fakeLinux() => false;

    test('non-macOS → null (Windows/Linux apply paths)', () async {
      var calls = 0;
      final r = await resolveEnforcedCodeSignRequirement(
        runningBundlePath: '/Applications/Octodo.app',
        platformIsMacOS: fakeLinux,
        processRunner: (exe, args) {
          calls += 1;
          return Future.value(ProcessResult(0, 0, '', ''));
        },
      );
      expect(r, isNull);
      expect(calls, 0, reason: 'codesign must not be invoked off-macOS');
    });

    test('empty teamId → null (forks disabled the gate)', () async {
      var calls = 0;
      final r = await resolveEnforcedCodeSignRequirement(
        runningBundlePath: '/Applications/Octodo.app',
        teamId: '',
        platformIsMacOS: fakeMac,
        processRunner: (exe, args) {
          calls += 1;
          return Future.value(ProcessResult(0, 0, '', ''));
        },
      );
      expect(r, isNull);
      expect(calls, 0);
    });

    test('running bundle satisfies the pin → returns the requirement',
        () async {
      ProcessResult? seen;
      final r = await resolveEnforcedCodeSignRequirement(
        runningBundlePath: '/Applications/Octodo.app',
        platformIsMacOS: fakeMac,
        processRunner: (exe, args) {
          seen = ProcessResult(0, 0, '', '');
          return Future.value(seen!);
        },
      );
      expect(r, macCodeSignRequirementFor(kMacUpdateTeamId));
      expect(seen!.exitCode, 0);
    });

    test('running bundle fails the pin (dev/ad-hoc/fork) → null', () async {
      // Dev build signed ad-hoc, or fork signed by a different Team
      // — the resolver returns null and the apply path inherits the
      // weaker posture (gate skipped) instead of refusing the update.
      final r = await resolveEnforcedCodeSignRequirement(
        runningBundlePath: '/Applications/Octodo.app',
        platformIsMacOS: fakeMac,
        processRunner: (exe, args) =>
            Future.value(ProcessResult(0, 1, '', 'invalidentifiererror')),
      );
      expect(r, isNull);
    });

    test('codesign tool missing (exception) → null, never true', () async {
      final r = await resolveEnforcedCodeSignRequirement(
        runningBundlePath: '/Applications/Octodo.app',
        platformIsMacOS: fakeMac,
        processRunner: (exe, args) async =>
            throw const ProcessException('codesign', ['--verify']),
      );
      expect(r, isNull, reason: 'tool-unavailable must NOT enable the gate');
    });

    test('runner receives the pinned requirement and the bundle path',
        () async {
      List<String>? seenArgs;
      String? seenExe;
      await resolveEnforcedCodeSignRequirement(
        runningBundlePath: '/Applications/Octodo.app',
        platformIsMacOS: fakeMac,
        processRunner: (exe, args) {
          seenExe = exe;
          seenArgs = args;
          return Future.value(ProcessResult(0, 0, '', ''));
        },
      );
      expect(seenExe, '/usr/bin/codesign');
      expect(seenArgs, [
        '--verify',
        '--deep',
        '--strict',
        '-R=${macCodeSignRequirementFor(kMacUpdateTeamId)}',
        '/Applications/Octodo.app',
      ]);
    });

    test('fork Team ID flows through the requirement string', () async {
      List<String>? seenArgs;
      await resolveEnforcedCodeSignRequirement(
        runningBundlePath: '/Applications/ForkOctodo.app',
        teamId: 'FAKETEAMID1',
        platformIsMacOS: fakeMac,
        processRunner: (_, args) {
          seenArgs = args;
          return Future.value(ProcessResult(0, 0, '', ''));
        },
      );
      expect(
        seenArgs!.singleWhere((a) => a.startsWith('-R=')),
        '-R=${macCodeSignRequirementFor('FAKETEAMID1')}',
      );
    });
  });

  group('verifyBundleCodeSignature (production default verifier)', () {
    // Only the off-macOS/throw path is reachable in the host test
    // environment; the happy path is exercised end-to-end in
    // staged_apply_test.dart via the injected closure.
    test('codesign exception → false (fail closed)', () async {
      // verifyBundleCodeSignature shells out to the real
      // /usr/bin/codesign which doesn't exist on the host —
      // ProcessException is caught and mapped to false.
      final ok = await verifyBundleCodeSignature(
        macCodeSignRequirementFor('P2HUSGVD3W'),
        '/nonexistent.app',
      );
      expect(ok, isFalse);
    });
  });
}
