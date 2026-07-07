// Update orchestrator. Drives:
//   * Periodic background probe (every `autoCheck` interval) +
//     one-time initial probe.
//   * User-initiated flows: checkForUpdates, downloadLatest,
//     cancelDownload, applyDownloaded, skipVersion.
//
// The model ([UpdateStateModel]) is the single source of truth the
// UI reads from. The controller pushes transitions into it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:retry/retry.dart';

import '../log.dart';
import '../settings/settings_catalog.dart';
import '../settings/settings_runtime.dart';
import 'digest.dart';
import 'r2_update_feed.dart';
import 'release_resolver.dart';
import 'semver.dart';
import 'update_feed.dart';
import 'update_state.dart';

final Logger _log = moduleLogger('update.controller');

/// How long the "you're up to date" pill is shown before being
/// dismissed by the controller. Tuned to be readable but not
/// annoying when the user did a manual "Check now".
const Duration _kNotFoundFlash = Duration(milliseconds: 2500);

/// How long the helper-mode copy waits between `setInstalling()`
/// and the unconditional `exit(0)`. The helper reads its env
/// vars near the top of `main()`; this delay gives the helper
/// process enough time to start *before* the parent process
/// releases its install-dir file locks.
const Duration _kHelperStartupDelay = Duration(seconds: 2);

/// Single GET timeout for `.sha256` sidecar fetches. Matches
/// the 5 s timeout applied by both [UpdateFeed] and
/// [R2UpdateFeed] for their primary `fetchLatest` calls.
const Duration _kSidecarTimeout = Duration(seconds: 5);

/// Total attempts per source (1 initial + 2 retries) for both
/// the manifest probe and the zip download. The retry package's
/// backoff (400 ms, 800 ms, 1600 ms ... with ±25% jitter) is
/// short enough that the user-visible delay for a transient
/// blip stays under ~5 s in the worst case.
const int _kMaxAttemptsPerSource = 3;

/// Filename of the standalone helper exe spawned by [applyDownloaded].
/// Lives next to `octodo.exe` in the install dir. Compiled from
/// `tool/update_helper.dart`. See [_spawnHelper] for why a separate
/// binary is required.
const String _kHelperExeName = 'octodo_helper.exe';

class UpdateController {
  final UpdateStateModel model;
  final UpdateSettingsSection settings;
  final String userAgentVersion;

  /// Optional factory for the primary [UpdateFeedSource] (GitHub by
  /// default). Production callers leave this null and get the default
  /// `http.Client`-backed feed. Tests inject a `MockClient`-backed
  /// source here so they can drive probes deterministically without
  /// hitting the network.
  final UpdateFeedSource Function(
          String repository, String userAgentVersion)?
      primaryFeedFactory;

  /// Optional factory for the fallback [UpdateFeedSource]. Production
  /// callers leave this null — the controller instantiates
  /// [R2UpdateFeed] when the `update.fallbackUrl` setting is non-empty.
  /// Tests inject to assert fallback behavior without hitting R2.
  final UpdateFeedSource Function(
          Uri manifestUrl, String userAgentVersion)?
      fallbackFeedFactory;

  UpdateFeedSource? _primaryFeed;
  UpdateFeedSource? _fallbackFeed;

  /// The source that produced the release currently in
  /// `model.detected`. Used to route the `.sha256` sidecar fetch
  /// through whichever transport serves the source (R2 → R2,
  /// GitHub → GitHub). Updated whenever `_fetchWithFallback`
  /// returns successfully; reset on `model.reset()`.
  UpdateFeedSource? _currentReleaseSource;

  Timer? _probeTimer;
  Timer? _notFoundTimer;
  StreamSubscription<void>? _repoOverrideSub;
  StreamSubscription<void>? _autoCheckSub;
  StreamSubscription<void>? _fallbackUrlSub;
  bool _started = false;

  /// Single-flight probe guard. Set true while a probe is in
  /// flight (HTTP request outstanding); cleared in the finally
  /// block. Concurrent `checkForUpdates` / periodic timer calls
  /// see the flag and skip rather than racing two probes through
  /// the same model.
  bool _probeInFlight = false;

  /// Best-effort handle to the in-flight HTTP download. Used by
  /// [cancelDownload] so the user can abort a running download.
  StreamSubscription<List<int>>? _downloadSub;
  http.Client? _downloadClient;
  IOSink? _downloadSink;
  CancelToken? _downloadCancel;

  /// Persistent "skip this version" list. Read from disk at
  /// [start]; written to disk after every [skipVersion] call.
  Set<String> _skipList = {};
  late File _skipListFile;

  /// GitHub repository. Defaults to the public octodo repo, but
  /// the `update.repositoryOverride` setting lets forks / private
  /// builds point at their own.
  static const String _defaultRepository = 'invented-pro/octodo';

  /// Optional override for the persistent skip-list file path.
  /// Production callers leave this null and use the default
  /// `%APPDATA%/octodo/update_skipped.json` resolution. Tests pass
  /// a temp file to avoid colliding with whatever a real user has
  /// accumulated on their machine.
  final File Function()? skipListFileFactory;

