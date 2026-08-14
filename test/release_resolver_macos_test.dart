// Tests for the multi-platform asset-token support in
// `release_resolver.dart` — the same release payload advertises
// per-platform zips (`octodo-v<ver>-windows-x64.zip`,
// `octodo-v<ver>-macos-arm64.zip`, …) and the resolver must pick
// the asset matching the requested token while ignoring the
// others.
//
// The default token stays `windows-x64` so every pre-existing
// caller (and the pre-existing tests) resolve exactly what they
// always did — covered by release_resolver_test.dart.

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/update/release_resolver.dart';

Map<String, dynamic> _releaseWithAssets(List<String> names) {
  return <String, dynamic>{
    'tag_name': 'v9.9.9',
    'name': 'v9.9.9',
    'prerelease': false,
    'published_at': '2026-06-15T12:00:00Z',
    'html_url': 'https://github.com/invented-pro/octodo/releases'
        '/tag/v9.9.9',
    'body': '',
    'assets': [
      for (final name in names)
        <String, dynamic>{
          'name': name,
          'size': 12345,
          'browser_download_url': 'https://example.com/v9.9.9/$name',
          'content_type': 'application/zip',
        },
    ],
  };
}

void main() {
  group('assetPatternFor', () {
    test('builds a strict per-token matcher', () {
      final mac = assetPatternFor('macos-arm64');
      expect(mac.hasMatch('octodo-v1.2.3-macos-arm64.zip'), isTrue);
      expect(mac.hasMatch('octodo-v1.2.3-macos-x64.zip'), isFalse);
      expect(mac.hasMatch('octodo-v1.2.3-windows-x64.zip'), isFalse);
      expect(mac.hasMatch('octodo-v1.2.3-macos-arm64.zip.sha256'), isFalse);

      final sha = assetSha256PatternFor('macos-arm64');
      expect(sha.hasMatch('octodo-v1.2.3-macos-arm64.zip.sha256'), isTrue);
      expect(sha.hasMatch('octodo-v1.2.3-macos-arm64.zip'), isFalse);
    });

    test('kWindowsAssetPattern is the windows-x64 token pattern', () {
      expect(
        kWindowsAssetPattern.pattern,
        assetPatternFor('windows-x64').pattern,
      );
    });
  });

  group('resolveReleaseMap with assetToken', () {
    test('macos-arm64 picks the macOS zip + sidecar, ignores windows', () {
      final release = resolveReleaseMap(
        _releaseWithAssets([
          'octodo-v9.9.9-windows-x64.zip',
          'octodo-v9.9.9-windows-x64.zip.sha256',
          'octodo-v9.9.9-macos-arm64.zip',
          'octodo-v9.9.9-macos-arm64.zip.sha256',
        ]),
        assetToken: 'macos-arm64',
      );

      expect(release.version, '9.9.9');
      expect(release.zipUrl.toString(),
          'https://example.com/v9.9.9/octodo-v9.9.9-macos-arm64.zip');
      expect(release.digestUrl?.toString(),
          'https://example.com/v9.9.9/octodo-v9.9.9-macos-arm64.zip.sha256');
    });

    test('default token still resolves the windows asset', () {
      final release = resolveReleaseMap(
        _releaseWithAssets([
          'octodo-v9.9.9-windows-x64.zip',
          'octodo-v9.9.9-macos-arm64.zip',
        ]),
      );
      expect(release.zipUrl.toString(),
          'https://example.com/v9.9.9/octodo-v9.9.9-windows-x64.zip');
    });

    test('release without the requested platform asset throws', () {
      expect(
        () => resolveReleaseMap(
          _releaseWithAssets(['octodo-v9.9.9-windows-x64.zip']),
          assetToken: 'macos-arm64',
        ),
        throwsA(isA<ResolverException>()),
      );
    });

    test('version in a foreign-platform filename must still match tag', () {
      // A windows asset uploaded with a mismatched version is
      // simply not matched; the macos asset with the matching
      // version wins even when listed after it.
      final release = resolveReleaseMap(
        _releaseWithAssets([
          'octodo-v9.8.0-windows-x64.zip',
          'octodo-v9.9.9-macos-arm64.zip',
        ]),
        assetToken: 'macos-arm64',
      );
      expect(release.zipUrl.toString(), contains('9.9.9-macos-arm64'));
    });
  });

  group('currentAssetToken', () {
    test('returns a token from the published naming contract', () {
      expect(
        currentAssetToken(),
        anyOf('windows-x64', 'macos-arm64', 'macos-x64'),
      );
    });
  });
}
