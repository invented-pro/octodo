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

import '../app_info.dart';
import '../log.dart';
import '../settings/settings_catalog.dart';
import '../settings/settings_runtime.dart';
import 'digest.dart';
import 'distribution.dart';
import 'installer/crash_sentinel.dart';
import 'installer/macos_codesign.dart';
import 'installer/posix_apply_script.dart';
import 'manifest_signature.dart';
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

/// Filename of the standalone helper binary spawned by
/// [applyDownloaded] on Windows (`octodo.exe`'s dir). Compiled from
/// `tool/update_helper.dart`. See [_spawnHelper] for why a
/// separate binary is required there.
///
/// macOS does NOT use it: the Dart AOT helper gets killed by the
/// kernel under Hardened Runtime (see posix_apply_script.dart) —
/// the macOS apply runs through /bin/sh instead.
String get _kHelperExeName => 'octodo_helper.exe';

/// Cached signed-manifest body + the digest CI signed for the
/// helper exe on the current platform. Populated by the download
/// step (after the same body has been verified for the zip), so
/// the apply step can reuse the body without a second HTTPS round
/// trip or a second Ed25519 verify.
class _CachedHelperSig {
  final String body;
  final String helperDigestHex;
  const _CachedHelperSig({required this.body, required this.helperDigestHex});
}

class UpdateController {
  final UpdateStateModel model;
  final UpdateSettingsSection settings;
  final String userAgentVersion;

  /// The running app's distribution. The Store build cannot be
  /// self-updated (its install dir lives under the ACL-locked
  /// `WindowsApps`), so [downloadLatest] / [applyDownloaded]
  /// short-circuit when this is [InstallDistribution.store]; the
  /// UI is expected to route the user to the Store instead.
  /// Defaults to portable so existing call sites/tests keep
  /// working.
  final InstallDistribution distribution;

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

  /// Ed25519 public keys (base64) accepted for release-manifest
  /// signatures. Production leaves this null and the keys embedded
  /// in `manifest_signature.dart` apply. Tests inject a deterministic
  /// dev keypair's public half so MockClient-served fixtures can be
  /// signed without the production private key.
  final List<String>? signaturePublicKeys;

  UpdateFeedSource? _primaryFeed;
  UpdateFeedSource? _fallbackFeed;

  /// The source that produced the release currently in
  /// `model.detected`. Used to route the `.sha256` sidecar fetch
  /// through whichever transport serves the source (R2 → R2,
  /// GitHub → GitHub). Updated whenever `_fetchWithFallback`
  /// returns successfully; reset on `model.reset()`.
  UpdateFeedSource? _currentReleaseSource;

  /// In-memory cache of verified helper-signature (body + digest),
  /// keyed by the version whose helper hash they describe.
  /// Populated by [_downloadAndVerify] at the end of a successful
  /// download so the apply step can verify the on-disk helper
  /// without a fresh HTTPS fetch (and without re-running the
  /// Ed25519 verify). Never persisted: a fresh launch re-fetches
  /// from the URL stored on [DownloadedPayload.signatureUrl], so a
  /// tampered in-memory copy can't outlive the process.
  final Map<String, _CachedHelperSig> _verifiedHelperSigCache = {};

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

  /// Single-flight download guard. Set true while a download
  /// chain is in flight; cleared in the finally block of
  /// [downloadLatest]. Concurrent calls (a double-click before
  /// the popover swaps to the progress body, error-payload retry
  /// callbacks) see the flag and skip rather than racing two
  /// chains through the same model — concurrent chains would
  /// clobber the shared [_downloadSub] / [_downloadSink] /
  /// [_downloadClient] / [_downloadCancel] handles and interleave
  /// progress resets (each attempt restarts the bar at 0), which
  /// reads in the UI as multiple progress bars spinning in turn.
  bool _downloadInFlight = false;

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

  /// Optional override for the path of `octodo_helper.exe` (or
  /// `octodo_helper` on macOS, where the production apply goes
  /// through `/bin/sh` and the helper is unused). Production
  /// resolves next to [Platform.resolvedExecutable]; tests pass
  /// a temp file so the integrity check can be exercised without
  /// touching the real install dir (e.g. next to the
  /// `flutter_tester` host).
  final File? Function()? helperExeFactory;