  /// Optional override for the [http.Client] used by
  /// [_downloadAndVerify]. Production callers leave this null
  /// and a fresh `http.Client()` is constructed per attempt
  /// (cheap, and lets each retry start with a clean connection
  /// pool). Tests inject a `MockClient` so the retry chain can
  /// be exercised deterministically without hitting the network.
  final http.Client Function()? downloadClientFactory;

  /// Base for the exponential backoff between retry attempts.
  /// Production: 200 ms (the `package:retry` default — yields
  /// 400 ms / 800 ms gaps between attempts, ±25% jitter).
  /// Tests: typically [Duration.zero] so the suite stays fast even
  /// when 6+ attempts run sequentially (3 primary + 3 fallback).
  final Duration retryDelayFactor;

  UpdateController({
    required this.model,
    required this.settings,
    required this.userAgentVersion,
    this.primaryFeedFactory,
    this.fallbackFeedFactory,
    this.skipListFileFactory,
    this.downloadClientFactory,
    this.retryDelayFactor = const Duration(milliseconds: 200),
  });

  /// The default (and recommended) GitHub repo. Visible so the
  /// settings UI can show a "Reset" hint.
  static String get defaultRepository => _defaultRepository;

  /// Wrapper around the `retry` package that applies the
  /// project-wide defaults: 3 total attempts (1 initial + 2
  /// retries) and the controller's [retryDelayFactor] backoff.
  /// Used by both the probe path and the download path so the
  /// "3 retries on primary, then 3 on fallback" semantics apply
  /// uniformly.
  ///
  /// `retryIf` always returns true except for the internal
  /// [_DownloadCancelledException] sentinel — every other exception
  /// thrown by the feed/download paths is considered transient at
  /// this layer (network errors, 5xx, parse hiccups, mid-stream
  /// resets). The underlying feed classes have already translated
  /// low-level SocketException / TimeoutException / http.ClientException
  /// into [UpdateFeedException] before we get here, so the retry
  /// budget is the only signal we need to act on.
  Future<T> _withRetry<T>(
    Future<T> Function() fn, {
    required String label,
  }) {
    return retry(
      fn,
      maxAttempts: _kMaxAttemptsPerSource,
      delayFactor: retryDelayFactor,
      retryIf: (e) => e is! _DownloadCancelledException,
      onRetry: (e) {
        if (e is _DownloadCancelledException) return;
        _log.warning('$label retry: ${e.runtimeType}: $e');
      },
    );
  }

  String _resolveRepository() {
    final repo = SettingsRuntime.instance.store.get(settings.repository);
    if (repo.isNotEmpty) return repo;
    return _defaultRepository;
  }

  /// Resolves the `update.fallbackUrl` setting to an absolute
  /// http(s) URI. Returns `null` if the setting is empty, malformed,
  /// or non-http(s) — in all those cases the controller falls back
  /// to "no fallback", letting the GitHub error surface.
  Uri? _resolveFallbackUrl() {
    final raw = SettingsRuntime.instance.store.get(settings.fallbackUrl);
    if (raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        !parsed.isAbsolute ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      _log.warning(
          'update.fallbackUrl is not a valid http(s) URL: "$raw" — '
          'fallback disabled.');
      return null;
    }
    return parsed;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _skipListFile = (skipListFileFactory ?? _resolveSkipListFile)();
    await _readSkipList();

    _primaryFeed = _buildPrimaryFeed();
    _fallbackFeed = _buildFallbackFeed();

    _repoOverrideSub = SettingsRuntime.instance.store
        .watch(settings.repository)
        .listen((_) {
      _primaryFeed?.dispose();
      // NOTE: any in-flight request on the old client completes
      // against a closed socket. That's fine — the request
      // exception is caught at the call site and the next probe
      // re-issues against the fresh client.
      _primaryFeed = _buildPrimaryFeed();
      // If the release in `model.detected` was sourced from the
      // feed we just disposed, clear the routing pointer — otherwise
      // the next `downloadLatest()` would `fetchSidecar` on a
      // closed client and the user would see a misleading
      // "Download failed integrity check". Repopulated on the
      // next successful probe.
      _currentReleaseSource = null;
    });

    _fallbackUrlSub = SettingsRuntime.instance.store
        .watch(settings.fallbackUrl)
        .listen((_) {
      _fallbackFeed?.dispose();
      _fallbackFeed = _buildFallbackFeed();
      // Same routing-pointer invalidation as the primary watcher
      // — the disposed fallback feed's `http.Client` is closed, so
      // any cached reference is now useless.
      _currentReleaseSource = null;
    });

    _autoCheckSub = SettingsRuntime.instance.store
        .watch(settings.autoCheck)
        .listen((_) => _scheduleNextProbe());

    // Run the initial probe synchronously so `start()` returns
    // only after the boot probe has settled. Without this, a
    // manual `checkForUpdates()` immediately after `start()`
    // races the initial probe: the single-flight guard would
    // skip the manual click, leaving the user with no feedback.
    // The 5 s timeout in `UpdateFeed.fetchLatest` caps the
    // startup cost even on a hostile network.
    await _runProbe(showNotFound: false);
    _scheduleNextProbe();
  }

