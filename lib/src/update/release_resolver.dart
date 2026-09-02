// GitHub release JSON resolver + asset matcher.
//
// The /repos/{owner}/{repo}/releases/latest endpoint returns a single
// release payload. We extract:
//   * `tag_name` ("v1.2.3") stripped of leading "v" → version.
//   * `prerelease` (informational; /releases/latest already filters
//     pre-releases, so this is the strict-stable case in practice).
//   * `published_at` (display only).
//   * `html_url` (release notes page).
//   * The asset matching `^octodo-v<ver>-<assetToken>\.zip$` (zip).
//   * Sibling asset matching `^octodo-v<ver>-<assetToken>\.zip\.sha256$`
//     (digest sidecar, optional — older releases may lack it).
//   * Sibling asset matching `^octodo-v<ver>-manifest\.sig$`
//     (Ed25519 signature over version|asset|digest — see
//     `manifest_signature.dart`; optional at parse time, but the
//     controller refuses to install without one).
//
// [assetToken] selects the platform build ("windows-x64",
// "macos-arm64", "macos-x64"). The default is [kDefaultAssetToken]
// ("windows-x64") so pre-existing callers and tests keep their
// behavior; production feeds pass [currentAssetToken] for the
// running platform.
//
// We re-derive the version from each asset filename and require it
// to match `tag_name` — guards against an asset uploaded under the
// wrong tag after publishing.
//
// Pure function: no I/O, no globals, fully testable. The HTTP client
// (separate file) fetches the body; this file parses it.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// The asset token the Windows x64 build publishes under. Kept as
/// the default everywhere so historical callers (and the whole
/// pre-macOS test suite) resolve the same assets they always did.
const String kDefaultAssetToken = 'windows-x64';

/// Strict regex matching the install asset filename for [token].
/// Captures the "X.Y.Z" or "X.Y.Z-prerelease" version portion for
/// cross-checking against the release tag.
RegExp assetPatternFor(String token) => RegExp(
      '^octodo-v(\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.]+)?)-$token\\.zip\$',
    );

/// Strict regex matching the digest sidecar asset for [token].
/// Captures the same version portion.
RegExp assetSha256PatternFor(String token) => RegExp(
      '^octodo-v(\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.]+)?)-$token\\.zip\\.sha256\$',
    );

/// Strict regex matching the per-release Ed25519 manifest-signature
/// asset (`octodo-v<ver>-manifest.sig`). One file covers every
/// platform zip — see `manifest_signature.dart` for the format.
/// Captures the version portion for the same tag cross-check as
/// the zip / sidecar patterns.
RegExp assetSignaturePattern() => RegExp(
      '^octodo-v(\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.]+)?)-manifest\\.sig\$',
    );

/// The platform token the *running* app should resolve assets for.
/// Used by the production feed wiring only — the resolver itself
/// stays pure via the [assetToken] parameter.
///
/// Windows → "windows-x64" (the only Windows build published).
/// macOS → "macos-arm64" on Apple Silicon, "macos-x64" on Intel —
/// matching the asset naming contract the release workflow emits.
String currentAssetToken() {
  if (Platform.isMacOS) {
    return Abi.current() == Abi.macosArm64 ? 'macos-arm64' : 'macos-x64';
  }
  return kDefaultAssetToken;
}

/// Strict regex matching the install asset filename. Captures the
/// "X.Y.Z" or "X.Y.Z-prerelease" version portion for cross-checking
/// against the release tag.
final RegExp kWindowsAssetPattern = assetPatternFor(kDefaultAssetToken);

/// Strict regex matching the digest sidecar asset. Captures the same
/// version portion.
final RegExp kWindowsAssetSha256Pattern =
    assetSha256PatternFor(kDefaultAssetToken);

/// Conservative semver-shape check. Accepts the same shape the
/// release workflow accepts: "X.Y.Z" or "X.Y.Z-prerelease".
final RegExp _kSemverShape = RegExp(
  r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$',
);

class ResolverException implements Exception {
  final String message;
  final Object? cause;
  const ResolverException(this.message, [this.cause]);

  @override
  String toString() => cause == null
      ? 'ResolverException: $message'
      : 'ResolverException: $message ($cause)';
}

/// A resolved GitHub release with the matching platform build asset
/// identified, ready to be downloaded and verified. Constructed by
/// [resolveReleaseJson]; never mutated after construction.
class ReleaseInfo {
  /// "X.Y.Z" or "X.Y.Z-prerelease" — what the running app will
  /// compare against its own version via `compareSemver`.
  final String version;

  /// Raw tag name as published, including any "v" prefix.
  final String tagName;

  /// Whether GitHub marked this as a pre-release. /releases/latest
  /// is supposed to filter these out, so this is informational but
  /// logged for diagnostics.
  final bool prerelease;

  /// `published_at` field, parsed. Display-only; may be null.
  final DateTime? publishedAt;

  /// The release page (notesUrl in the legacy manifest model).
  final Uri htmlUrl;

  /// Direct download URL of the matched zip asset.
  final Uri zipUrl;

  /// Reported size of the zip asset in bytes (used for progress UI).
  final int zipSizeBytes;

  /// Direct download URL of the matched .sha256 sidecar, or null
  /// when the release was published without one (older releases, or
  /// a future asset that wasn't generated by the workflow).
  final Uri? digestUrl;

