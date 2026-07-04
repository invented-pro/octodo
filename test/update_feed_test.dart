// Tests for `update_feed.dart` — mocks the HTTP layer with
// `MockClient` from package:http so the actual API is never hit.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:octodo/src/update/release_resolver.dart';
import 'package:octodo/src/update/update_feed.dart';

void main() {
  // Canonical "complete" GitHub release body — same shape as the
  // real /releases/latest payload but with values easy to assert.
  String releaseBody({
    String tagName = 'v1.2.3',
    int zipSize = 54321000,
  }) {
    final zipName = 'octodo-$tagName-windows-x64.zip';
    final shaName = '$zipName.sha256';
    return jsonEncode(<String, dynamic>{
      'tag_name': tagName,
      'name': tagName,
      'prerelease': false,
      'published_at': '2026-06-15T12:00:00Z',
      'html_url': 'https://github.com/invented-pro/octodo/releases/tag/$tagName',
      'body': 'Initial.',
      'assets': <Map<String, dynamic>>[
        {
          'name': zipName,
          'size': zipSize,
          'browser_download_url':
              'https://github.com/invented-pro/octodo/releases/download/$tagName/$zipName',
          'content_type': 'application/zip',
        },
        {
          'name': shaName,
          'size': 64,
          'browser_download_url':
              'https://github.com/invented-pro/octodo/releases/download/$tagName/$shaName',
          'content_type': 'text/plain',
        },
      ],
    });
  }

  UpdateFeed feedFrom(MockClient mock) => UpdateFeed(
        repository: 'invented-pro/octodo',
        userAgentVersion: '1.0.0+1',
        client: mock,
      );

  group('fetchLatest', () {
    test('parses a complete payload into ReleaseInfo', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(),
            'https://api.github.com/repos/invented-pro/octodo/releases/latest');
        expect(req.headers['Accept'], 'application/vnd.github+json');
        expect(req.headers['User-Agent'], 'octodo/1.0.0+1');
        expect(req.headers['X-GitHub-Api-Version'], '2022-11-28');
        expect(req.method, 'GET');
        return http.Response(releaseBody(), 200);
      });

      final f = feedFrom(mock);
      final r = await f.fetchLatest();

      expect(r, isA<ReleaseInfo>());
      expect(r.version, '1.2.3');
      expect(r.zipSizeBytes, 54321000);
      expect(r.digestUrl, isNotNull);
    });

    test('uses the configured repository in the URL', () async {
      Uri? observed;
      final mock = MockClient((req) async {
        observed = req.url;
        return http.Response(releaseBody(tagName: 'v9.9.9'), 200);
      });
      final f = UpdateFeed(
        repository: 'someoneelse/their-octodo',
        userAgentVersion: '0.0.0+0',
        client: mock,
      );
      await f.fetchLatest();
      expect(
        observed.toString(),
        'https://api.github.com/repos/someoneelse/their-octodo/releases/latest',
      );
    });

    test('throws UpdateFeedEmptyException on 404', () async {
      final mock = MockClient((_) async {
        return http.Response('{"message":"Not Found"}', 404);
      });
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(
          isA<UpdateFeedEmptyException>().having(
              (e) => e.message, 'message', contains('No releases published')),
        ),
      );
    });

    test('throws UpdateFeedException on 5xx', () async {
      final mock = MockClient((_) async {
        return http.Response('boom', 500);
      });
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(
          isA<UpdateFeedException>()
              .having((e) => e.message, 'message', contains('HTTP 500')),
        ),
      );
    });

    test('wraps network errors into UpdateFeedException', () async {
      final mock = MockClient((_) async {
        throw const SocketException('no internet');
      });
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(
          isA<UpdateFeedException>().having(
              (e) => e.message, 'message', contains('Network error')),
        ),
      );
    });

    test('wraps resolver exceptions into UpdateFeedException', () async {
      final mock = MockClient((_) async {
        // Empty JSON object — missing tag_name -> ResolverException.
        return http.Response('{}', 200);
      });
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(
          isA<UpdateFeedException>().having(
            (e) => e.message,
            'message',
            contains('Could not read the update feed'),
          ),
        ),
      );
    });

    group('rate limit detection', () {
      test('403 + x-ratelimit-remaining=0 → typed exception with reset',
          () async {
        // Reset 30 minutes in the future.
        final resetEpoch =
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 1800;
        final mock = MockClient((_) async {
          return http.Response(
            '{"message":"API rate limit exceeded"}',
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-limit': '60',
              'x-ratelimit-reset': '$resetEpoch',
            },
          );
        });
        final f = feedFrom(mock);
        await expectLater(
          f.fetchLatest(),
          throwsA(
            isA<UpdateFeedRateLimitException>()
                .having((e) => e.remaining, 'remaining', 0)
                .having((e) => e.limit, 'limit', 60)
                .having(
                  (e) => e.resetAt.millisecondsSinceEpoch ~/ 1000,
                  'resetAt',
                  resetEpoch,
                ),
          ),
        );
      });

      test('403 + missing header + body says "rate limit exceeded" → typed',
          () async {
        // Proxy stripped the headers but the body is unmistakable.
        final mock = MockClient((_) async {
          return http.Response(
            '{"message":"API rate limit exceeded for 1.2.3.4"}',
            403,
          );
        });
        final f = feedFrom(mock);
        await expectLater(
          f.fetchLatest(),
          throwsA(isA<UpdateFeedRateLimitException>()),
        );
      });

      test('403 + missing header + unrelated body → generic 403, not rate-limit',
          () async {
        // Private repo / suspended account / etc. The body
        // doesn't mention "rate limit exceeded" specifically, so
        // we should NOT mis-classify this as a rate-limit hit.
        final mock = MockClient((_) async {
          return http.Response(
            '{"message":"Repository access blocked"}',
            403,
          );
        });
        final f = feedFrom(mock);
        await expectLater(
          f.fetchLatest(),
          throwsA(
            isA<UpdateFeedException>().having(
                (e) => e.runtimeType.toString(),
                'runtimeType',
                'UpdateFeedException'),
          ),
        );
      });

      test('403 + remaining=5 (under limit) → not rate-limited', () async {
        // Some other 403 reason (e.g. suspended). The
        // `remaining` header is still 5 because the account
        // hasn't exhausted its quota.
        final mock = MockClient((_) async {
          return http.Response(
            '{"message":"Forbidden"}',
            403,
            headers: {
              'x-ratelimit-remaining': '5',
              'x-ratelimit-limit': '60',
            },
          );
        });
        final f = feedFrom(mock);
        await expectLater(
          f.fetchLatest(),
          throwsA(isA<UpdateFeedException>()),
        );
      });
    });
  });
}
