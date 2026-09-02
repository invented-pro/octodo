// Ed25519 release-manifest signatures for the self-updater
// (GH issue #5, item 2: "hash comes from the same channel").
//
// Threat model: a compromised GitHub account, R2 bucket, or CDN can
// serve a malicious zip WITH a matching .sha256 sidecar — the sidecar
// alone defends against corruption, not compromise. This module adds
// a second, channel-independent trust anchor: every release's digest
// is covered by an Ed25519 signature whose PUBLIC key is compiled
// into the app. The signing key never leaves CI (sops+age encrypted
// at keys/update-signing.pem.age; see .sops.yaml and the
// publish-manifest job in .github/workflows/release.yml).
//
// Wire format — the `octodo-v<ver>-manifest.sig` release asset is a
// plain-text file, one entry per platform zip:
//
//   # octodo-update-sig-v1
//   octodo-v1.2.3-windows-x64.zip <64-hex sha256> <base64 ed25519 sig>
//   octodo-v1.2.3-macos-arm64.zip <64-hex sha256> <base64 ed25519 sig>
//
// Each signature is Ed25519 (PureEdDSA, RFC 8032 — what
// `openssl pkeyutl -sign -rawin` produces and this module verifies)
// over the canonical message built by [canonicalUpdateMessage]:
//
//   octodo-update-v1|<version>|<assetName>|<sha256hex>
//
// CI (bash/openssl) and the app (Dart) build the identical string;
// the version and asset name are inside the signed message, so a
// signature cannot be replayed across releases or platforms.
//
// Verification is fail-closed: a release without a signature asset,
// an entry for the wrong asset, a sidecar digest that disagrees with
// the signed digest, or a signature that fails against every
// embedded key → the update is refused.

import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:cryptography/cryptography.dart';

/// Production Ed25519 public key — raw 32 bytes, base64. Kept in
/// lockstep with the sops-encrypted private half at
/// `keys/update-signing.pem.age` (rotation: generate a successor
/// pair, decrypt+re-encrypt under .sops.yaml rules, and set
/// [kUpdateSigningPublicKeyNext] here one release BEFORE switching
/// CI to the new key).
const String kUpdateSigningPublicKey =
    'JueleegZ9GVeyu01AC9jwTYEY+mxwv5YZNcPqvS0vPU=';

/// Successor public-key slot for rotation; `null` while the current
/// key is the only one. Old builds only know keys compiled into
/// them, so a rotation must ride through one release where BOTH
/// keys verify.
const String? kUpdateSigningPublicKeyNext = null;

/// Comment line every signature file starts with. Informational —
/// not covered by any signature (the canonical message is).
const String kSignatureFileHeader = '# octodo-update-sig-v1';

/// Build the canonical signed message. MUST stay byte-identical to
/// the bash side in release.yml:
/// `printf '%s' "octodo-update-v1|$ver|$asset|$hash"`.
String canonicalUpdateMessage(
  String version,
  String assetName,
  String sha256Hex,
) =>
    'octodo-update-v1|$version|$assetName|${sha256Hex.toLowerCase()}';

/// Typed failure for every fail-closed branch of
/// [verifyAssetSignature]. `reason` is short and log-safe (never
/// includes raw file bytes).
class UpdateSignatureException implements Exception {
  final String reason;
  const UpdateSignatureException(this.reason);

  @override
  String toString() => 'UpdateSignatureException: $reason';
}

/// One `<assetName> <sha256hex> <signatureBase64>` line of a
/// signature file.
class ManifestSignatureEntry {
  final String assetName;
  final String digestHex;
  final String signatureBase64;
  const ManifestSignatureEntry({
    required this.assetName,
    required this.digestHex,
    required this.signatureBase64,
  });
}

