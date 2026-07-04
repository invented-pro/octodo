// Tests for `r2_update_feed.dart` — mocks the HTTP layer with
// `MockClient` from package:http so the actual R2 endpoint is
// never hit.
//
// The fixture `manifestBody(...)` mirrors `releaseBody(...)` from
// `update_feed_test.dart` byte-for-byte. That's the whole point of
// mirroring the schema in production: tests and production CI run
// against the same parser.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:octodo/src/update/r2_update_feed.dart';
import 'package:octodo/src/update/release_resolver.dart';
import 'package:octodo/src/update/update_feed.dart';

void main() {
  // Canonical "complete" R2 manifest body — same shape as
  // update_feed_test's releaseBody (deliberately: the R2 release
  // re-uses resolveReleaseJson, which doesn't care where it came
  // from).
  String manifestBody({
    String tagName = 'v1.2.4',
    int zipSize = 54321456,
    String zipHost = 'https://s3.example.test/octodo',
  }) {
    final zipName = 'octodo-$tagName-windows-x64.zip';
    final shaName = '$zipName.sha256';
    return jsonEncode(<String, dynamic>{
      'tag_name': tagName,
      'name': tagName,
      'prerelease': false,
      'published_at': '2026-06-15T12:00:00Z',
      'html_url': 'https://github.com/invented-pro/octodo/releases/tag/$tagName',
      'body': 'R2 mirror of upstream release.',
      'assets': <Map<String, dynamic>>[
        {
          'name': zipName,
          'size': zipSize,
          'browser_download_url': '$zipHost/$zipName',
          'content_type': 'application/zip',
        },
        {
          'name': shaName,
          'size': 64,
          'browser_download_url': '$zipHost/$shaName',
          'content_type': 'text/plain',
        },
      ],
    });
  }

  R2UpdateFeed feedFrom(MockClient mock) => R2UpdateFeed(
        manifestUrl: Uri.parse('https://s3.example.test/octodo/manifest.json'),
        userAgentVersion: '1.0.0+1',
        client: mock,
      );

  group('kind', () {
    test('returns "r2"', () {
      final f = feedFrom(MockClient((_) async => http.Response('', 200)));
      expect(f.kind, 'r2');
      f.dispose();
    });
  });

  group('fetchLatest', () {
    test('parses a complete manifest into ReleaseInfo', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(),
            'https://s3.example.test/octodo/manifest.json');
        expect(req.method, 'GET');
        expect(req.headers['Accept'], 'application/json');
        expect(req.headers['User-Agent'], 'octodo/1.0.0+1');
        expect(req.headers['Cache-Control'], 'no-cache');
        return http.Response(manifestBody(), 200);
      });

      final f = feedFrom(mock);
      final r = await f.fetchLatest();

      expect(r, isA<ReleaseInfo>());
      expect(r.version, '1.2.4');
      expect(r.tagName, 'v1.2.4');
      expect(r.prerelease, isFalse);
      expect(r.zipSizeBytes, 54321456);
      expect(
          r.zipUrl.toString(),
          'https://s3.example.test/octodo/'
          'octodo-v1.2.4-windows-x64.zip');
      expect(r.digestUrl.toString(),
          'https://s3.example.test/octodo/'
          'octodo-v1.2.4-windows-x64.zip.sha256');
      expect(r.body, 'R2 mirror of upstream release.');
    });

    test('forwards the configured manifestUrl verbatim', () async {
      Uri? observed;
      final mock = MockClient((req) async {
        observed = req.url;
        return http.Response(manifestBody(tagName: 'v9.9.9'), 200);
      });
      final f = R2UpdateFeed(
        manifestUrl: Uri.parse('https://custom.example.test/octodo.json'),
        userAgentVersion: '1.0.0+1',
        client: mock,
      );
      final r = await f.fetchLatest();
      expect(observed.toString(),
          'https://custom.example.test/octodo.json');
      expect(r.version, '9.9.9');
    });

    test('404 surfaces as generic UpdateFeedException, not Empty',
        () async {
      final mock = MockClient((_) async => http.Response('', 404));
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(
          isA<UpdateFeedException>().having(
              (e) => e is UpdateFeedEmptyException, 'is Empty',
              isFalse),
        ),
      );
      // Helpful for the error message the user sees — verifies the
      // manifest URL is included so they can tell what they got wrong.
      try {
        await f.fetchLatest();
        fail('expected throw');
      } on UpdateFeedException catch (e) {
        expect(e.message, contains('manifest not found'));
        expect(e.message, contains('manifest.json'));
      }
    });

    test('5xx surfaces as generic UpdateFeedException', () async {
      final mock = MockClient((_) async => http.Response('', 503));
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(isA<UpdateFeedException>()
            .having((e) => e.message, 'message', contains('503'))),
      );
    });

    test('malformed JSON body surfaces as UpdateFeedException', () async {
      final mock =
          MockClient((_) async => http.Response('{"oops":', 200));
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(isA<UpdateFeedException>()),
      );
    });

    test('missing assets array surfaces via the resolver',
        () async {
      final mock = MockClient((_) async => http.Response(jsonEncode({
            'tag_name': 'v1.2.4',
            'name': 'v1.2.4',
            'prerelease': false,
            'published_at': '2026-06-15T12:00:00Z',
            'html_url': 'https://github.com/invented-pro/octodo/releases/tag/v1.2.4',
            'assets': <Map<String, dynamic>>[],
          }), 200));
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(isA<UpdateFeedException>()
            .having((e) => e.message, 'message',
                contains('Could not read R2 manifest'))),
      );
    });

    test('HTTP 403 surfaces as generic exception (no rate-limit '
        'concept on R2)', () async {
      final mock = MockClient((_) async => http.Response(
          '{"error":"forbidden"}', 403,
          headers: {'content-type': 'application/json'}));
      final f = feedFrom(mock);
      await expectLater(
        f.fetchLatest(),
        throwsA(isA<UpdateFeedException>()
            .having((e) => e.message, 'message', contains('403'))),
      );
    });

    test('allowMalformed UTF-8 in payload still parses', () async {
      final mock = MockClient((_) async {
        // Manually craft a body with a stray invalid UTF-8 byte
        // in the body string. The manifest stays valid JSON.
        final bytes = utf8.encode(manifestBody());
        bytes[bytes.length - 10] = 0xff; // inject malformed byte
        return http.Response.bytes(bytes, 200);
      });
      final f = feedFrom(mock);
      final r = await f.fetchLatest();
      expect(r.version, '1.2.4');
    });
  });

  group('fetchSidecar', () {
    test('GETs the sidecar URL and trims the body', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.headers['Accept'], 'text/plain');
        expect(req.headers['User-Agent'], 'octodo/1.0.0+1');
        return http.Response('   abc123\n', 200);
      });
      final f = feedFrom(mock);
      final sidecar =
          await f.fetchSidecar(Uri.parse('https://s3.example.test/octodo/file.sha256'));
      expect(sidecar, 'abc123');
    });

    test('non-2xx rethrows as UpdateFeedException', () async {
      final mock = MockClient((_) async => http.Response('', 404));
      final f = feedFrom(mock);
      await expectLater(
        f.fetchSidecar(Uri.parse('https://s3.example.test/octodo/file.sha256')),
        throwsA(isA<UpdateFeedException>()
            .having((e) => e.message, 'message', contains('404'))),
      );
    });
  });
}
