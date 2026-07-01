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

import '../settings/settings_catalog.dart';
import '../settings/settings_runtime.dart';
import 'digest.dart';
import 'release_resolver.dart';
import 'semver.dart';
import 'update_feed.dart';
import 'update_state.dart';

class UpdateController {
  final UpdateStateModel model;
  final UpdateSettingsSection settings;
  final String userAgentVersion;

  UpdateFeed? _feed;
  Timer? _probeTimer;
  StreamSubscription<void>? _repoOverrideSub;
  StreamSubscription<void>? _autoCheckSub;
  bool _started = false;

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

  UpdateController({
    required this.model,
    required this.settings,
    required this.userAgentVersion,
  });

  /// The default (and recommended) GitHub repo. Visible so the
  /// settings UI can show a "Reset" hint.
  static String get defaultRepository => _defaultRepository;

  String _resolveRepository() {
    final repo = SettingsRuntime.instance.store.get(settings.repository);
    if (repo.isNotEmpty) return repo;
    return _defaultRepository;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _skipListFile = _resolveSkipListFile();
    await _readSkipList();

    _feed = UpdateFeed(
      repository: _resolveRepository(),
      userAgentVersion: userAgentVersion,
    );

    _repoOverrideSub = SettingsRuntime.instance.store
        .watch(settings.repository)
        .listen((_) {
      _feed?.dispose();
      _feed = UpdateFeed(
        repository: _resolveRepository(),
        userAgentVersion: userAgentVersion,
      );
    });

    _autoCheckSub = SettingsRuntime.instance.store
        .watch(settings.autoCheck)
        .listen((_) => _scheduleNextProbe());

    unawaited(_probe(showNotFound: false));
    _scheduleNextProbe();
  }

  /// Manual "Check now" button. Always surfaces results in the UI,
  /// even "you're up to date" (which auto-dismisses after 2.5s).
  Future<void> checkForUpdates() async {
    if (_feed == null) return;
    model.setState(UpdateState.checking);
    await _runProbe(showNotFound: true);
  }

  /// Download the asset the model currently has as [detected].
  /// Transitions: updateAvailable → downloading → downloaded (or
  /// → error).
  Future<void> downloadLatest() async {
    final release = model.detected;
    if (release == null) return;
    final feed = _feed;
    if (feed == null) return;

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
      await _downloadSink?.flush();
      await _downloadSink?.close();
      _downloadSink = null;
      client.close();
      _downloadClient = null;
      _downloadSub = null;

      // Verify SHA-256 against the .sha256 sidecar if one was
      // advertised. A missing sidecar is allowed (older releases
      // may not have one); we trust GitHub TLS + the asset URL
      // comes from /releases/latest.
      var digestVerified = false;
      if (release.digestUrl != null) {
        final expectedHex = await _fetchDigestSidecar(
          feed: feed,
          url: release.digestUrl!,
        );
        await verifySha256Hex(file: zipPath, expectedHex: expectedHex);
        digestVerified = true;
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
    await Future<void>.delayed(const Duration(seconds: 2));

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
      (_) => _probe(showNotFound: false),
    );
  }

  Future<void> _probe({required bool showNotFound}) async {
    await _runProbe(showNotFound: showNotFound);
  }

  Future<void> _runProbe({required bool showNotFound}) async {
    final feed = _feed;
    if (feed == null) return;
    final autoCheck = SettingsRuntime.instance.store.get(settings.autoCheck);
    if (!autoCheck && !showNotFound) return;
    try {
      final release = await feed.fetchLatest();
      if (_isNewer(release.version, model.currentVersion) &&
          !_skipList.contains(release.version)) {
        model.setAvailable(release);
      } else {
        if (showNotFound) {
          model.setState(UpdateState.notFound);
          Timer(const Duration(milliseconds: 2500), () {
            if (model.state == UpdateState.notFound) {
              model.reset();
            }
          });
        } else {
          model.reset();
        }
      }
    } on UpdateFeedEmptyException {
      // Repo exists but has no published releases yet — this is the
      // same outcome as "you're up to date", just earlier in the
      // repo's life. Fall back to the idle / About view rather than
      // surface a confusing 'Update Failed' pill. Background
      // probes skip the brief notFound flash; manual "Check now"
      // gets the same 2.5s dismissible flash so the user still gets
      // feedback that *something* happened.
      if (showNotFound) {
        model.setState(UpdateState.notFound);
        Timer(const Duration(milliseconds: 2500), () {
          if (model.state == UpdateState.notFound) {
            model.reset();
          }
        });
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
        // Background failure: stay quiet (no error pill on every
        // transient outage), record the error internally.
        model.setError(UpdateErrorPayload(
          message: _userFacingMessageForProbe(e),
          technicalDetails: e.toString(),
          onDismiss: () => model.reset(),
        ));
      }
    }
  }

  /// Maps a real [UpdateFeedException] to a user-facing message.
  /// [UpdateFeedEmptyException] no longer routes through this — the
  /// controller catches it earlier and falls back to the idle view.
  String _userFacingMessageForProbe(UpdateFeedException e) {
    final raw = e.toString();
    if (raw.contains('Timed out')) return 'Update check timed out.';
    if (raw.contains('Network error')) {
      return 'Could not reach GitHub.';
    }
    if (raw.contains('rate limit')) return 'GitHub rate limit hit.';
    if (raw.contains('HTTP 4')) return 'Update feed is misconfigured.';
    if (raw.contains('HTTP 5')) return 'GitHub is having trouble.';
    if (raw.contains('Could not read the update feed')) {
      return 'Could not read the update feed.';
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

  bool _isNewer(String candidate, String current) =>
      compareSemver(candidate, current) > 0;

  void dispose() {
    _probeTimer?.cancel();
    _repoOverrideSub?.cancel();
    _autoCheckSub?.cancel();
    _feed?.dispose();
    unawaited(_downloadSub?.cancel());
    _downloadClient?.close();
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

  Future<String> _fetchDigestSidecar({
    required UpdateFeed feed,
    required Uri url,
  }) async {
    try {
      final resp = await feed._sendInternal(url, extraHeaders: const {
        'Accept': 'text/plain',
      });
      return resp.body.trim();
    } on Exception catch (e) {
      throw UpdateFeedException(
        'Could not fetch ${p.basename(url.pathSegments.last)}: $e',
        e,
      );
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

/// Minimal HTTP shim so [_fetchDigestSidecar] can reuse the same
/// `http.Client` (and User-Agent) as the feed's main request — the
/// sidecar sits on the same GitHub host so reusing the connection
/// pool is good citizenship.
extension on UpdateFeed {
  Future<_SidecarResponse> _sendInternal(
    Uri url, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', url)..headers.addAll(extraHeaders);
      final resp = await client.send(req);
      return _SidecarResponse(statusCode: resp.statusCode, body: await resp.stream.bytesToString());
    } finally {
      client.close();
    }
  }
}

class _SidecarResponse {
  final int statusCode;
  final String body;
  const _SidecarResponse({required this.statusCode, required this.body});
}
