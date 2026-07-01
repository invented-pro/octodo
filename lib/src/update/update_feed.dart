// HTTP client for `GET /repos/{owner}/{repo}/releases/latest`.
//
// Single responsibility: GET the release JSON, return a parsed
// [ReleaseInfo], throw [UpdateFeedException] on any failure. We
// don't retry (caller handles backoff) and don't cache (GitHub's
// own CDN handles ETag / If-None-Match for us, but for a 1-hour
// poll rate with a hard `Cache-Control: no-cache` request, the
// cache hits are not worth the wiring).
//
// GitHub quirks handled here:
//   * UA header is REQUIRED by GitHub's API guidelines; we send
//     `octodo/<version>`.
//   * 404 is "no releases published yet" — surfaced as a typed
//     [UpdateFeedException] with a distinct message so the
//     controller can distinguish it from a real failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'release_resolver.dart';

class UpdateFeedException implements Exception {
  final String message;
  final Object? cause;
  const UpdateFeedException(this.message, [this.cause]);

  @override
  String toString() => cause == null
      ? 'UpdateFeedException: $message'
      : 'UpdateFeedException: $message ($cause)';
}

/// Distinct sub-type thrown when GitHub replies 404 ("Not Found")
/// to /releases/latest — i.e. the repo exists but has no published
/// release yet. This is *not* a failure: it means there's nothing
/// to update against, and the controller should fall back to the
/// idle / About view rather than surface an "Update Failed"
/// pill.
class UpdateFeedEmptyException extends UpdateFeedException {
  const UpdateFeedEmptyException(super.message, [super.cause]);
}

class UpdateFeed {
  /// GitHub "owner/repo" — e.g. `invented-pro/octodo`. Resolved
  /// from the `update.repositoryOverride` setting by
  /// [UpdateController]; defaults to the public octodo repo.
  final String repository;
  final http.Client _client;
  final Duration _timeout;

  /// Used in `User-Agent: octodo/<version>` per GitHub's API rules.
  /// Bumping this when the running app's version changes is what
  /// lets GitHub's rate-limit headers (`X-RateLimit-Remaining`)
  /// tie traffic to a specific release line.
  final String userAgentVersion;

  UpdateFeed({
    required this.repository,
    required this.userAgentVersion,
    http.Client? client,
    Duration timeout = const Duration(seconds: 5),
  })  : _client = client ?? http.Client(),
        // Private fields can't use the `this.x` initializer form,
        // so this lint is a false-positive — but suppressing it
        // inline keeps the code straight to read.
        // ignore: prefer_initializing_formals
        _timeout = timeout;

  /// Canonical URL of the "latest non-prerelease" release.
  Uri get latestReleaseUrl => Uri.parse(
        'https://api.github.com/repos/$repository/releases/latest',
      );

  Future<ReleaseInfo> fetchLatest() async {
    final url = latestReleaseUrl;
    try {
      final response = await _client
          .get(
            url,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'octodo/$userAgentVersion',
              'X-GitHub-Api-Version': '2022-11-28',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(_timeout);
      if (response.statusCode == 404) {
        throw UpdateFeedEmptyException(
          'No releases published yet for $repository',
        );
      }
      if (response.statusCode == 403 &&
          (response.body.contains('rate limit') ||
              response.headers['x-ratelimit-remaining'] == '0')) {
        throw const UpdateFeedException(
          'GitHub API rate limit hit. Try again in an hour.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw UpdateFeedException(
            'HTTP ${response.statusCode} from $url');
      }
      return resolveReleaseJson(utf8.decode(response.bodyBytes));
    } on UpdateFeedException {
      rethrow;
    } on ResolverException catch (e) {
      throw UpdateFeedException(
          'Could not read the update feed: ${e.message}', e);
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

  void dispose() {
    _client.close();
  }
}
