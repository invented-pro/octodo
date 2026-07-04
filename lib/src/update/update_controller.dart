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

  UpdateController({
    required this.model,
    required this.settings,
    required this.userAgentVersion,
    this.primaryFeedFactory,
    this.fallbackFeedFactory,
    this.skipListFileFactory,
  });

  /// The default (and recommended) GitHub repo. Visible so the
  /// settings UI can show a "Reset" hint.
  static String get defaultRepository => _defaultRepository;

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

  /// Probe primary, then optional fallback. Throws primary's
  /// exception if both fail — that's the one the user configured
  /// explicitly, so its error message is what reaches the UI.
  Future<ReleaseInfo> _fetchWithFallback() async {
    final primary = _primaryFeed;
    if (primary == null) {
      throw UpdateFeedException('no primary feed configured');
    }
    try {
      final release = await primary.fetchLatest();
      _currentReleaseSource = primary;
      return release;
    } on UpdateFeedException catch (primaryError) {
      final fallback = _fallbackFeed;
      if (fallback == null) rethrow;
      _log.warning(
          'Primary ${primary.kind} feed failed (${primaryError.message}); '
          'trying ${fallback.kind} fallback.');
      try {
        final release = await fallback.fetchLatest();
        _currentReleaseSource = fallback;
        return release;
      } on UpdateFeedException catch (_) {
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

    try {
      await stagingDir.create(recursive: true);
      final client = http.Client();
      _downloadClient = client;
      final req = http.Request('GET', release.zipUrl)
        ..headers.addAll({
          'Accept': 'application/octet-stream',
          'User-Agent': 'octodo/$userAgentVersion',
        });
      final resp = await client.send(req);

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw UpdateFeedException(
          'HTTP ${resp.statusCode} from ${release.zipUrl}',
        );
      }

      final declaredTotal = release.zipSizeBytes > 0
          ? release.zipSizeBytes
          : (resp.contentLength ?? 0);

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
      } on Exception catch (_) {
        if (_downloadCancel?.cancelled == true) {
          // Caller (cancelDownload) cleaned up; no error dialog.
          return;
        }
        rethrow;
      }

      // All bytes received. Flush + close the file sink.
      try {
        await _downloadSink?.flush();
        await _downloadSink?.close();
      } catch (_) {
        // Best effort; if close fails (locked file, broken pipe)
        // we still want to attempt the integrity check below —
        // the staging dir cleanup in the outer catch handles any
        // partial state.
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
      // The fetch routes through the source that advertised the
      // release (captured in `_currentReleaseSource` during the
      // successful `_fetchWithFallback`). A sidecar hosted on R2
      // is fetched from R2, never via GitHub's client.
      var digestVerified = false;
      if (release.digestUrl != null) {
        final expectedHex = await _fetchDigestSidecar(
          source: _currentReleaseSource,
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
    } catch (e) {
      // Clean up partial staging unless it was a user cancel.
      if (_downloadCancel?.cancelled != true) {
        await _cleanupStaging(stagingDir);
        model.setError(UpdateErrorPayload(
          message: _userFacingMessageForDownload(e),
          technicalDetails: e.toString(),
          onDownload: downloadLatest,
          onDismiss: () => model.reset(),
        ));
      }
    }
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

  /// Spawns a helper-mode copy of the running exe with the right
  /// env vars, then exits the original process. The helper detects
  /// the env var early in `main()`, applies the staged payload over
  /// the install dir, and relaunches the freshly-replaced exe.
  ///
  /// Sequence:
  ///   1. setInstalling() — UI shows "Restarting to apply update…".
  ///   2. spawn helper detached with env vars + currrent PID.
  ///   3. wait ~2s so the helper begins and notices it's in helper
  ///      mode (pre-empts file-lock collisions while we're alive).
  ///   4. exit(0) — the helper then copies + relaunches.
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

  Future<void> _spawnHelper({
    required String version,
    required int pid,
  }) async {
    final executable = Platform.resolvedExecutable;
    try {
      await Process.start(
        executable,
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

  String _userFacingMessageForDownload(Object e) {
    final raw = e.toString();
    if (raw.contains('Timed out')) return 'Download timed out.';
    if (raw.contains('Network error')) return 'Download interrupted.';
    if (raw.contains('DigestMismatchException')) {
      return 'Download failed integrity check.';
    }
    return 'Download failed.';
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

class CancelToken {
  bool cancelled = false;
}
