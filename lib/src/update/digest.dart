// SHA-256 helpers for the in-app updater.
//
// One-shot: load the file into memory, hash, compare. Update payloads
// are ~30–50MB and a single allocation is cheaper than wiring a
// streaming Hash sink through the HTTP `Stream<List<int>>` — progress
// reporting already comes from the HTTP listener callbacks, so
// streaming the digest buys nothing.
//
// The sidecar convention is the bare 64-char lowercase hex string
// with no trailing newline. We tolerate case + whitespace on input so
// the upstream contract can drift without breaking us.
//
// Runs without a direct dependency on package:async. We only consume
// `package:crypto` (sha256.convert) + dart:io + dart:typed_data.

import 'dart:io';

import 'package:crypto/crypto.dart';

const int _kSha256HexLen = 64;
final RegExp _kHex64 =
    RegExp(r'^[0-9a-fA-F]{64}$');

/// Thrown by [verifySha256Hex] when the on-disk file's digest does
/// not match the expected hex.
class DigestMismatchException implements Exception {
  final String expected;
  final String actual;
  final String path;
  const DigestMismatchException({
    required this.expected,
    required this.actual,
    required this.path,
  });

  @override
  String toString() =>
      'DigestMismatchException: SHA-256 mismatch for $path '
      '(expected $expected, got $actual)';
}

/// Read [file] from disk and return its SHA-256 digest as lowercase
/// 64-char hex. Allocates the full file in RAM (~30–50MB for an
/// octodo release); fine for update payloads, intentionally simple.
Future<String> sha256HexOfFile(File file) async {
  final bytes = await file.readAsBytes();
  return sha256.convert(bytes).toString();
}

/// Parse a "bare 64-char hex" string with any leading/trailing
/// whitespace stripped, returning it lowercased. Throws
/// [FormatException] if the result is not 64 hex characters.
String normalizeSha256Hex(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length != _kSha256HexLen || !_kHex64.hasMatch(trimmed)) {
    throw FormatException(
      'Expected 64-hex-char SHA-256, got: "$raw"',
    );
  }
  return trimmed.toLowerCase();
}

/// Verify [file]'s SHA-256 against [expectedHex]. Whitespace and
/// case in [expectedHex] are tolerated. Returns the actual lowercase
/// hex on success.
///
/// Throws:
///   * [FormatException] if [expectedHex] isn't a 64-hex string.
///   * [DigestMismatchException] if the on-disk file's digest differs.
Future<String> verifySha256Hex({
  required File file,
  required String expectedHex,
}) async {
  final expected = normalizeSha256Hex(expectedHex);
  final actual = await sha256HexOfFile(file);
  if (actual != expected) {
    throw DigestMismatchException(
      expected: expected,
      actual: actual,
      path: file.path,
    );
  }
  return actual;
}
