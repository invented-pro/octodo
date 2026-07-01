// Tests for `release_resolver.dart` — pure parser; no HTTP, no I/O.
// Covers the canonical GitHub release shape, missing assets, schema
// edge cases, and the asset-version-cross-check guard.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/update/release_resolver.dart';

Map<String, dynamic> _canonical({
  String tagName = 'v1.2.3',
  String body = 'Initial release.',
  String zipName = 'octodo-v1.2.3-windows-x64.zip',
  int zipSize = 54321000,
  String? shaName = 'octodo-v1.2.3-windows-x64.zip.sha256',
  bool prerelease = false,
  String publishedAt = '2026-06-15T12:00:00Z',
}) {
  final assets = <Map<String, dynamic>>[
    {
      'name': zipName,
      'size': zipSize,
      'browser_download_url':
          'https://github.com/invented-pro/octodo/releases/download/$tagName/$zipName',
      'content_type': 'application/zip',
    },
  ];
  if (shaName != null) {
    assets.add({
      'name': shaName,
      'size': 64,
      'browser_download_url':
          'https://github.com/invented-pro/octodo/releases/download/$tagName/$shaName',
      'content_type': 'text/plain',
    });
  }
  // GitHub also auto-includes source archives; we want to ensure
  // these get ignored without affecting matching.
  assets.add({
    'name': 'Source code (zip)',
    'size': 12000,
    'browser_download_url':
        'https://github.com/invented-pro/octodo/zipball/$tagName',
    'content_type': 'application/zip',
  });

  return <String, dynamic>{
    'tag_name': tagName,
    'name': tagName,
    'prerelease': prerelease,
    'published_at': publishedAt,
    'html_url': 'https://github.com/invented-pro/octodo/releases/tag/$tagName',
    'body': body,
    'assets': assets,
  };
}

String _encode(Object? o) => jsonEncode(o);

void main() {
  group('resolveReleaseJson (canonical)', () {
    test('extracts every field from a complete payload', () {
      final r = resolveReleaseJson(_encode(_canonical()));
      expect(r.version, '1.2.3');
      expect(r.tagName, 'v1.2.3');
      expect(r.prerelease, isFalse);
      expect(r.publishedAt, DateTime.utc(2026, 6, 15, 12));
      expect(r.htmlUrl.toString(),
          'https://github.com/invented-pro/octodo/releases/tag/v1.2.3');
      expect(r.zipUrl.toString(),
          'https://github.com/invented-pro/octodo/releases/download/v1.2.3/octodo-v1.2.3-windows-x64.zip');
      expect(r.zipSizeBytes, 54321000);
      expect(r.digestUrl?.toString(),
          'https://github.com/invented-pro/octodo/releases/download/v1.2.3/octodo-v1.2.3-windows-x64.zip.sha256');
      expect(r.body, 'Initial release.');
    });

    test('digest is null when no sidecar present', () {
      final r = resolveReleaseJson(_encode(_canonical(shaName: null)));
      expect(r.digestUrl, isNull);
      expect(r.zipUrl, isNotNull);
    });

    test('captures prerelease flag when true', () {
      final r = resolveReleaseJson(_encode(_canonical(
        tagName: 'v1.3.0-rc.1',
        zipName: 'octodo-v1.3.0-rc.1-windows-x64.zip',
        shaName: 'octodo-v1.3.0-rc.1-windows-x64.zip.sha256',
        prerelease: true,
      )));
      expect(r.version, '1.3.0-rc.1');
      expect(r.prerelease, isTrue);
    });

    test('treats missing published_at as null', () {
      final m = _canonical();
      m.remove('published_at');
      final r = resolveReleaseJson(_encode(m));
      expect(r.publishedAt, isNull);
    });

    test('treats malformed published_at as null (does not throw)', () {
      final r = resolveReleaseJson(
        _encode(_canonical(publishedAt: 'not-a-date')),
      );
      expect(r.publishedAt, isNull);
    });
  });

  group('asset-version cross-check', () {
    test('drops an asset whose embedded version does not match the tag', () {
      // The tag is v1.2.3 but the asset on disk is named
      // octodo-v1.2.4-windows-x64.zip. We must NOT match it.
      final m = <String, dynamic>{
        'tag_name': 'v1.2.3',
        'prerelease': false,
        'html_url': 'https://github.com/invented-pro/octodo/releases/tag/v1.2.3',
        'published_at': '2026-06-15T12:00:00Z',
        'body': '',
        'assets': <Map<String, dynamic>>[
          {
            'name': 'octodo-v1.2.4-windows-x64.zip',
            'size': 1,
            'browser_download_url':
                'https://github.com/invented-pro/octodo/releases/download/v1.2.3/octodo-v1.2.4-windows-x64.zip',
          }
        ],
      };
      expect(() => resolveReleaseMap(m), throwsA(isA<ResolverException>()));
    });

    test('matches an asset whose version agrees with the tag', () {
      final r = resolveReleaseMap(<String, dynamic>{
        'tag_name': 'v1.2.3',
        'prerelease': false,
        'html_url': 'https://github.com/invented-pro/octodo/releases/tag/v1.2.3',
        'published_at': '2026-06-15T12:00:00Z',
        'body': '',
        'assets': <Map<String, dynamic>>[
          {
            'name': 'octodo-v1.2.3-windows-x64.zip',
            'size': 1,
            'browser_download_url':
                'https://github.com/invented-pro/octodo/releases/download/v1.2.3/octodo-v1.2.3-windows-x64.zip',
          }
        ],
      });
      expect(r.zipUrl.toString(),
          'https://github.com/invented-pro/octodo/releases/download/v1.2.3/octodo-v1.2.3-windows-x64.zip');
    });
  });

  group('schema rejection', () {
    test('rejects non-object root', () {
      expect(() => resolveReleaseJson('[]'),
          throwsA(isA<ResolverException>()));
      expect(() => resolveReleaseJson('null'),
          throwsA(isA<ResolverException>()));
    });

    test('rejects missing tag_name', () {
      expect(
        () => resolveReleaseMap(<String, dynamic>{
          'prerelease': false,
          'html_url':
              'https://github.com/owner/repo/releases/tag/v1.0.0',
          'assets': <Map<String, dynamic>>[],
        }),
        throwsA(isA<ResolverException>()),
      );
    });

    test('rejects tag without v + X.Y.Z shape', () {
      expect(
        () => resolveReleaseMap(<String, dynamic>{
          'tag_name': 'not-semver',
          'prerelease': false,
          'html_url':
              'https://github.com/owner/repo/releases/tag/not-semver',
          'assets': <Map<String, dynamic>>[],
        }),
        throwsA(isA<ResolverException>()),
      );
    });

    test('rejects release with no matching zip', () {
      expect(
        () => resolveReleaseMap(<String, dynamic>{
          'tag_name': 'v1.2.3',
          'prerelease': false,
          'html_url': 'https://github.com/owner/repo/releases/tag/v1.2.3',
          'assets': <Map<String, dynamic>>[
            {
              'name': 'octodo-v1.2.3-linux-x64.zip',
              'size': 1,
              'browser_download_url': 'https://example/other.zip',
            }
          ],
        }),
        throwsA(isA<ResolverException>()),
      );
    });
  });
}
