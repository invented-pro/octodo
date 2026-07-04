// Update feed abstraction + the GitHub concrete implementation.
//
// [UpdateFeedSource] is the small contract used by [UpdateController]:
// each probe iteration asks the source for the latest release, and the
// controller can wire a primary + fallback source so the in-app updater
// stays alive when GitHub itself is unreachable or rate-limited.
//
// [UpdateFeed] is the GitHub implementation (`kind = "github"`). It GETs
// `/repos/{owner}/{repo}/releases/latest`, recognises the typed
// rate-limit / empty / generic error cases, and feeds the body to the
// shared [resolveReleaseJson] parser.
//
// GitHub quirks handled in [UpdateFeed.fetchLatest]:
//   * UA header is REQUIRED by GitHub's API guidelines; we send
//     `octodo/<version>`.
//   * 404 is "no releases published yet" — surfaced as a typed
//     [UpdateFeedException] with a distinct message so the
//     controller can distinguish it from a real failure.
//   * 403 with `x-ratelimit-remaining: 0` is a rate-limit, typed as
//     [UpdateFeedRateLimitException] with reset timestamp + quota.

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

/// Distinct sub-type for GitHub rate-limit responses (HTTP 403
/// with `x-ratelimit-remaining: 0`). Carries the reset timestamp
/// and quota so the UI can show a precise retry window instead of
/// the generic "try again in an hour".
///
/// Thrown for unauthenticated requests (60/hour/IP). Shared IPs
/// (office, university, VPN, NAT) hit this frequently — the
/// error message intentionally does NOT blame the user, since
/// other apps on the same IP share the quota.
class UpdateFeedRateLimitException extends UpdateFeedException {
  /// UTC Unix timestamp from `x-ratelimit-reset` (seconds since
  /// epoch). Falls back to "now + 1 h" if the header is absent.
  final DateTime resetAt;

  /// Hourly quota from `x-ratelimit-limit`. Defaults to 60
  /// (unauthenticated GitHub REST API quota).
  final int limit;

  /// Calls remaining (`x-ratelimit-remaining`). Always 0 in
  /// practice — kept for diagnostics.
  final int remaining;

  const UpdateFeedRateLimitException({
    required this.resetAt,
    required this.limit,
    required this.remaining,
  }) : super('GitHub API rate limit hit.');

  @override
  String toString() {
    final resetIso = resetAt.toIso8601String();
    return 'UpdateFeedException: $message '
        '(limit=$limit, remaining=$remaining, reset=$resetIso)';
  }
}

class UpdateFeed implements UpdateFeedSource {
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

  @override
  String get kind => 'github';

  /// Canonical URL of the "latest non-prerelease" release.
  Uri get latestReleaseUrl => Uri.parse(
        'https://api.github.com/repos/$repository/releases/latest',
      );

  @override
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
      if (response.statusCode == 403) {
        // GitHub sends `x-ratelimit-remaining` and `x-ratelimit-reset`
        // on every API response. Treat a 403 with `remaining == 0`
        // as a definitive rate-limit hit. The fallback path
        // (header missing AND body mentions rate limit) is a
        // belt-and-braces guard against proxies that strip the
        // header — `contains('rate limit exceeded')` is a tighter
        // match than the previous substring so unrelated 403s
        // (private repo, suspended account) don't get
        // mis-classified.
        final remainingHeader =
            response.headers['x-ratelimit-remaining'];
        final remaining = int.tryParse(remainingHeader ?? '');
        final isDefiniteRateLimit = remaining == 0;
        final isFallbackRateLimit = remainingHeader == null &&
            response.body.contains('rate limit exceeded');
        if (isDefiniteRateLimit || isFallbackRateLimit) {
          final resetHeader = response.headers['x-ratelimit-reset'];
          final resetEpoch = int.tryParse(resetHeader ?? '');
          final resetAt = resetEpoch != null
              ? DateTime.fromMillisecondsSinceEpoch(resetEpoch * 1000)
              : DateTime.now().add(const Duration(hours: 1));
          final limit =
              int.tryParse(response.headers['x-ratelimit-limit'] ?? '') ??
                  60;
          throw UpdateFeedRateLimitException(
            resetAt: resetAt,
            limit: limit,
            remaining: remaining ?? 0,
          );
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw UpdateFeedException(
            'HTTP ${response.statusCode} from $url');
      }
      // `allowMalformed: true` keeps us alive on the rare payload
      // with a stray invalid UTF-8 byte. The release resolver
      // surfaces the same shape regardless.
      return resolveReleaseJson(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
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

  /// Fetch a sibling asset URL (typically `.sha256` sidecar) over
  /// GitHub. The url is whatever was advertised inside the resolved
  /// [ReleaseInfo.digestUrl] — usually `releases.githubusercontent.com`
  /// or `objects.githubusercontent.com`. No auth, plain GET, trimmed
  /// body returned as a String. Any non-2xx is rethrown as
  /// [UpdateFeedException].
  ///
  /// Routes through the injected [_client] (not a fresh one) so
  /// tests using `MockClient` can drive sidecar fetches without
  /// having to wire a second client.
  @override
  Future<String> fetchSidecar(Uri url) async {
    try {
      final req = http.Request('GET', url)
        ..headers['Accept'] = 'text/plain'
        ..headers['User-Agent'] = 'octodo/$userAgentVersion';
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

// ---------------------------------------------------------------------------
// [UpdateFeedSource] — small interface for a feed the controller probes.
//
// Two implementations exist:
//   * [UpdateFeed]              — GitHub `/releases/latest`, kind="github"
//   * `R2UpdateFeed` (in r2_update_feed.dart) — static manifest.json on
//                                an R2 bucket + custom domain, kind="r2"
//
// The controller wires a primary + optional fallback; if the primary
// throws any [UpdateFeedException] (including rate-limit), the fallback
// is tried. If both fail, the primary's error surfaces to the UI.
// ---------------------------------------------------------------------------

/// Contract implemented by every "where can I find the latest release"
/// source the in-app updater knows how to probe.
///
/// Each call to [fetchLatest] returns a parsed [ReleaseInfo] (shape
/// shared between GitHub's `/releases/latest` payload and the R2
/// mirror manifest) or throws an [UpdateFeedException] subclass — the
/// controller treats any of those uniformly as a primary-feed failure
/// that should trigger the fallback if one is configured.
abstract class UpdateFeedSource {
  /// Short identifier for diagnostics and logs. Stable per concrete
  /// implementation; never user-visible. Examples: `"github"`, `"r2"`.
  String get kind;

  /// Probe the source for its current latest release. May throw any
  /// [UpdateFeedException] subtype on a real failure — the controller
  /// catches all of them and falls back to the next configured source.
  Future<ReleaseInfo> fetchLatest();

  /// Fetch a raw asset body advertised inside a resolved release —
  /// used by the controller to pull the `.sha256` sidecar for digest
  /// verification before staging the zip for apply.
  ///
  /// Implementations route through whichever transport serves the
  /// source (so a sidecar hosted on R2 is fetched from R2, not via
  /// GitHub). Returns the body as a trimmed String; non-2xx is
  /// rethrown as an [UpdateFeedException].
  Future<String> fetchSidecar(Uri url);

  /// Release any underlying sockets/timers. Called from the
  /// controller's [UpdateController.dispose].
  void dispose();
}