  UpdateFeedSource _buildPrimaryFeed() {
    final factory = primaryFeedFactory;
    if (factory != null) {
      return factory(_resolveRepository(), userAgentVersion);
    }
    return UpdateFeed(
      repository: _resolveRepository(),
      userAgentVersion: userAgentVersion,
    );
  }

  UpdateFeedSource? _buildFallbackFeed() {
    final url = _resolveFallbackUrl();
    if (url == null) return null;
    final factory = fallbackFeedFactory;
    if (factory != null) {
      return factory(url, userAgentVersion);
    }
    return R2UpdateFeed(
      manifestUrl: url,
      userAgentVersion: userAgentVersion,
    );
  }

  /// Probe primary, then optional fallback. Each source is given
  /// [_kMaxAttemptsPerSource] (3) attempts via the `retry` package
  /// before falling through. Throws primary's last exception if
  /// both fail — that's the one the user configured explicitly,
  /// so its error message is what reaches the UI.
  ///
  /// Sequence (per [Start background + periodic probe flow]):
  ///   1. Primary — up to 3 attempts (1 initial + 2 retries).
  ///   2. Fallback (if configured) — up to 3 attempts.
  ///   3. If both fail, propagate the primary's last error; the
  ///      periodic probe timer ([_scheduleNextProbe]) re-runs
  ///      the whole chain ~1 hour later.
  Future<ReleaseInfo> _fetchWithFallback() async {
    final resolved = await _fetchWithFallbackResolved();
    _currentReleaseSource = resolved.source;
    return resolved.release;
  }

  /// Inner probe that returns a [_ResolvedRelease] (carries the
  /// source alongside the release). Kept separate from
  /// [_fetchWithFallback] so the download path can re-derive the
  /// same source it should route sidecar fetches through when it
  /// falls back to the alternate URL mid-download.
  Future<_ResolvedRelease> _fetchWithFallbackResolved() async {
    final primary = _primaryFeed;
    if (primary == null) {
      throw UpdateFeedException('no primary feed configured');
    }
    try {
      final release = await _withRetry(
        () => primary.fetchLatest(),
        label: 'primary ${primary.kind}',
      );
      return _ResolvedRelease(release: release, source: primary);
    } on Object catch (primaryError) {
      final fallback = _fallbackFeed;
      if (fallback == null) rethrow;
      _log.warning(
          'Primary ${primary.kind} feed failed after '
          '$_kMaxAttemptsPerSource attempts (${primaryError.runtimeType}: '
          '${(primaryError is UpdateFeedException) ? primaryError.message : primaryError}); '
          'trying ${fallback.kind} fallback.');
      try {
        final release = await _withRetry(
          () => fallback.fetchLatest(),
          label: 'fallback ${fallback.kind}',
        );
        return _ResolvedRelease(release: release, source: fallback);
      } on Object catch (_) {
        // Both failed: surface the primary's error, since that's
        // the user's explicit configuration. The fallback's error
        // is recorded in the log at warning level above.
        rethrow;
      }
    }
  }

  /// Manual "Check now" button. Always surfaces results in the UI,
  /// even "you're up to date" (which auto-dismisses after 2.5s).
  ///
  /// Skips if a probe is already in flight (concurrent calls
  /// collapse into one) — but does *not* set the [UpdateState.
  /// checking] state in that case, so the UI is never stuck on a
  /// spinner because of a dropped click.
  Future<void> checkForUpdates() async {
    if (_primaryFeed == null || _probeInFlight) return;
    model.setState(UpdateState.checking);
    await _runProbe(showNotFound: true);
  }

