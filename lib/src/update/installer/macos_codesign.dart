// macOS payload code-signature gate — Phase C of the self-update
// trust hardening (GH issue #5, item 2).
//
// Phases A/B (fail-closed sidecar + Ed25519 manifest signature)
// protect the *transport*: what was downloaded is what was signed.
// This module protects the *payload* on macOS: the extracted .app
// bundle must carry a code signature chaining to the pinned Apple
// Developer Team before anything is swapped into the install
// location. Even a compromise of the Ed25519 signing key would then
// still require the attacker's build to carry the Apple-issued
// Developer ID identity.
//
// Enforcement uses the *inheritance rule* (the same principle
// Sparkle applies): the pin is enforced only when the RUNNING app
// itself satisfies it. Official signed builds therefore always
// verify their successor, while dev builds (ad-hoc signature),
// unsigned forks, and custom-Team-ID forks inherit their weaker
// posture instead of being bricked mid-update. The Ed25519 manifest
// signature remains enforced unconditionally either way.
//
// All verification is offline — `codesign --verify -R` evaluates a
// designated requirement against the certificate chain embedded in
// the bundle's signature; no network, no Gatekeeper assessment
// (which we deliberately bypass by swapping the bundle ourselves).

import 'dart:io';

/// Verifier signature shared by the apply paths: returns true only
/// when the bundle at [bundlePath] satisfies [requirement].
typedef CodeSignVerifier = Future<bool> Function(
  String requirement,
  String bundlePath,
);

/// Apple Developer Program Team ID — the `subject.OU` carried by the
/// Developer ID Application leaf certificate official octodo release
/// bundles are signed with (CI secret `MACOS_SIGNING_IDENTITY`).
///
/// Forks: replace with your own Team ID, or set to '' to disable the
/// platform-signature gate entirely (Phase B's Ed25519 manifest
/// signature stays active regardless).
const String kMacUpdateTeamId = 'P2HUSGVD3W';

/// Build the designated requirement pinned to [teamId]. Passed to
/// `codesign --verify --deep --strict -R=<requirement>` on both the
/// running bundle (inheritance probe) and the extracted payload
/// (enforcement).
String macCodeSignRequirementFor(String teamId) =>
    'anchor apple generic and certificate leaf[subject.OU] = "$teamId"';

/// Resolve the requirement this apply should enforce, or `null`
/// when the platform gate must not run:
///
///   * [teamId] empty (fork disabled the gate),
///   * not macOS (the Windows/Linux apply paths),
///   * the RUNNING bundle fails the pin (dev build, ad-hoc
///     signature, different-team fork) — inheritance rule,
///   * `codesign` itself could not be executed (treated as
///     gate-unavailable, never as verification success).
///
/// [processRunner] and [platformIsMacOS] are injection points for
/// unit tests; production uses `Process.run` and `Platform.isMacOS`.
Future<String?> resolveEnforcedCodeSignRequirement({
  required String runningBundlePath,
  String teamId = kMacUpdateTeamId,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
      processRunner,
  bool Function()? platformIsMacOS,
}) async {
  if (teamId.isEmpty) return null;
  final isMac = platformIsMacOS ?? () => Platform.isMacOS;
  if (!isMac()) return null;

  final requirement = macCodeSignRequirementFor(teamId);
  final run = processRunner ?? Process.run;
  try {
    final result = await run('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      '-R=$requirement',
      runningBundlePath,
    ]);
    return result.exitCode == 0 ? requirement : null;
  } catch (_) {
    return null;
  }
}

/// Default payload verifier used by the legacy Dart bundle-swap
/// apply path (production macOS applies through the /bin/sh script;
/// this keeps the in-process path honest). Returns true only when
/// `codesign` exits 0.
Future<bool> verifyBundleCodeSignature(
  String requirement,
  String bundlePath,
) async {
  try {
    final result = await Process.run('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      '-R=$requirement',
      bundlePath,
    ]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