final RegExp _kHex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// Parse a signature-file body. Throws [UpdateSignatureException] on
/// any structurally invalid line — the file is tiny and fully
/// attacker-controlled if the feed is compromised, so leniency buys
/// nothing. Blank lines and `#` comments are skipped.
List<ManifestSignatureEntry> parseSignatureFile(String body) {
  final entries = <ManifestSignatureEntry>[];
  var sawHeader = false;
  for (final rawLine in body.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      if (line == kSignatureFileHeader) sawHeader = true;
      continue;
    }
    final fields = line.split(RegExp(r'\s+'));
    if (fields.length != 3) {
      throw UpdateSignatureException(
          'malformed signature line: expected "<asset> <sha256> <sig>", '
          'got ${fields.length} field(s)');
    }
    final name = fields[0];
    final hex = fields[1];
    final sig = fields[2];
    if (name.isEmpty || !_kHex64.hasMatch(hex)) {
      throw const UpdateSignatureException(
          'malformed signature line: bad asset name or digest');
    }
    entries.add(ManifestSignatureEntry(
      assetName: name,
      digestHex: hex.toLowerCase(),
      signatureBase64: sig,
    ));
  }
  if (!sawHeader) {
    throw const UpdateSignatureException(
        'signature file is missing its header line');
  }
  if (entries.isEmpty) {
    throw const UpdateSignatureException(
        'signature file contains no entries');
  }
  return entries;
}

/// Verify that the release's [assetName] at [version] is covered by
/// a valid Ed25519 signature whose signed digest equals
/// [digestHex] (the value the `.sha256` sidecar advertised).
///
/// Fail-closed on every gap; returns normally ONLY when all of:
///   1. the file parses (header, well-formed entries),
///   2. an entry exists for exactly [assetName],
///   3. that entry's signed digest equals [digestHex],
///   4. its signature verifies against one of [publicKeysBase64]
///      (defaults to the keys embedded in this module).
Future<void> verifyAssetSignature({
  required String body,
  required String version,
  required String assetName,
  required String digestHex,
  List<String>? publicKeysBase64,
}) async {
  final keys = publicKeysBase64 ??
      [
        kUpdateSigningPublicKey,
        ?kUpdateSigningPublicKeyNext,
      ];
  if (keys.isEmpty) {
    throw const UpdateSignatureException('no public keys configured');
  }

  final entries = parseSignatureFile(body);
  final matches =
      entries.where((e) => e.assetName == assetName).toList();
  if (matches.isEmpty) {
    throw UpdateSignatureException(
        'signature file has no entry for asset "$assetName"');
  }
  if (matches.length > 1) {
    throw UpdateSignatureException(
        'signature file has ${matches.length} entries for asset '
        '"$assetName"');
  }
  final entry = matches.single;

  final sidecar = digestHex.toLowerCase();
  if (!_kHex64.hasMatch(sidecar)) {
    throw const UpdateSignatureException(
        'sidecar digest is not 64-hex');
  }
  if (entry.digestHex != sidecar) {
    // The signed manifest and the sidecar disagree — one of the two
    // channels is lying. Distinct reason: this is the strongest
    // tamper signal the updater can observe. Include both digests
    // so the controller's `technicalDetails` line is actionable.
    throw UpdateSignatureException(
        'signed digest does not match the .sha256 sidecar '
        '(signed=${entry.digestHex}, sidecar=$sidecar)');
  }

  final Uint8List signatureBytes;
  try {
    signatureBytes = base64.decode(entry.signatureBase64);
  } on FormatException {
    throw const UpdateSignatureException(
        'signature is not valid base64');
  }
  if (signatureBytes.length != 64) {
    throw UpdateSignatureException(
        'signature is ${signatureBytes.length} bytes, expected 64');
  }

  final message =
      utf8.encode(canonicalUpdateMessage(version, assetName, entry.digestHex));
  final algorithm = Ed25519();
  var verified = false;
  for (final keyB64 in keys) {
    final Uint8List pubBytes;
    try {
      pubBytes = base64.decode(keyB64);
    } on FormatException {
      // A malformed EMBEDDED key is a build error, not an attacker
      // signal — but fail closed regardless.
      throw const UpdateSignatureException(
          'embedded public key is not valid base64');
    }
    if (pubBytes.length != 32) {
      throw UpdateSignatureException(
          'embedded public key is ${pubBytes.length} bytes, expected 32');
    }
    final ok = await algorithm.verify(
      message,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
      ),
    );
    if (ok) {
      verified = true;
      break;
    }
  }
  if (!verified) {
    throw const UpdateSignatureException(
        'Ed25519 signature did not verify against any known key');
  }
}