  /// Download the asset the model currently has as [detected].
  /// Transitions: updateAvailable → downloading → downloaded (or
  /// → error).
  ///
  /// Reliability chain (per request): try the primary URL
  /// ([_kMaxAttemptsPerSource] attempts via [package:retry]); if
  /// all 3 fail, fetch the fallback feed's manifest (also 3
  /// attempts) and try its URL (3 more attempts); if both chains
  /// fail, surface the last error so the user can manually retry.
  /// The download stream itself has **no timeout** — package size
  /// and bandwidth are both unknown, and a stalled connection is
  /// detected via the stream's own error path (not a wall clock).
  ///
  /// Cancellation: a single [CancelToken] is shared across the
  /// whole chain, so clicking "Cancel" aborts whichever attempt is
  /// currently in flight and prevents the next retry from starting.
  Future<void> downloadLatest() async {
    final release = model.detected;
    if (release == null) return;

    final stagingDir = _resolveStagingDir(release.version);
    final zipPath = File(p.join(stagingDir.path, _stagedZipName(release)));

    model.setDownloading(
      release.version,
      receivedBytes: 0,
      totalBytes: release.zipSizeBytes,
    );

    _downloadCancel = CancelToken();

    // Primary attempt: source = whatever the probe produced.
    final primarySource = _currentReleaseSource;

    bool primaryOk = false;
    // Last error from the primary chain — preserved so the
    // terminal error UI can produce a specific message (network
    // vs. timeout vs. SHA-256 mismatch) instead of a generic
    // "Download failed". Only assigned when primaryOk stays false.
    Object? primaryFailure;
    try {
      await _withRetry(
        () => _downloadAndVerify(
          release: release,
          source: primarySource,
          zipPath: zipPath,
        ),
        label: 'primary download (${primarySource?.kind ?? "?"})',
      );
      primaryOk = true;
    } on _DownloadCancelledException {
      // User clicked Cancel — bail without falling back. The
      // cancelDownload() call already cleaned up the partial
      // staging dir and reset the model state.
      return;
    } on Object catch (primaryError) {
      primaryFailure = primaryError;
      _log.warning('Primary download failed after '
          '$_kMaxAttemptsPerSource attempts: $primaryError');
    }

    if (_downloadCancel?.cancelled == true) return;

    if (!primaryOk) {
      // Try the fallback feed. Need its URL — re-fetch the manifest
      // with the same retry budget, then attempt the download.
      final fallback = _fallbackFeed;
      if (fallback != null) {
        try {
          final fallbackRelease = await _withRetry(
            () => fallback.fetchLatest(),
            label: 'fallback ${fallback.kind} manifest for download',
          );
          if (fallbackRelease.version != release.version) {
            _log.warning('Fallback manifest version '
                '${fallbackRelease.version} does not match primary '
                '${release.version}; refusing to download from fallback.');
          } else {
            await _withRetry(
              () => _downloadAndVerify(
                release: fallbackRelease,
                source: fallback,
                zipPath: zipPath,
              ),
              label: 'fallback download (${fallback.kind})',
            );
            primaryOk = true;
          }
        } on _DownloadCancelledException {
          return;
        } on Object catch (fallbackError) {
          _log.warning('Fallback download chain failed: $fallbackError');
        }
      }
    }

    if (_downloadCancel?.cancelled == true) return;

    if (!primaryOk) {
      // Both chains exhausted (or no fallback configured). Mark
      // staging as failed and surface a tailored error message:
      // the headline wording depends on whether a fallback was
      // actually attempted, and on whether the failure looked like
      // a network blip, a timeout, or a SHA-256 mismatch (the
      // security-relevant signal).
      final fallbackConfigured = _fallbackFeed != null;
      final headline = _userFacingMessageForDownload(
        primaryFailure,
        fallbackConfigured: fallbackConfigured,
      );
      await _cleanupStaging(stagingDir);
      final fallbackKind = _fallbackFeed?.kind;
      final technicalDetails = fallbackKind == null
          ? 'Primary: ${primarySource?.kind ?? "?"} '
              '($_kMaxAttemptsPerSource attempts); no fallback configured.'
          : 'Primary: ${primarySource?.kind ?? "?"} '
              '($_kMaxAttemptsPerSource attempts); '
              'fallback: $fallbackKind '
              '($_kMaxAttemptsPerSource attempts each).';
      model.setError(UpdateErrorPayload(
        message: headline,
        technicalDetails: technicalDetails,
        onDownload: downloadLatest,
        onDismiss: () => model.reset(),
      ));
    }
  }

  /// Map the download chain's terminal error to a user-facing
  /// message. Three cases worth distinguishing:
  ///
  ///   * `DigestMismatchException` — the bytes landed but failed
  ///     the SHA-256 sidecar check. Security-relevant: a mismatch
  ///     implies either a corrupted download or a tampered asset.
  ///     Surfacing it distinctly lets the user distinguish "try
  ///     again" from "your connection is being meddled with".
  ///   * `TimeoutException` — the connection hung mid-stream.
  ///   * Anything else — generic network/HTTP error.
  ///
  /// [fallbackConfigured] decides whether the headline says
  /// "both sources" (true) or just "the download" (false). The
  /// common case in v1 is no fallback configured, so saying
  /// "both" when only one source was tried is misleading.
  String _userFacingMessageForDownload(
    Object? error, {
    required bool fallbackConfigured,
  }) {
    if (error is DigestMismatchException) {
      return 'Download failed integrity check. The downloaded file '
          'does not match the published SHA-256 — try again, and if '
          'it persists, report it.';
    }
    final generic = fallbackConfigured
        ? 'Download failed on both sources. Check your network and try again.'
        : 'Download failed. Check your network and try again.';
    return generic;
  }