  /// Optional override for [Process.start] used to spawn the
  /// update helper exe. Production leaves this null and uses
  /// `Process.start` directly; tests inject a no-op so the
  /// apply path can be exercised without actually launching a
  /// binary. Matches the same pattern in `posix_apply_script.dart`
  /// and `staged_apply.dart`.
  final Future<Process> Function(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required ProcessStartMode mode,
  })? processStartFactory;

  /// Optional override for the final `exit(0)` that
  /// [applyDownloaded] invokes after the helper is spawned.
  /// Production leaves this null and uses `dart:io`'s `exit`;
  /// tests pass a no-op so the test runner survives a successful
  /// apply. (Without this override the entire test process is
  /// torn down before subsequent tests can run.)
  final void Function(int code)? exitFactory;

  /// Base for the exponential backoff between retry attempts.
  /// Production: 200 ms (the `package:retry` default — yields
  /// 400 ms / 800 ms gaps between attempts, ±25% jitter).
  /// Tests: typically [Duration.zero] so the suite stays fast even
  /// when 6+ attempts run sequentially (3 primary + 3 fallback).
  final Duration retryDelayFactor;

  /// Minimum time the manual-check UI stays in the `checking`
  /// state before a result is surfaced. A sub-100 ms GitHub
  /// response otherwise flashes the "Checking…" pill for a frame,
  /// which reads as a glitch rather than a completed check.
  /// Background probes ignore this. Tests pass [Duration.zero].
  final Duration minCheckDisplay;

  /// Wall-clock budget for one probe's whole primary+fallback
  /// chain. Without it, 3 retries × 5 s timeout on each of the two
  /// sources can legitimately stretch a manual check past 30 s on
  /// a hostile network; past this budget the probe surfaces a
  /// timeout error instead of leaving the user on a spinner.
  final Duration probeTimeout;

  UpdateController({
    required this.model,
    required this.settings,
    required this.userAgentVersion,
    this.distribution = InstallDistribution.portable,
    this.primaryFeedFactory,
    this.fallbackFeedFactory,
    this.signaturePublicKeys,
    this.skipListFileFactory,
    this.downloadClientFactory,
    this.helperExeFactory,
    this.processStartFactory,
    this.exitFactory,
    this.retryDelayFactor = const Duration(milliseconds: 200),
    this.minCheckDisplay = const Duration(milliseconds: 600),
    this.probeTimeout = const Duration(seconds: 20),
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
  ///
  /// [UpdateIntegrityException] is ALSO non-retryable: a missing
  /// sidecar or unverified signature is a property of the release,
  /// not a transient — retrying burns 9 wasted zip+sidecar+sig
  /// fetches per source for the same refusal.
  Future<T> _withRetry<T>(
    Future<T> Function() fn, {
    required String label,
  }) {
    return retry(
      fn,
      maxAttempts: _kMaxAttemptsPerSource,
      delayFactor: retryDelayFactor,
      retryIf: (e) =>
          e is! _DownloadCancelledException && e is! UpdateIntegrityException,
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
  /// https URI. Returns `null` if the setting is empty, malformed,
  /// or non-https — in all those cases the controller falls back
  /// to "no fallback", letting the GitHub error surface.
  ///
  /// Only https is accepted. Plain http would let an on-path
  /// attacker observe update checks (privacy) or suppress them (DoS),
  /// and — even with the Ed25519 manifest signature in place — fail
  /// the user's "is there a new version?" probe indefinitely.
  /// Dropping the fallback is preferable to leaking either signal.
  Uri? _resolveFallbackUrl() {
    final raw = SettingsRuntime.instance.store.get(settings.fallbackUrl);
    if (raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        !parsed.isAbsolute ||
        parsed.scheme != 'https') {
      _log.warning(
          'update.fallbackUrl must be an https URL: "$raw" — '
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
      // Match the running platform's release asset
      // (windows-x64 / macos-arm64 / macos-x64). Injected
      // factories (tests) construct their own feeds with the
      // resolver default, which is why this lives here and not in
      // the feed constructor's default.
      assetToken: currentAssetToken(),
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
      assetToken: currentAssetToken(),
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
    _manualCheckStartedAt = DateTime.now();
    model.setState(UpdateState.checking);
    try {
      await _runProbe(showNotFound: true);
    } finally {
      // Reset even if an unexpected exception type escapes the
      // probe — a stale timestamp would wrongly apply the display
      // floor to the NEXT manual check.
      _manualCheckStartedAt = null;
    }
  }

  /// Timestamp of the in-flight manual "Check now" click, used to
  /// enforce the [minCheckDisplay] floor. Null for background
  /// probes.
  DateTime? _manualCheckStartedAt;

  /// Hold the `checking` state for at least [minCheckDisplay] after
  /// a manual check began, so a fast probe result doesn't flash the
  /// spinner for a single frame. No-op for background probes and
  /// when the floor is already elapsed.
  Future<void> _holdCheckingFloor() async {
    final start = _manualCheckStartedAt;
    if (start == null) return;
    final elapsed = DateTime.now().difference(start);
    final remaining = minCheckDisplay - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
  }

  /// Download the asset the model currently has as [detected].
  /// Transitions: updateAvailable → downloading → downloaded (or
  /// → error).
  ///
  /// Skips if a download chain is already in flight (concurrent
  /// calls collapse into one), mirroring the probe path's
  /// [_probeInFlight] guard.
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
    if (distribution == InstallDistribution.store) {
      // Store builds can't self-apply: the install dir is
      // ACL-locked and `octodo_helper.exe` isn't present. The UI
      // must route to the Store instead; reaching this method on
      // a Store build is a programming error.
      _log.warning('downloadLatest() called on a Store distribution; '
          'the UI should open the Store URL instead.');
      return;
    }
    if (_downloadInFlight) return;
    _downloadInFlight = true;
    try {
      await _runDownloadChain();
    } finally {
      _downloadInFlight = false;
    }
  }

  /// The primary-then-fallback download chain behind
  /// [downloadLatest]'s single-flight guard.
  Future<void> _runDownloadChain() async {
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
      // The terminal failure itself is quoted in the details so a
      // fail-closed refusal (missing sidecar, missing/untrusted
      // signature, digest mismatch) is attributable from the UI —
      // these are security-relevant signals, not generic blips.
      final technicalDetails = fallbackKind == null
          ? 'Primary: ${primarySource?.kind ?? "?"} '
              '($_kMaxAttemptsPerSource attempts); no fallback configured.\n'
              'Last error: $primaryFailure\n'
              '${_feedDiagnostics()}'
          : 'Primary: ${primarySource?.kind ?? "?"} '
              '($_kMaxAttemptsPerSource attempts); '
              'fallback: $fallbackKind '
              '($_kMaxAttemptsPerSource attempts each).\n'
              'Last error: $primaryFailure\n'
              '${_feedDiagnostics()}';
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
    // Deterministic integrity refusals (missing sidecar, missing
    // signature, signature does not verify, signed digest disagrees
    // with the sidecar) are NOT network blips — they won't recover
    // on retry and a "check your network" message misleads the user
    // into looping. Surface the actual nature.
    if (error is UpdateIntegrityException) {
      return 'Update refused: this release did not pass integrity '
          'verification. See the technical details, and check the '
          'release page or report this.';
    }
    if (error is DigestMismatchException) {
      return 'Download failed integrity check. The downloaded file '
          'does not match the published SHA-256 — try again, and if '
          'it persists, report it.';
    }
    // A cleanly-closed early stream (proxy timeout, flaky wifi)
    // reads differently from a hard network failure — the bytes
    // WERE arriving. Surfaced distinctly so the retry hint makes
    // sense to the user.
    if (error is UpdateFeedException && error.message.contains('truncated')) {
      return 'Download was interrupted before it finished. '
          'Check your network and try again.';
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
    final connectToken = _downloadCancel;
    try {
      // Race the connect against cancellation too: `client.close()`
      // aborts pending sends on the real `http.Client`, but not on
      // every client (e.g. test mocks) — without this race a Cancel
      // issued while the request is still connecting would leave the
      // chain suspended here forever.
      resp = await (connectToken == null
          ? client.send(req)
          : Future.any<http.StreamedResponse>([
              client.send(req),
              connectToken.whenCancelled.then(
                (_) => throw const _DownloadCancelledException(),
              ),
            ]));
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
      // Race the stream against cancellation: `asFuture()` never
      // completes on an externally-cancelled subscription, so a
      // mid-stream Cancel must arrive via the token's future for
      // this await to ever return. Throwing the sentinel here
      // routes through the catch below, which cleans up the
      // partial sink/client and re-throws it for the retry
      // wrapper to short-circuit on.
      final token = _downloadCancel;
      final streamDone = _downloadSub!.asFuture<void>();
      await (token == null
          ? streamDone
          : Future.any<void>([streamDone, token.whenCancelled]));
      if (token?.cancelled ?? false) {
        throw const _DownloadCancelledException();
      }
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

    // Truncation guard. A server (or an intercepting proxy) can
    // close the body stream CLEANLY before all bytes arrive — the
    // listen/onDone path above then completes without error and the
    // UI would otherwise hand a short zip to the apply step. This
    // exact failure shipped to a macOS host in Aug 2026: a 26.5 MB
    // asset downloaded as 23.5 MB with no error surfaced, and the
    // apply died in zip extraction. Only a STRICT deficit fails —
    // receiving more than declared is legal (e.g. a transport
    // decoding gzip) and must not break a good download.
    if (declaredTotal > 0 && received < declaredTotal) {
      throw UpdateFeedException(
        'Download truncated: received $received of '
        '$declaredTotal bytes from ${release.zipUrl}',
      );
    }

    // Integrity chain (GH issue #5, items 2+3 — all fail-closed):
    //
    //   1. The `.sha256` sidecar MUST exist. A missing sidecar used
    //      to install with a log warning; now it refuses. Every
    //      release the workflow has published for years ships one,
    //      so the tolerance only ever helped an attacker strip it.
    //   2. The release MUST publish an `octodo-v<ver>-manifest.sig`
    //      Ed25519 signature asset, and the sidecar's digest must be
    //      covered by a valid signature against the public keys
    //      embedded in this build. The sidecar alone defends against
    //      corruption; the signature is what defends against a
    //      compromised feed/GitHub account/R2 bucket serving a
    //      malicious zip with a MATCHING hash.
    //   3. Only then is the on-disk zip hashed and compared.
    //
    // Sidecar and signature both route through whichever source
    // produced the zip (passed as [source] above) — GitHub → GitHub,
    // R2 → R2.
    final digestUrl = release.digestUrl;
    if (digestUrl == null) {
      throw UpdateIntegrityException(
        'Release ${release.version} publishes no .sha256 sidecar; '
        'refusing to install without an integrity check.',
      );
    }
    final sigUrl = release.signatureUrl;
    if (sigUrl == null) {
      throw UpdateIntegrityException(
        'Release ${release.version} publishes no signed manifest '
        '(octodo-v${release.version}-manifest.sig); refusing to '
        'install an unsigned update.',
      );
    }
    final expectedHex =
        await _fetchTextAsset(source: source, url: digestUrl);
    final String sigBody;
    try {
      sigBody = await _fetchTextAsset(source: source, url: sigUrl);
    } on UpdateFeedException catch (e) {
      // 4xx on the signature asset means the release was published
      // without a signature — deterministic, not transient. Surface
      // as an integrity refusal so `_withRetry` doesn't burn the
      // full 3-per-source budget re-downloading the zip + sidecar.
      // 5xx stays as transient and is left to the retry wrapper.
      if (_isHttpClientError(e)) {
        throw UpdateIntegrityException(
          'Release ${release.version} signature file is missing on '
          'the feed (${e.message.split(' ').take(2).join(' ')}); '
          'refusing to install an update without a verifiable '
          'signature.',
          e,
        );
      }
      rethrow;
    }
    try {
      await verifyAssetSignature(
        body: sigBody,
        version: release.version,
        assetName: release.assetName,
        digestHex: expectedHex,
        publicKeysBase64: signaturePublicKeys,
      );
    } on UpdateSignatureException catch (e) {
      throw UpdateIntegrityException(
        'Update signature check failed: ${e.reason}',
        e,
      );
    }
    // Also pre-verify the helper entry so the apply step doesn't
    // pay a second Ed25519 verify. If the manifest predates the
    // helper gate (no helper line), skip — the apply step will
    // re-fetch + re-verify and surface the same error then.
    try {
      final helperDigestHex = await verifyAssetSignature(
        body: sigBody,
        version: release.version,
        assetName: helperAssetNameForCurrentPlatform(),
        publicKeysBase64: signaturePublicKeys,
      );
      _verifiedHelperSigCache[release.version] =
          _CachedHelperSig(body: sigBody, helperDigestHex: helperDigestHex);
    } on UpdateSignatureException {
      // No helper entry, or wrong sig — handled at apply time.
    }
    final actualHex = await verifySha256Hex(
      file: zipPath,
      expectedHex: expectedHex,
    );

    final size = await zipPath.length();
    model.setDownloaded(DownloadedPayload(
      version: release.version,
      zipPath: zipPath,
      sizeBytes: size,
      digestVerified: true,
      // The signature-verified digest rides with the payload so the
      // apply paths can re-hash the staged zip right before
      // extraction (TOCTOU: the staging dir is user-writable, and
      // any same-user process could otherwise swap the file between
      // this check and the helper running).
      expectedDigestHex: actualHex,
      // The signature asset URL for this release (fork-aware —
      // update.repositoryOverride produces a non-default URL that
      // the apply step must reuse if its in-memory cache is lost
      // between download and apply).
      signatureUrl: release.signatureUrl,
    ));
  }

  /// Aborts an in-flight download. Returns the model to
  /// `updateAvailable` so the user can retry / skip / cancel.
  Future<void> cancelDownload() async {
    final cancel = _downloadCancel;
    if (cancel == null || cancel.cancelled) return;

    // Complete the token's future FIRST so the suspended download
    // chain (racing its stream future against `whenCancelled`)
    // unwinds and releases the single-flight guard.
    cancel.cancel();
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

  /// Spawns the apply orchestrator, then exits the original
  /// process. The orchestrator waits for our exit, replaces the
  /// install, and relaunches the new version.
  ///
  ///   * Windows — `octodo_helper.exe` applies the staged payload
  ///     per-file over the install dir (see [_spawnHelper] for why
  ///     a separate binary is required).
  ///   * macOS — `/bin/sh` + a generated script swaps the .app
  ///     bundle (see [_spawnPosixApply] and
  ///     posix_apply_script.dart for why the bundled Dart helper
  ///     cannot be used there).
  ///
  /// Sequence:
  ///   1. pre-apply checks — everything that can fail WITHOUT
  ///      quitting must fail HERE, while the UI can still show an
  ///      error (staged zip still present; on macOS: running from
  ///      a .app bundle and its parent dir writable).
  ///   2. setInstalling() — UI shows "Restarting to apply update…".
  ///   3. spawn the orchestrator detached (sh + script on macOS;
  ///      helper exe with env vars + current PID on Windows).
  ///   4. wait ~2s so the orchestrator begins (pre-empts file-lock
  ///      collisions while we're alive).
  ///   5. exit(0) — it then extracts + applies + relaunches.
  Future<void> applyDownloaded() async {
    if (distribution == InstallDistribution.store) {
      _log.warning('applyDownloaded() called on a Store distribution; '
          'ignored — Store builds update via the Store.');
      return;
    }
    final d = model.downloaded;
    if (d == null) return;

    final preCheckError = _preApplyCheck(d);
    if (preCheckError != null) {
      model.setError(preCheckError);
      return;
    }

    model.setInstalling();

    final spawned = await _spawnHelper(
      version: d.version,
      pid: pid,
      expectedDigestHex: d.expectedDigestHex,
    );
    if (!spawned) return;

    await Future<void>.delayed(_kHelperStartupDelay);

    (exitFactory ?? exit)(0);
  }

  /// Everything that must be verified BEFORE the app quits. Each
  /// failure returns an [UpdateErrorPayload] the UI can surface
  /// while the app is still alive; a null return means "safe to
  /// proceed". Once the process exits there is no UI left, so any
  /// predictable failure mode belongs here instead of in the
  /// helper.
  ///
  /// All platforms: the staged zip still exists at the path
  /// recorded at download time — a cleaned temp dir would
  /// otherwise quit the app and silently do nothing.
  ///
  /// macOS only: the running executable lives inside a `.app`
  /// bundle (the bundle-swap apply is undefined otherwise), and the
  /// bundle's parent directory is writable (a read-only install
  /// location can't be swapped into; the user needs the manual
  /// download instead).
  UpdateErrorPayload? _preApplyCheck(DownloadedPayload d) {
    if (!d.zipPath.existsSync()) {
      return UpdateErrorPayload(
        message: 'The downloaded update file is missing. '
            'Download it again to update.',
        technicalDetails: 'Staged zip no longer present at '
            '${d.zipPath.path}.\n'
            'Manual download: $kAppRepositoryReleases',
        onRetry: () => model.reset(),
        onDismiss: () => model.reset(),
      );
    }
    if (!Platform.isMacOS) return null;

    final bundleRoot = macAppBundleRoot(Platform.resolvedExecutable);
    if (bundleRoot == null) {
      return UpdateErrorPayload(
        message: 'Octodo must run from its Octodo.app bundle to '
            'self-update. Reinstall from the download page.',
        technicalDetails: 'Running executable is not inside a .app '
            'bundle: ${Platform.resolvedExecutable}\n'
            'Manual download: $kAppRepositoryReleases',
        onRetry: () => model.reset(),
        onDismiss: () => model.reset(),
      );
    }

    final installDir = File(bundleRoot).parent.path;
    if (!_isDirectoryWritable(installDir)) {
      return UpdateErrorPayload(
        message: 'Octodo cannot update automatically — the folder '
            'holding Octodo.app is not writable. Download the new '
            'version manually.',
        technicalDetails: 'Install dir not writable: $installDir\n'
            'Manual download: $kAppRepositoryReleases',
        onRetry: applyDownloaded,
        onDismiss: () => model.reset(),
      );
    }
    return null;
  }

  /// Best-effort writability probe: create + delete a uniquely
  /// named temp file in [dir]. Directory mode bits can mislead on
  /// ACL-mounted volumes, so an actual write is the only
  /// trustworthy answer.
  bool _isDirectoryWritable(String dir) {
    try {
      final probe = File(p.join(
        dir,
        '.octodo_write_probe_${DateTime.now().millisecondsSinceEpoch}',
      ));
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resolve the standalone helper binary path next to the running
  /// executable and verify its hash against the signed release
  /// manifest before returning it (Windows only — the macOS apply
  /// runs through /bin/sh and needs no helper binary).
  ///
  /// Returns null if the file is absent (the caller surfaces the
  /// reinstall error). Throws [UpdateIntegrityException] if the
  /// helper on disk does not match the hash the release workflow
  /// signed for the CURRENT version — i.e. the file at this path
  /// has been tampered with since the last update installed it.
  /// `applyDownloaded` catches that exception and surfaces the
  /// same Reinstall flow as the missing-helper case.
  ///
  /// Trust chain:
  ///   * helper asset name is platform-specific
  ///     ([kHelperAssetNameWindows] / [kHelperAssetNameMacOS]);
  ///   * the line in `octodo-v<ver>-manifest.sig` is signed by the
  ///     same Ed25519 key as the zip digest (Phase B);
  ///   * the signed message includes the version, so an old
  ///     version's sig body can't be replayed against a newer
  ///     install;
  ///   * the helper at this path is the one the running app's own
  ///     apply step extracted from a Phase-B-verified zip, so the
  ///     initial-install trust anchor is the embedded public key.
  ///
  /// The macOS apply goes through /bin/sh (Apple-signed) and
  /// never invokes this helper, but the manifest still pins the
  /// helper hash for parity / future-proofing.
  Future<File?> _resolveAndVerifyHelperExe({
    required String version,
  }) async {
    if (!Platform.isWindows) {
      // macOS production apply runs through /bin/sh; the helper
      // binary is unused. _spawnHelper short-circuits to
      // _spawnPosixApply before reaching here, so this branch is
      // a belt-and-braces guard.
      return null;
    }
    final installDir = p.dirname(Platform.resolvedExecutable);
    final helperPath = p.join(installDir, _kHelperExeName);
    final f = helperExeFactory?.call() ?? File(helperPath);
    if (!f.existsSync()) return null;

final helperAssetName = helperAssetNameForCurrentPlatform();
    final cached = await _fetchVerifiedHelperSigBody(
      version: version,
      helperAssetName: helperAssetName,
      signatureUrl: model.downloaded?.signatureUrl,
    );
    final expectedHex = cached.helperDigestHex;

    final actualHex = await sha256HexOfFile(f);
    if (actualHex.toLowerCase() != expectedHex.toLowerCase()) {
      throw UpdateIntegrityException(
        'Update helper at $helperPath has been modified since this '
        'build of Octodo was installed (on-disk=$actualHex, '
        'signed=$expectedHex). The apply step cannot safely spawn '
        'it. Reinstall Octodo from the download page to apply '
        'future updates.',
      );
    }
    return f;
  }

  /// Fetch (and Ed25519-verify) the signed manifest body containing
  /// the helper hash line for [version].
  ///
  /// Lookup order:
  ///   1. In-memory [_verifiedHelperSigCache] (populated at download
  ///      time — no HTTPS round-trip, no second Ed25519 verify).
  ///   2. The [signatureUrl] captured on [DownloadedPayload] at
  ///      download time (fork-aware: a custom `update.repositoryOverride`
  ///      produces a non-default URL that the apply step must reuse,
  ///      not a hardcoded `github.com/invented-pro/...` mirror).
  ///
  /// The cache is in-memory only — a fresh launch re-fetches from
  /// the stored URL. A tampered local copy therefore can't outlive
  /// the process.
  Future<_CachedHelperSig> _fetchVerifiedHelperSigBody({
    required String version,
    required String helperAssetName,
    required Uri? signatureUrl,
  }) async {
    final hit = _verifiedHelperSigCache[version];
    if (hit != null) return hit;

    if (signatureUrl == null) {
      // Legacy payload (test/older build) without a captured URL,
      // and no in-memory cache. Refuse to spawn rather than fall
      // back to a hardcoded mirror — that would silently break
      // forks and re-introduce the cross-repo-attacker surface.
      throw UpdateIntegrityException(
        'Cannot verify the on-disk helper: the signed manifest URL '
        'for this build is no longer in memory and the in-memory '
        'cache is empty. Re-trigger the update to rebuild it.',
      );
    }

    final body = await _fetchSigBodyFromUrl(signatureUrl);
    final helperDigestHex = await verifyAssetSignature(
      body: body,
      version: version,
      assetName: helperAssetName,
      publicKeysBase64: signaturePublicKeys,
    );
    final entry = _CachedHelperSig(body: body, helperDigestHex: helperDigestHex);
    _verifiedHelperSigCache[version] = entry;
    return entry;
  }

  Future<String> _fetchSigBodyFromUrl(Uri url) async {
    // Reuse [downloadClientFactory] so a single MockClient can route
    // both the zip download and the helper-sig fetch in tests.
    final client = downloadClientFactory?.call() ?? http.Client();
    final ownsClient = downloadClientFactory == null;
    try {
      final req = http.Request('GET', url)
        ..headers['Accept'] = 'text/plain'
        ..headers['User-Agent'] = 'octodo/$userAgentVersion';
      final resp = await client.send(req).timeout(_kSidecarTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw UpdateFeedException(
            'HTTP ${resp.statusCode} from $url');
      }
      return (await resp.stream.bytesToString()).trim();
    } on TimeoutException catch (e) {
      throw UpdateFeedException(
          'Timed out after ${_kSidecarTimeout.inSeconds}s', e);
    } on http.ClientException catch (e) {
      throw UpdateFeedException('HTTP client error: ${e.message}', e);
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// Spawns the apply orchestrator, then the caller exits the
  /// original process. The orchestrator waits for our exit,
  /// replaces the install, and relaunches the new version.
  ///
  ///   * macOS — `/bin/sh` with a generated script (see
  ///     [_spawnPosixApply]). The bundled Dart helper
  ///     (`octodo_helper`) is NOT exec'd: the Dart AOT runtime
  ///     writes its own code pages at boot, and macOS Hardened
  ///     Runtime enforces W^X, so the kernel kills the helper ~50 ms
  ///     after exec ("CODE SIGNING: rejecting invalid page",
  ///     wpmapped:1) — the bug where the app quit, nothing was
  ///     applied, and manual relaunch showed the old version.
  ///     /bin/sh + ditto + open are all Apple-signed OS binaries,
  ///     immune to Gatekeeper / HR kills (same property that makes
  ///     cmux's Sparkle updater reliable).
  ///
  ///   * Windows — the standalone helper exe
  ///     (`octodo_helper.exe`, compiled from tool/update_helper.dart):
  ///     `octodo.exe` statically imports plugin DLLs that Windows
  ///     locks into the process address space before `main()` runs,
  ///     so the app cannot overwrite them in-place; the helper links
  ///     against none of them and can.
  Future<bool> _spawnHelper({
    required String version,
    required int pid,
    required String? expectedDigestHex,
  }) async {
    if (Platform.isMacOS) {
      return _spawnPosixApply(pid: pid);
    }
    final File helper;
    try {
      final resolved = await _resolveAndVerifyHelperExe(version: version);
      if (resolved == null) {
        // Without the standalone helper exe we cannot safely apply
        // the update: the legacy in-process path (spawn octodo.exe
        // with env vars) hits the DLL-self-lock bug and corrupts the
        // install dir partway. Refuse with a clear error and no
        // retry button — the only recovery is to reinstall.
        final installDir = p.dirname(Platform.resolvedExecutable);
        model.setError(UpdateErrorPayload(
          message: 'Update helper is missing. Reinstall Octodo '
              'to apply this update.',
          technicalDetails: 'Expected $_kHelperExeName next to the '
              'running executable at $installDir.\n'
              'Manual download: $kAppRepositoryReleases',
          onDismiss: () => model.reset(),
        ));
        return false;
      }
      helper = resolved;
    } on UpdateIntegrityException catch (e) {
      // The helper at the canonical path doesn't match the hash
      // CI signed for this version. Most likely the on-disk file
      // was tampered with (per-user install, attacker with write
      // access to the install dir) — refuse to spawn it.
      _log.severe('helper integrity check failed: ${e.message}');
      model.setError(UpdateErrorPayload(
        message: 'Update refused: the on-disk helper did not pass '
            'integrity verification. Reinstall Octodo to apply '
            'future updates.',
        technicalDetails: '${e.message}\n'
            'Manual download: $kAppRepositoryReleases',
        onDismiss: () => model.reset(),
      ));
      return false;
    } on UpdateSignatureException catch (e) {
      // Same UX as the integrity-mismatch case: the helper can't be
      // trusted. Surface as a Reinstall — same shape as the
      // missing-helper path. The dedicated "integrity verification"
      // headline keeps the user from misdirecting to a network
      // check.
      _log.severe('helper signature verification failed: ${e.reason}');
      model.setError(UpdateErrorPayload(
        message: 'Update refused: the helper signature did not pass '
            'integrity verification. Reinstall Octodo to apply '
            'future updates.',
        technicalDetails: '${e.reason}\n'
            'Manual download: $kAppRepositoryReleases',
        onDismiss: () => model.reset(),
      ));
      return false;
    }
    try {
      final startProc = processStartFactory ??
          ((
            String executable,
            List<String> arguments, {
            required Map<String, String> environment,
            required ProcessStartMode mode,
          }) async =>
              Process.start(
            executable,
            arguments,
            environment: environment,
            mode: mode,
          ));
      await startProc(
        helper.path,
        const <String>[],
        environment: <String, String>{
          'OCTODO_UPDATE_HELPER': '1',
          'OCTODO_UPDATE_PAYLOAD': version,
          'OCTODO_UPDATE_PID': pid.toString(),
          // The signature-verified digest — the helper re-hashes the
          // staged zip against this before extracting (TOCTOU
          // close; see DownloadedPayload.expectedDigestHex). Sourced
          // from the captured DownloadedPayload, NOT from
          // `model.downloaded`, so an intervening setError/reset
          // can't drop the entry and silently downgrade the apply
          // to the legacy-skip path.
          'OCTODO_UPDATE_DIGEST_HEX': ?expectedDigestHex,
        },
        mode: ProcessStartMode.detached,
      );
      return true;
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
      return false;
    }
  }

  /// macOS apply: write the POSIX apply script into the staging
  /// dir and spawn `/bin/sh` detached with the runtime values as
  /// argv. The script (see posix_apply_script.dart) waits for our
  /// pid to exit, ditto-extracts the staged zip, swaps the .app
  /// bundle, and relaunches it via Launch Services.
  ///
  /// Any failure here (script write, spawn) surfaces an error
  /// payload while the GUI is still alive — same contract as the
  /// Windows helper path.
  Future<bool> _spawnPosixApply({required int pid}) async {
    final d = model.downloaded;
    if (d == null) return false;
    final bundleRootPath = macAppBundleRoot(Platform.resolvedExecutable);
    // Defensive: _preApplyCheck already refuses non-bundle macOS
    // runs before we get here.
    if (bundleRootPath == null) {
      model.setError(UpdateErrorPayload(
        message: 'Octodo must run from its Octodo.app bundle to '
            'self-update. Reinstall from the download page.',
        technicalDetails: 'Running executable is not inside a .app '
            'bundle: ${Platform.resolvedExecutable}\n'
            'Manual download: $kAppRepositoryReleases',
        onRetry: () => model.reset(),
        onDismiss: () => model.reset(),
      ));
      return false;
    }
    final stagingDir = d.zipPath.parent;
    try {
      // Phase C (macOS): resolve the code-signature requirement to
      // enforce — non-null only when the RUNNING bundle satisfies
      // the pinned Team ID itself (inheritance rule; see
      // macos_codesign.dart). Dev/ad-hoc/fork builds skip the gate,
      // official signed builds always verify their successor.
      String? codeSignRequirement;
      if (Platform.isMacOS) {
        codeSignRequirement = await resolveEnforcedCodeSignRequirement(
          runningBundlePath: bundleRootPath,
        );
        _log.info(codeSignRequirement == null
            ? 'macOS apply: codesign gate skipped (running bundle does '
                'not satisfy the pin, or gate disabled)'
            : 'macOS apply: codesign gate armed');
      }
      await spawnPosixApply(
        pid: pid,
        zipFile: d.zipPath,
        extractDir: Directory(p.join(stagingDir.path, 'extracted')),
        bundleRoot: Directory(bundleRootPath),
        scriptFile: File(p.join(stagingDir.path, 'apply.sh')),
        sentinelFile: resolveHelperCrashSentinelFile(),
        homeDir: Platform.environment['HOME'] ?? '/',
        // The sh script re-hashes the staged zip against this
        // (shasum -a 256) right before ditto extraction — closes the
        // download→apply TOCTOU the same way the Windows helper's
        // OCTODO_UPDATE_DIGEST_HEX does.
        expectedDigestHex: d.expectedDigestHex,
        codeSignRequirement: codeSignRequirement,
      );
      return true;
    } catch (e) {
      model.setError(UpdateErrorPayload(
        message: 'Could not start the update helper.',
        technicalDetails: e.toString(),
        // Hand the user a way back — without `onRetry` the error
        // body's Retry button is hidden and the user is stuck
        // after pressing "Restart to install".
        onRetry: applyDownloaded,
        onDismiss: () => model.reset(),
      ));
      return false;
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
        // Bound the whole primary+fallback chain: without this the
        // 3+3 retry budget × 5 s HTTP timeouts can hold a manual
        // check (and the startup probe) past 30 s on a hostile
        // network. `.timeout` completes the await early; the
        // abandoned retry chain settles harmlessly into the void.
        final release = await _fetchWithFallback().timeout(
              probeTimeout,
              onTimeout: () => throw UpdateFeedException(
                'Update check timed out after '
                '${probeTimeout.inSeconds}s.',
              ),
            );
        if (_isNewer(release.version, model.currentVersion) &&
            !_skipList.contains(release.version)) {
          if (showNotFound) await _holdCheckingFloor();
          model.setAvailable(release);
        } else {
          // No newer release available. Mark the persistent
          // "Latest" flag regardless of whether this was a
          // manual or background probe — the result is the same.
          if (showNotFound) await _holdCheckingFloor();
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
        if (showNotFound) await _holdCheckingFloor();
        model.markUpToDate();
        if (showNotFound) {
          _scheduleNotFoundFlash();
        } else {
          model.reset();
        }
      } on TimeoutException {
        // The `.timeout` wrapper above throws its own
        // UpdateFeedException, but an unconverted TimeoutException
        // could still escape a feed implementation — treat it the
        // same so it never leaks to the caller as an unhandled
        // async error.
        if (showNotFound) await _holdCheckingFloor();
        model.setError(UpdateErrorPayload(
          message: 'Update check timed out.',
          technicalDetails:
              'Timed out after ${probeTimeout.inSeconds}s.\n${_feedDiagnostics()}',
          onRetry: checkForUpdates,
          onDismiss: () => model.reset(),
        ));
      } on UpdateFeedException catch (e) {
        if (showNotFound) await _holdCheckingFloor();
        if (showNotFound) {
          model.setError(UpdateErrorPayload(
            message: _userFacingMessageForProbe(e),
            technicalDetails: '$e\n${_feedDiagnostics()}',
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

  /// One-line summary of the configured feeds for error payloads —
  /// when a release feed is mispublished (the class of failure
  /// cmux's Sparkle 4005 incident made famous), the source + repo
  /// in the "Copy details" text is the difference between a
  /// fixable report and a shrug.
  String _feedDiagnostics() {
    final primary = _primaryFeed;
    final fallback = _fallbackFeed;
    final parts = <String>[
      if (primary != null) 'primary=${primary.kind} (${_resolveRepository()})',
      if (fallback != null) 'fallback=${fallback.kind}',
    ];
    return parts.isEmpty ? 'no feeds configured' : parts.join(', ');
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
    // a future for us to await. Cancelling the token also wakes
    // the suspended chain so it can unwind into its cleanup path.
    _downloadCancel?.cancel();
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
    _downloadInFlight = false;
  }

  // -- staging paths (Windows: %LOCALAPPDATA%; macOS: ~/Library/
  // Application Support; other POSIX: ~/.octodo best-effort) --

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
    if (Platform.isMacOS) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return Directory(
          p.join(home, 'Library', 'Application Support', 'Octodo'),
        );
      }
    }
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
    if (Platform.isMacOS) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return Directory(
          p.join(home, 'Library', 'Application Support', 'Octodo'),
        );
      }
    }
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

  String _stagedZipName(ReleaseInfo release) =>
      release.assetName;

  Future<void> _cleanupStaging(Directory d) async {
    try {
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {
      // Non-fatal.
    }
  }

  /// True when [e] is a 4xx response from the feed (the resource is
  /// definitively missing or forbidden — not a transient network
  /// failure). Used to route sig/sidecar 4xx into
  /// `UpdateIntegrityException` so the retry wrapper doesn't burn
  /// the full 3-per-source budget on a misconfigured release.
  bool _isHttpClientError(UpdateFeedException e) =>
      RegExp(r'^HTTP 4\d\d ').hasMatch(e.message);

  /// Fetch a small text asset (`.sha256` sidecar or `.sig` signature
  /// manifest) via whichever source produced the current release —
  /// captured at probe-time into [_currentReleaseSource]. If for any
  /// reason that field is null (release came from a probe we don't
  /// track, e.g. a unit test that seeded the model directly), we fall
  /// back to a fresh short-lived `http.Client` so the path still
  /// works in tests.
  Future<String> _fetchTextAsset({
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

/// Cancellation handle shared across one download chain. Besides
/// the flag the retry logic polls, [cancel] completes an internal
/// future — required because `StreamSubscription.asFuture()` never
/// completes on an externally-cancelled subscription, so the
/// download chain races its stream future against [whenCancelled]
/// to unwind after a mid-stream Cancel (otherwise the suspended
/// `await` would hang forever and the single-flight guard would
/// never release).
class CancelToken {
  bool cancelled = false;
  final Completer<void> _done = Completer<void>();

  /// Future that completes when [cancel] is first called.
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _done.complete();
  }
}

/// Internal sentinel thrown by [_downloadAndVerify] when the user
/// has clicked Cancel. [`_withRetry`] is configured to NOT retry
/// on this exception, so the retry budget isn't burned on already-
/// cancelled attempts. [`downloadLatest`] catches it explicitly
/// and returns without falling back to the alternate feed.
class _DownloadCancelledException implements Exception {
  const _DownloadCancelledException();
}
