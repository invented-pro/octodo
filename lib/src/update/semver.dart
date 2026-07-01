// Semver helpers extracted from the old "latest_manifest.dart". Once
// the in-app updater fed off a Microsoft Store `latest.json`; it
// now feeds off GitHub's `/releases/latest` endpoint (see
// `release_resolver.dart`), but the semver comparison rules are the
// same. They live here, in their own file, so `compareSemver` can be
// tested and reused without dragging in GitHub-shape dependencies.
//
// Compares two semver-shaped strings: "MAJOR.MINOR.PATCH" with an
// optional "-prerelease" suffix. Build metadata ("+…") is ignored for
// ordering. A version WITHOUT a prerelease suffix is GREATER than the
// same version WITH one (2.4.0 > 2.4.0-rc.1).
//
// Returns negative if [a] < [b], 0 if equal, positive if [a] > [b].
// Falls back to lexical comparison if either string is malformed.

class _SemverParts {
  final List<int> majorMinorPatch;
  final String? prerelease;
  const _SemverParts(this.majorMinorPatch, this.prerelease);
}

_SemverParts? _parseSemver(String v) {
  final plus = v.indexOf('+');
  final base = plus >= 0 ? v.substring(0, plus) : v;
  final dash = base.indexOf('-');
  final core = dash >= 0 ? base.substring(0, dash) : base;
  final pre = dash >= 0 ? base.substring(dash + 1) : null;
  final parts = core.split('.');
  if (parts.length != 3) return null;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0) return null;
    nums.add(n);
  }
  return _SemverParts(nums, (pre == null || pre.isEmpty) ? null : pre);
}

int _comparePrereleaseId(String a, String b) {
  final ai = int.tryParse(a);
  final bi = int.tryParse(b);
  if (ai != null && bi != null) return ai.compareTo(bi);
  if (ai != null) return -1;
  if (bi != null) return 1;
  return a.compareTo(b);
}

int compareSemver(String a, String b) {
  final pa = _parseSemver(a);
  final pb = _parseSemver(b);
  if (pa == null || pb == null) return a.compareTo(b);
  for (var i = 0; i < 3; i++) {
    final d = pa.majorMinorPatch[i].compareTo(pb.majorMinorPatch[i]);
    if (d != 0) return d;
  }
  final ap = pa.prerelease;
  final bp = pb.prerelease;
  if (ap == null && bp == null) return 0;
  if (ap == null) return 1;
  if (bp == null) return -1;
  final aIds = ap.split('.');
  final bIds = bp.split('.');
  final n = aIds.length < bIds.length ? aIds.length : bIds.length;
  for (var i = 0; i < n; i++) {
    final d = _comparePrereleaseId(aIds[i], bIds[i]);
    if (d != 0) return d;
  }
  return aIds.length.compareTo(bIds.length);
}