  /// Inner unit of the download retry chain: open a stream from
  /// [release.zipUrl], pipe bytes to [zipPath], then verify via the
  /// source's `.sha256` sidecar (if any). The function is
  /// cancellation-aware — a user-cancelled run returns early
  /// without throwing, so the retry budget isn't spent on
  /// already-cancelled attempts.
  ///
  /// Throws [UpdateFeedException] (or any underlying
  /// SocketException / http.ClientException) on failure; the retry
  /// wrapper in [downloadLatest] handles the budget.
  ///
  /// Throws [_DownloadCancelledException] (which the retry
  /// wrapper short-circuits past — see [_withRetry]) when the
  /// user clicks Cancel before this attempt starts or while it's
  /// streaming. Without this throw, the retry chain would happily
  /// re-enter a cancelled run until the budget ran out.
  Future<void> _downloadAndVerify({
    required ReleaseInfo release,
    required UpdateFeedSource? source,
    required File zipPath,
  }) async {
    if (_downloadCancel?.cancelled == true) {
      throw const _DownloadCancelledException();
    }

    await zipPath.parent.create(recursive: true);
    final client = downloadClientFactory?.call() ?? http.Client();
    _downloadClient = client;
    final req = http.Request('GET', release.zipUrl)
      ..headers.addAll({
        'Accept': 'application/octet-stream',
        'User-Agent': 'octodo/$userAgentVersion',
      });
    final http.StreamedResponse resp;
    try {
      resp = await client.send(req);
    } catch (e) {
      client.close();
      _downloadClient = null;
      rethrow;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      client.close();
      _downloadClient = null;
      throw UpdateFeedException(
        'HTTP ${resp.statusCode} from ${release.zipUrl}',
      );
    }

    final declaredTotal = release.zipSizeBytes > 0
        ? release.zipSizeBytes
        : (resp.contentLength ?? 0);

    // Reset progress to 0 at the start of each attempt so the UI
    // doesn't show stale bytes from a previous (failed) attempt
    // while we're still establishing this connection.
    model.updateDownloadProgress(
      version: release.version,
      receivedBytes: 0,
      totalBytes: declaredTotal,
    );

    _downloadSink = zipPath.openWrite();
    var received = 0;
    _downloadSub = resp.stream.listen(
      (chunk) {
        if (_downloadCancel?.cancelled == true) return;
        _downloadSink!.add(chunk);
        received += chunk.length;
        model.updateDownloadProgress(
          version: release.version,
          receivedBytes: received,
          totalBytes: declaredTotal,
        );
      },
      onDone: () {},
      cancelOnError: true,
    );

    try {
      await _downloadSub!.asFuture<void>();
    } on Exception catch (e) {
      // Best-effort cleanup of the partial stream/sink. Rethrow so
      // the outer retry budget can take over (unless the user
      // cancelled, in which case we throw the cancel sentinel so
      // the retry wrapper doesn't spin another attempt).
      try {
        await _downloadSink?.close();
      } catch (_) {}
      _downloadSink = null;
      try {
        client.close();
      } catch (_) {}
      _downloadClient = null;
      _downloadSub = null;
      if (_downloadCancel?.cancelled == true) {
        throw const _DownloadCancelledException();
      }
      throw UpdateFeedException(
        'Download stream error: ${e.runtimeType}: $e',
        e,
      );
    }

    // All bytes received. Flush + close the file sink.
    try {
      await _downloadSink?.flush();
      await _downloadSink?.close();
    } catch (_) {
      // Best effort; the integrity check below will catch any
      // truncation via the SHA-256 mismatch.
    }
    _downloadSink = null;
    client.close();
    _downloadClient = null;
    _downloadSub = null;

    // Verify SHA-256 against the .sha256 sidecar if one was
    // advertised. A missing sidecar is allowed (older releases
    // may not have one); we trust TLS + the asset URL comes
    // from the source. We do log a warning so the gap is at
    // least visible in debug logs.
    //
    // The fetch routes through whichever source produced the zip
    // we just downloaded (passed as [source] above). When we
    // fell back to R2 mid-download, [source] is the R2 feed and
    // the sidecar is fetched from R2, never via GitHub's client.
    var digestVerified = false;
    if (release.digestUrl != null) {
      final expectedHex = await _fetchDigestSidecar(
        source: source,
        url: release.digestUrl!,
      );
      await verifySha256Hex(file: zipPath, expectedHex: expectedHex);
      digestVerified = true;
    } else {
      _log.warning(
        'Release ${release.version} has no .sha256 sidecar; '
        'installing without integrity check.',
      );
    }

    final size = await zipPath.length();
    model.setDownloaded(DownloadedPayload(
      version: release.version,
      zipPath: zipPath,
      sizeBytes: size,
      digestVerified: digestVerified,
    ));
  }

  /// Aborts an in-flight download. Returns the model to
  /// `updateAvailable` so the user can retry / skip / cancel.
  Future<void> cancelDownload() async {
    final cancel = _downloadCancel;
    if (cancel == null || cancel.cancelled) return;

    cancel.cancelled = true;
    await _downloadSub?.cancel();
    await _downloadSink?.close();
    _downloadClient?.close();

    final release = model.detected;
    if (release != null) {
      // Best-effort cleanup of the partial staging dir.
      try {
        final stagingDir = _resolveStagingDir(release.version);
        if (await stagingDir.exists()) {
          await stagingDir.delete(recursive: true);
        }
      } catch (_) {
        // Non-fatal; the next successful download overwrites.
      }
      model.setAvailable(release);
    }
  }