  /// Filename of the matched platform zip (e.g.
  /// `octodo-v1.2.3-windows-x64.zip`). Needed to build the canonical
  /// signed message during signature verification — the message
  /// covers the exact asset name, so it can't be re-derived from the
  /// download URL alone (hosts/paths vary between GitHub and R2).
  final String assetName;

  /// Direct download URL of the `octodo-v<ver>-manifest.sig`
  /// Ed25519 signature asset, or null when absent. The updater
  /// REFUSES to install without one (fail-closed; see
  /// `manifest_signature.dart`).
  final Uri? signatureUrl;

  /// Release notes body (markdown), or null if GitHub didn't include
  /// one. We don't render this in v1 but expose it for future use.
  final String? body;

  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.prerelease,
    required this.htmlUrl,
    required this.zipUrl,
    required this.zipSizeBytes,
    required this.assetName,
    this.publishedAt,
    this.digestUrl,
    this.signatureUrl,
    this.body,
  });
}

/// Parse a GitHub release JSON body into a [ReleaseInfo]. Throws
/// [ResolverException] on any structural problem — a release without
/// a matching asset surfaces a clear error to the controller
/// instead of being silently dropped.
ReleaseInfo resolveReleaseJson(
  String body, {
  String assetToken = kDefaultAssetToken,
}) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw ResolverException(
      'Expected JSON object at root, got ${decoded.runtimeType}',
    );
  }
  return resolveReleaseMap(decoded, assetToken: assetToken);
}

/// Like [resolveReleaseJson] but takes the already-decoded Map. Useful
/// for tests that bypass JSON encoding.
ReleaseInfo resolveReleaseMap(
  Map<String, dynamic> json, {
  String assetToken = kDefaultAssetToken,
}) {
  final tagName = json['tag_name'];
  if (tagName is! String || tagName.isEmpty) {
    throw const ResolverException('Missing or empty "tag_name"');
  }
  final version = tagName.startsWith('v')
      ? tagName.substring(1)
      : tagName;
  if (!_kSemverShape.hasMatch(version)) {
    throw ResolverException(
      'Tag "$tagName" is not shaped like vX.Y.Z or vX.Y.Z-prerelease',
    );
  }

  final prereleaseRaw = json['prerelease'];
  if (prereleaseRaw is! bool) {
    throw const ResolverException('"prerelease" must be a boolean');
  }

  final publishedAtRaw = json['published_at'];
  DateTime? publishedAt;
  if (publishedAtRaw is String && publishedAtRaw.isNotEmpty) {
    publishedAt = DateTime.tryParse(publishedAtRaw);
  }

  final htmlUrlRaw = json['html_url'];
  if (htmlUrlRaw is! String || htmlUrlRaw.isEmpty) {
    throw const ResolverException('Missing or empty "html_url"');
  }
  final htmlUrl = Uri.tryParse(htmlUrlRaw);
  if (htmlUrl == null || !htmlUrl.hasScheme) {
    throw ResolverException('Invalid "html_url": $htmlUrlRaw');
  }

  final body = json['body'] is String ? json['body'] as String : null;

  final assetsRaw = json['assets'];
  if (assetsRaw is! List) {
    throw const ResolverException('"assets" must be an array');
  }

  Uri? zipUrl;
  int? zipSize;
  Uri? digestUrl;
  Uri? signatureUrl;
  String? zipAssetName;

  final zipPattern = assetPatternFor(assetToken);
  final shaPattern = assetSha256PatternFor(assetToken);
  final sigPattern = assetSignaturePattern();

  for (final entry in assetsRaw) {
    if (entry is! Map<String, dynamic>) continue;
    final name = entry['name'];
    if (name is! String) continue;

    final shaMatch = shaPattern.firstMatch(name);
    if (shaMatch != null) {
      if (shaMatch.group(1) != version) continue;
      digestUrl = _assetDownloadUrl(entry, hint: 'digest asset');
      continue;
    }

    final sigMatch = sigPattern.firstMatch(name);
    if (sigMatch != null) {
      if (sigMatch.group(1) != version) continue;
      signatureUrl = _assetDownloadUrl(entry, hint: 'signature asset');
      continue;
    }

    final zipMatch = zipPattern.firstMatch(name);
    if (zipMatch != null) {
      if (zipMatch.group(1) != version) continue;
      zipUrl = _assetDownloadUrl(entry, hint: 'zip asset');
      zipAssetName = name;
      final sizeRaw = entry['size'];
      zipSize = sizeRaw is int ? sizeRaw : 0;
      continue;
    }
  }

  if (zipUrl == null) {
    throw ResolverException(
      'Release $tagName has no asset matching ${zipPattern.pattern}',
    );
  }

  return ReleaseInfo(
    version: version,
    tagName: tagName,
    prerelease: prereleaseRaw,
    publishedAt: publishedAt,
    htmlUrl: htmlUrl,
    zipUrl: zipUrl,
    zipSizeBytes: zipSize ?? 0,
    assetName: zipAssetName!,
    digestUrl: digestUrl,
    signatureUrl: signatureUrl,
    body: body,
  );
}

Uri? _assetDownloadUrl(
  Map<String, dynamic> asset, {
  required String hint,
}) {
  final raw = asset['browser_download_url'];
  if (raw is! String || raw.isEmpty) {
    throw ResolverException(
      '$hint has missing/empty browser_download_url',
    );
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) {
    throw ResolverException(
      '$hint has invalid browser_download_url: $raw',
    );
  }
  return uri;
}
