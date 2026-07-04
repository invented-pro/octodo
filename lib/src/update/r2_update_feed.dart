// Cloudflare R2 (or any S3-compatible static bucket, plus R2.dev or
// a custom domain) manifest feed.
//
// [R2UpdateFeed] is the fallback source the controller wires when
// the user has supplied a `update.fallbackUrl` setting. It mirrors
// GitHub's `/releases/latest` JSON shape byte-for-byte in a single
// static `manifest.json` file, so the existing [resolveReleaseJson]
// parser picks it up with zero changes:
//
//   {
//     "tag_name":     "v1.2.4",
//     "name":         "v1.2.4",
//     "prerelease":   false,
//     "published_at": "2026-...",
//     "html_url":     "https://github.com/invented-pro/octodo/releases/tag/v1.2.4",
//     "body":         "Release notes…",
//     "assets": [
//       { "name": "octodo-v1.2.4-windows-x64.zip",
//         "size": 54321000,
//         "browser_download_url": "https://<your-r2-host>/octodo/octodo-v1.2.4-windows-x64.zip",
//         "content_type": "application/zip" },
//       { "name": "octodo-v1.2.4-windows-x64.zip.sha256",
//         "size": 64,
//         "browser_download_url": "https://<your-r2-host>/octodo/octodo-v1.2.4-windows-x64.zip.sha256",
//         "content_type": "text/plain; charset=utf-8" }
//     ]
//   }
//
// Publishing flow (run from CI on every release tag):
//   1. Build the zip + .sha256, create a static manifest.json next
//      to them, and upload the three to R2.
//   2. manifest.json is overwritten in place on every release so the
//      URL the in-app feed reads is always a single "what's latest"
//      pointer.
//
// Like [UpdateFeed], this class:
//   * emits `User-Agent: octodo/<version>` and `Cache-Control: no-cache`
//   * throws [UpdateFeedException] on network / 5xx / parse errors
//
// Differences from [UpdateFeed]:
//   * The manifest URL is fully user-configured (R2 bucket + custom
//     domain or R2.dev URL).
//   * No rate-limit detection — R2 doesn't issue `x-ratelimit-*`
//     headers. Any 403 is misconfiguration.
//   * No "empty repo" semantic — a missing manifest on R2 is *not*
//     "no releases yet", it's "you set the wrong URL". Surfaces as a
//     generic [UpdateFeedException] so the UI shows it instead of
//     falsely declaring "you're up to date".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'release_resolver.dart';
import 'update_feed.dart';

class R2UpdateFeed implements UpdateFeedSource {
  /// Manifest JSON URL — typically
  /// `https://<your-r2-custom-domain>/<key-prefix>/manifest.json`,
  /// e.g. `https://s3.primorial.net/octodo/manifest.json`.
  final Uri manifestUrl;
  final http.Client _client;
  final Duration _timeout;
  final String _userAgentVersion;

  R2UpdateFeed({
    required this.manifestUrl,
    required String userAgentVersion,
    http.Client? client,
    Duration timeout = const Duration(seconds: 5),
  })  : _client = client ?? http.Client(),
        // Private fields can't use the `this.x` initializer form,
        // so this lint is a false-positive — but suppressing it
        // inline keeps the code straight to read.
        // ignore: prefer_initializing_formals
        _timeout = timeout,
        // Same caveat as above: parameter name doesn't match the
        // private field name we want to assign to.
        // ignore: prefer_initializing_formals
        _userAgentVersion = userAgentVersion;

  @override
  String get kind => 'r2';

  @override
  Future<ReleaseInfo> fetchLatest() async {
    final url = manifestUrl;
    try {
      final response = await _client
          .get(
            url,
            headers: {
              'Accept': 'application/json',
              'User-Agent': 'octodo/$_userAgentVersion',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(_timeout);
      if (response.statusCode == 404) {
        throw UpdateFeedException(
            'manifest not found at $url — check the '
            '`update.fallbackUrl` setting or that the CI uploaded it.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw UpdateFeedException('HTTP ${response.statusCode} from $url');
      }
      // `allowMalformed: true` keeps us alive on a rare payload with
      // a stray invalid UTF-8 byte. The release resolver surfaces
      // the same shape regardless of whether it came from GitHub or
      // R2 — that's the point of mirroring the schema.
      return resolveReleaseJson(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } on UpdateFeedException {
      rethrow;
    } on ResolverException catch (e) {
      throw UpdateFeedException(
          'Could not read R2 manifest: ${e.message}', e);
    } on TimeoutException catch (e) {
      throw UpdateFeedException(
          'Timed out after ${_timeout.inSeconds}s', e);
    } on SocketException catch (e) {
      throw UpdateFeedException('Network error: ${e.message}', e);
    } on http.ClientException catch (e) {
      throw UpdateFeedException('HTTP client error: ${e.message}', e);
    } on FormatException catch (e) {
      throw UpdateFeedException('Parse error: ${e.message}', e);
    } catch (e) {
      throw UpdateFeedException('Unexpected error', e);
    }
  }

  /// Fetch a sibling asset URL (typically `.sha256` sidecar). On R2
  /// these are ordinary public objects next to `manifest.json`, so
  /// this is a plain authenticated-less GET — exactly the same
  /// contract as [UpdateFeed.fetchSidecar] but routed through our
  /// own client so we can keep the timeout + exception mapping
  /// consistent.
  ///
  /// Routes through the injected [_client] (not a fresh one) so
  /// tests using `MockClient` can drive sidecar fetches without
  /// having to wire a second client.
  @override
  Future<String> fetchSidecar(Uri url) async {
    try {
      final req = http.Request('GET', url)
        ..headers['Accept'] = 'text/plain'
        ..headers['User-Agent'] = 'octodo/$_userAgentVersion';
      final resp = await _client.send(req).timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw UpdateFeedException(
            'HTTP ${resp.statusCode} from $url');
      }
      return (await resp.stream.bytesToString()).trim();
    } on UpdateFeedException {
      rethrow;
    } on TimeoutException catch (e) {
      throw UpdateFeedException(
          'Timed out after ${_timeout.inSeconds}s', e);
    } on SocketException catch (e) {
      throw UpdateFeedException('Network error: ${e.message}', e);
    } on http.ClientException catch (e) {
      throw UpdateFeedException('HTTP client error: ${e.message}', e);
    } on Exception catch (e) {
      throw UpdateFeedException('Could not fetch $url: $e', e);
    }
  }

  @override
  void dispose() {
    _client.close();
  }
}