  /// Spawns the standalone helper executable (`octodo_helper.exe`)
  /// with the right env vars, then exits the original process. The
  /// helper reads its env vars at the top of its `main()`, applies
  /// the staged payload over the install dir, and relaunches the
  /// freshly-replaced `octodo.exe`.
  ///
  /// Why a *separate* exe (not `octodo.exe` with env vars):
  /// `octodo.exe` statically imports five plugin DLLs
  /// (`desktop_drop_plugin.dll`, `flutter_windows.dll`,
  /// `screen_retriever_windows_plugin.dll`,
  /// `url_launcher_windows_plugin.dll`, `window_manager_plugin.dll`).
  /// The Windows loader maps them into the process address space
  /// *before* `main()` runs, so a helper-mode spawn of `octodo.exe`
  /// cannot overwrite them — Windows returns `ERROR_ALREADY_EXISTS`
  /// (errno 183) on every retry attempt. The standalone helper
  /// (compiled from `tool/update_helper.dart`) doesn't link against
  /// any of those DLLs, so it can freely overwrite every file in the
  /// install dir.
  ///
  /// Sequence:
  ///   1. setInstalling() — UI shows "Restarting to apply update…".
  ///   2. spawn helper detached with env vars + current PID.
  ///   3. wait ~2s so the helper begins and notices it's in helper
  ///      mode (pre-empts file-lock collisions while we're alive).
  ///   4. exit(0) — the helper then extracts + copies + relaunches.
  Future<void> applyDownloaded() async {
    final d = model.downloaded;
    if (d == null) return;
    model.setInstalling();

    await _spawnHelper(version: d.version, pid: pid);

    // Visible "Restarting to apply update…" affordance. The
    // exit() below is unconditional — Flutter will tear down
    // the next event-loop turn.
    await Future<void>.delayed(_kHelperStartupDelay);

    exit(0);
  }

  /// Resolve the standalone helper exe path next to the running
  /// `octodo.exe`. Returns null if the file is absent — the caller
  /// surfaces a clear error in that case so the user knows to
  /// reinstall rather than retry blindly.
  File? _resolveHelperExe() {
    final installDir = p.dirname(Platform.resolvedExecutable);
    final helperPath = p.join(installDir, _kHelperExeName);
    final f = File(helperPath);
    return f.existsSync() ? f : null;
  }

  Future<void> _spawnHelper({
    required String version,
    required int pid,
  }) async {
    final helper = _resolveHelperExe();
    if (helper == null) {
      // Without the standalone helper exe we cannot safely apply
      // the update: the legacy in-process path (spawn octodo.exe
      // with env vars) hits the DLL-self-lock bug and corrupts the
      // install dir partway. Refuse with a clear error and no
      // retry button — the only recovery is to reinstall.
      final installDir = p.dirname(Platform.resolvedExecutable);
      model.setError(UpdateErrorPayload(
        message: 'Update helper is missing. Reinstall Octodo '
            'to apply this update.',
        technicalDetails:
            'Expected $_kHelperExeName next to octodo.exe at $installDir.',
        onDismiss: () => model.reset(),
      ));
      return;
    }
    try {
      await Process.start(
        helper.path,
        const <String>[],
        environment: <String, String>{
          'OCTODO_UPDATE_HELPER': '1',
          'OCTODO_UPDATE_PAYLOAD': version,
          'OCTODO_UPDATE_PID': pid.toString(),
        },
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      model.setError(UpdateErrorPayload(
        message: 'Could not start the update helper.',
        technicalDetails: e.toString(),
        // Hand the user a way back. Without `onRetry` the error
        // body's Retry button is hidden (see update_popover_view),
        // and the user is stuck after pressing "Restart to
        // install" — clicking "Close" only resets the state.
        onRetry: applyDownloaded,
        onDismiss: () => model.reset(),
      ));
    }
  }

  Future<void> skipVersion(String version) async {
    if (version.isEmpty) return;
    _skipList.add(version);
    await _writeSkipList();
    model.reset();
  }

  void _scheduleNextProbe() {
    _probeTimer?.cancel();
    _probeTimer = null;
    final autoCheck = SettingsRuntime.instance.store.get(settings.autoCheck);
    if (!autoCheck) return;
    _probeTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => _runProbe(showNotFound: false),
    );
  }

  Future<void> _runProbe({required bool showNotFound}) async {
    if (_probeInFlight) return;
    _probeInFlight = true;
    try {
      if (_primaryFeed == null) return;
      final autoCheck =
          SettingsRuntime.instance.store.get(settings.autoCheck);
      if (!autoCheck && !showNotFound) return;
      try {
        final release = await _fetchWithFallback();
        if (_isNewer(release.version, model.currentVersion) &&
            !_skipList.contains(release.version)) {
          model.setAvailable(release);
        } else {
          // No newer release available. Mark the persistent
          // "Latest" flag regardless of whether this was a
          // manual or background probe — the result is the same.
          model.markUpToDate();
          if (showNotFound) {
            _scheduleNotFoundFlash();
          } else {
            model.reset();
          }
        }
      } on UpdateFeedEmptyException {
        // Repo exists but has no published releases yet — this is
        // the same outcome as "you're up to date", just earlier in
        // the repo's life. Fall back to the idle / About view
        // rather than surface a confusing 'Update Failed' pill.
        model.markUpToDate();
        if (showNotFound) {
          _scheduleNotFoundFlash();
        } else {
          model.reset();
        }
      } on UpdateFeedException catch (e) {
        if (showNotFound) {
          model.setError(UpdateErrorPayload(
            message: _userFacingMessageForProbe(e),
            technicalDetails: e.toString(),
            onRetry: checkForUpdates,
            onDismiss: () => model.reset(),
          ));
        } else {
          // Background failure: silently record and stay idle.
          // The previous implementation routed these through
          // `setError`, which surfaced a yellow error pill on
          // every transient GitHub outage — clearly worse than
          // the original intent of "no error pill on every
          // transient outage, record the error internally".
          _log.warning('Background update probe failed: $e');
        }
      }
    } finally {
      _probeInFlight = false;
    }
  }

  /// Show the "you're up to date" state for [_kNotFoundFlash] and
  /// then auto-dismiss back to idle. Cancels any pending flash
  /// first so two probes back-to-back (e.g. an auto probe right
  /// after a manual one) don't compound timers that would
  /// otherwise clobber a later state.
  void _scheduleNotFoundFlash() {
    _notFoundTimer?.cancel();
    _notFoundTimer = null;
    model.setState(UpdateState.notFound);
    _notFoundTimer = Timer(_kNotFoundFlash, () {
      if (model.state == UpdateState.notFound) {
        model.reset();
      }
      _notFoundTimer = null;
    });
  }

  /// Maps a real [UpdateFeedException] to a user-facing message.
  /// [UpdateFeedEmptyException] no longer routes through this — the
  /// controller catches it earlier and falls back to the idle view.
  ///
  /// The fallback path always rethrows the primary's error, so a
  /// "Could not reach update feed." message after a fallback attempt
  /// is the user's primary GitHub error (since both failed). The
  /// wording here is generic on purpose: an `R2UpdateFeed` failure
  /// would only ever reach this method if both feed calls threw,
  /// in which case the primary's error is what we have.
  String _userFacingMessageForProbe(UpdateFeedException e) {
    if (e is UpdateFeedRateLimitException) {
      return _formatRateLimitMessage(e);
    }
    final raw = e.toString();
    if (raw.contains('Timed out')) return 'Update check timed out.';
    if (raw.contains('Network error')) {
      return 'Could not reach update feed.';
    }
    if (raw.contains('HTTP 4')) return 'Update feed is misconfigured.';
    if (raw.contains('HTTP 5')) return 'Update feed is having trouble.';
    if (raw.contains('Could not read the update feed')) {
      return 'Could not read the update feed.';
    }
    if (raw.contains('manifest not found')) {
      return 'Fallback update feed is unreachable.';
    }
    return 'Update check failed.';
  }

  /// Format a user-facing rate-limit message from the typed
  /// exception. Uses the `x-ratelimit-reset` timestamp to show
  /// a precise retry window. Falls back to a generic "in an
  /// hour" if the reset timestamp is missing or already past.
  String _formatRateLimitMessage(UpdateFeedRateLimitException e) {
    final wait = e.resetAt.difference(DateTime.now());
    if (wait.isNegative || wait.inMinutes < 1) {
      return 'GitHub rate limit hit. Try again shortly.';
    }
    if (wait.inHours >= 1) {
      final hours = wait.inHours;
      final mins = wait.inMinutes - hours * 60;
      if (mins == 0) {
        return 'GitHub rate limit hit. Try again in $hours h.';
      }
      return 'GitHub rate limit hit. Try again in ${hours}h ${mins}m.';
    }
    return 'GitHub rate limit hit. Try again in ${wait.inMinutes} min.';
  }

  bool _isNewer(String candidate, String current) =>
      compareSemver(candidate, current) > 0;

  void dispose() {
    _probeTimer?.cancel();
    _notFoundTimer?.cancel();
    _repoOverrideSub?.cancel();
    _autoCheckSub?.cancel();
    _fallbackUrlSub?.cancel();
    _primaryFeed?.dispose();
    _fallbackFeed?.dispose();
    _primaryFeed = null;
    _fallbackFeed = null;
    _currentReleaseSource = null;
    // Tear down any in-flight download so a half-written staging
    // file isn't leaked past dispose. We don't await the cancel —
    // dispose is called from widget teardown, which doesn't have
    // a future for us to await.
    unawaited(_downloadSub?.cancel());
    try {
      _downloadSink?.close();
    } catch (_) {
      // Sink close during teardown is best-effort.
    }
    _downloadClient?.close();
    _downloadSub = null;
    _downloadSink = null;
    _downloadClient = null;
    _downloadCancel = null;
    _probeInFlight = false;
  }

  // -- staging paths (Windows-friendly; mac/Linux paths are
  // best-effort because we don't auto-update those platforms) --

  Directory _resolveStagingDir(String version) {
    final base = _resolveAppLocalDir();
    final safeVer = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    return Directory(p.join(base.path, 'updates', safeVer));
  }

  File _resolveSkipListFile() {
    return File(p.join(_resolveAppRoamingDir().path, 'update_skipped.json'));
  }

  Directory _resolveAppLocalDir() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final local = env['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        return Directory(p.join(local, 'octodo'));
      }
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(p.join(home, '.octodo'));
    }
    return Directory.systemTemp.createTempSync('octodo_');
  }

  Directory _resolveAppRoamingDir() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final roaming = env['APPDATA'];
      if (roaming != null && roaming.isNotEmpty) {
        return Directory(p.join(roaming, 'octodo'));
      }
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(p.join(home, '.octodo'));
    }
    return Directory.systemTemp.createTempSync('octodo_');
  }

  String _stagedZipName(ReleaseInfo release) {
    final uri = Uri.parse(release.zipUrl.toString());
    final last = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : 'octodo-${release.version}-windows-x64.zip';
    return last;
  }

  Future<void> _cleanupStaging(Directory d) async {
    try {
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Fetch a `.sha256` sidecar via whichever source produced the
  /// current release — captured at probe-time into
  /// [_currentReleaseSource]. If for any reason that field is null
  /// (release came from a probe we don't track, e.g. a unit test that
  /// seeded the model directly), we fall back to a fresh short-lived
  /// `http.Client` so the path still works in tests.
  Future<String> _fetchDigestSidecar({
    required UpdateFeedSource? source,
    required Uri url,
  }) async {
    if (source != null) {
      try {
        return await source.fetchSidecar(url);
      } on UpdateFeedException {
        rethrow;
      } on Exception catch (e) {
        throw UpdateFeedException(
          'Could not fetch ${p.basename(url.pathSegments.last)} via '
          '${source.kind}: $e',
          e,
        );
      }
    }
    // Fallback path used only when the model was seeded outside of
    // the controller (test path). Cheap because the digest sidecar
    // is 64 bytes, but capped at the same 5 s timeout as the real
    // feeds so a hostile URL can't pin the staging dir in a
    // half-verified state.
    final client = http.Client();
    try {
      final req = http.Request('GET', url)
        ..headers['Accept'] = 'text/plain'
        ..headers['User-Agent'] = 'octodo/$userAgentVersion';
      final resp = await client.send(req).timeout(_kSidecarTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw UpdateFeedException('HTTP ${resp.statusCode} from $url');
      }
      return (await resp.stream.bytesToString()).trim();
    } on TimeoutException catch (e) {
      throw UpdateFeedException(
          'Timed out after ${_kSidecarTimeout.inSeconds}s', e);
    } on http.ClientException catch (e) {
      throw UpdateFeedException('HTTP client error: ${e.message}', e);
    } finally {
      client.close();
    }
  }

  Future<void> _readSkipList() async {
    try {
      if (!await _skipListFile.exists()) return;
      final raw = await _skipListFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _skipList = decoded.whereType<String>().toSet();
      }
    } catch (_) {
      // Corrupt file → ignore; skip-list starts empty.
      _skipList = {};
    }
  }

  Future<void> _writeSkipList() async {
    try {
      await _skipListFile.parent.create(recursive: true);
      await _skipListFile.writeAsString(jsonEncode(_skipList.toList()));
    } catch (_) {
      // Best-effort; we don't want a permission failure on the
      // skip-list file to break the user's update path.
    }
  }
}

/// Internal carrier for the result of [_fetchWithFallback]. The
/// download path uses [source] to route the `.sha256` sidecar
/// fetch through whichever feed produced [release], so the
/// fallback-to-R2 download branch can verify R2's zip against
/// R2's sidecar (not GitHub's).
class _ResolvedRelease {
  final ReleaseInfo release;
  final UpdateFeedSource source;

  const _ResolvedRelease({
    required this.release,
    required this.source,
  });
}

class CancelToken {
  bool cancelled = false;
}

/// Internal sentinel thrown by [_downloadAndVerify] when the user
/// has clicked Cancel. [`_withRetry`] is configured to NOT retry
/// on this exception, so the retry budget isn't burned on already-
/// cancelled attempts. [`downloadLatest`] catches it explicitly
/// and returns without falling back to the alternate feed.
class _DownloadCancelledException implements Exception {
  const _DownloadCancelledException();
}
