// The update state machine.
//
// Phases:
//   * [idle]              — no update known; pill hidden.
//   * [checking]          — probe in flight.
//   * [updateAvailable]   — manifest reported a newer version; the
//                           popover shows a "Download" button.
//   * [downloading]       — bytes in flight; the popover shows a
//                           progress bar and a Cancel button.
//   * [downloaded]        — payload staged + verified; the popover
//                           prompts the user to "Restart to install".
//   * [installing]        — the helper process is running; the popover
//                           is disabled with a spinner + "Restarting…".
//   * [notFound]          — probe completed, we're up to date.
//                           Auto-dismissed by the controller so it
//                           never reaches the UI.
//   * [error]             — probe or download failed.
//
// All UI reads from this model through getters (`state`, `detected`,
// `progress`, `downloaded`, `error`, `currentVersion`); no widget
// reaches into the private fields. The controller drives transitions
// via `setState`, `setAvailable`, `setDownloading`, `setDownloaded`,
// `setInstalling`, `setError`, `reset`.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'release_resolver.dart';

enum UpdateState {
  idle,
  checking,
  updateAvailable,
  downloading,
  downloaded,
  installing,
  notFound,
  error,
}

@immutable
class DownloadProgress {
  final String version;
  final int receivedBytes;
  final int totalBytes;
  const DownloadProgress({
    required this.version,
    required this.receivedBytes,
    required this.totalBytes,
  });

  /// 0.0..1.0. Returns 0 when [totalBytes] is unknown (zero or
  /// negative) so the progress bar shows "starting…" instead of
  /// "indeterminate / 0%".
  double get fraction {
    if (totalBytes <= 0) return 0;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  DownloadProgress copyWith({
    String? version,
    int? receivedBytes,
    int? totalBytes,
  }) =>
      DownloadProgress(
        version: version ?? this.version,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
      );
}

@immutable
class DownloadedPayload {
  final String version;
  final File zipPath;
  final int sizeBytes;
  final bool digestVerified;
  const DownloadedPayload({
    required this.version,
    required this.zipPath,
    required this.sizeBytes,
    required this.digestVerified,
  });
}

@immutable
class UpdateErrorPayload {
  final String message;
  final String? technicalDetails;
  final VoidCallback? onRetry;
  final VoidCallback? onDownload;
  final VoidCallback? onRetryDownload;
  final VoidCallback? onDismiss;
  const UpdateErrorPayload({
    required this.message,
    this.technicalDetails,
    this.onRetry,
    this.onDownload,
    this.onRetryDownload,
    this.onDismiss,
  });
}

/// Source of truth for the update UI. All UI reads happen through
/// getters; transitions happen through the `set*` methods on a
/// controller-side timer or after async work.
class UpdateStateModel extends ChangeNotifier {
  UpdateState _state = UpdateState.idle;
  ReleaseInfo? _release;
  DownloadProgress? _progress;
  DownloadedPayload? _downloaded;
  UpdateErrorPayload? _error;
  final String _currentVersion;
  DateTime? _lastCheck;

  /// Persistent "you're up to date" flag — true once any probe
  /// (initial, periodic, or manual) has confirmed the running
  /// version matches or exceeds the published release. Cleared
  /// whenever a newer release is detected or the probe fails
  /// (uncertainty). Independent of the transient [UpdateState]
  /// — the 2.5 s `notFound` flash and the idle state both leave
  /// this flag alone.
  bool _isUpToDate = false;

  UpdateStateModel({required String currentVersion})
      // ignore: prefer_initializing_formals
      : _currentVersion = currentVersion;

  UpdateState get state => _state;
  ReleaseInfo? get detected => _release;
  DownloadProgress? get progress => _progress;
  DownloadedPayload? get downloaded => _downloaded;
  UpdateErrorPayload? get error => _error;
  String get currentVersion => _currentVersion;
  DateTime? get lastCheck => _lastCheck;

  /// True when the most recent probe confirmed no newer release
  /// is available. Stays true across the [UpdateState.notFound]
  /// → [UpdateState.idle] transition so the UI can keep showing
  /// the "Latest" indicator.
  bool get isUpToDate => _isUpToDate;

  /// True when the pill should be visible. [UpdateState.notFound] is
  /// intentionally hidden — the controller auto-dismisses it after
  /// 2.5s.
  bool get showsPill {
    switch (_state) {
      case UpdateState.idle:
      case UpdateState.notFound:
        return false;
      case UpdateState.checking:
      case UpdateState.updateAvailable:
      case UpdateState.downloading:
      case UpdateState.downloaded:
      case UpdateState.installing:
      case UpdateState.error:
        return true;
    }
  }

  /// Pill label. Localized here (kept in sync with the popover).
  String get text {
    switch (_state) {
      case UpdateState.idle:
      case UpdateState.notFound:
        return '';
      case UpdateState.checking:
        return 'Checking for updates…';
      case UpdateState.updateAvailable:
        return 'Update available: ${_release?.version ?? _currentVersion}';
      case UpdateState.downloading:
        final p = _progress;
        if (p == null || p.totalBytes <= 0) {
          return 'Downloading update…';
        }
        return 'Downloading ${_formatBytes(p.receivedBytes)} of '
            '${_formatBytes(p.totalBytes)}';
      case UpdateState.downloaded:
        return 'Restart to install ${_downloaded?.version ?? ''}'.trim();
      case UpdateState.installing:
        return 'Restarting to apply update…';
      case UpdateState.error:
        return 'Update check failed';
    }
  }

  IconData? get iconName {
    switch (_state) {
      case UpdateState.idle:
      case UpdateState.notFound:
        return null;
      case UpdateState.checking:
        return Icons.sync;
      case UpdateState.updateAvailable:
        return Icons.system_update_alt;
      case UpdateState.downloading:
        return Icons.downloading;
      case UpdateState.downloaded:
        return Icons.restart_alt;
      case UpdateState.installing:
        return Icons.restart_alt;
      case UpdateState.error:
        return Icons.error_outline;
    }
  }

  String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Stream<UpdateState> get stateChanges => _changesCtrl.stream;
  final StreamController<UpdateState> _changesCtrl =
      StreamController<UpdateState>.broadcast();

  void setState(UpdateState newState) {
    if (newState == _state) return;
    _state = newState;
    _scrubSidePayloads(newState);
    _lastCheck = DateTime.now();
    _changesCtrl.add(newState);
    notifyListeners();
  }

  void setAvailable(ReleaseInfo release) {
    // Short-circuit when the controller re-pushes the same release
    // (e.g. a 1 h periodic probe that finds nothing new). Skipping
    // the rebuild avoids an AnimatedBuilder pass over the drawer
    // pill for every redundant probe.
    if (_state == UpdateState.updateAvailable &&
        _release != null &&
        _release!.version == release.version &&
        _release!.zipUrl == release.zipUrl) {
      return;
    }
    _release = release;
    _state = UpdateState.updateAvailable;
    _progress = null;
    _downloaded = null;
    _error = null;
    _isUpToDate = false;
    _lastCheck = DateTime.now();
    _changesCtrl.add(_state);
    notifyListeners();
  }

  void setDownloading(String version, {int receivedBytes = 0, int totalBytes = 0}) {
    _state = UpdateState.downloading;
    _progress = DownloadProgress(
      version: version,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    );
    _error = null;
    _changesCtrl.add(_state);
    notifyListeners();
  }

  void updateDownloadProgress({
    required String version,
    required int receivedBytes,
    required int totalBytes,
  }) {
    if (_state != UpdateState.downloading) return;
    _progress = DownloadProgress(
      version: version,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    );
    notifyListeners();
  }

  void setDownloaded(DownloadedPayload payload) {
    _downloaded = payload;
    _state = UpdateState.downloaded;
    _progress = null;
    _error = null;
    _changesCtrl.add(_state);
    notifyListeners();
  }

  void setInstalling() {
    if (_state != UpdateState.downloaded &&
        _state != UpdateState.updateAvailable) {
      // Strict; reinstall only from a known-good payload.
      return;
    }
    _state = UpdateState.installing;
    _changesCtrl.add(_state);
    notifyListeners();
  }

  void setError(UpdateErrorPayload payload) {
    _error = payload;
    _state = UpdateState.error;
    _release = null;
    _progress = null;
    _downloaded = null;
    // Error means uncertainty about whether a newer release is
    // available — drop the "Latest" indicator until the next
    // probe comes back clean.
    _isUpToDate = false;
    _lastCheck = DateTime.now();
    _changesCtrl.add(_state);
    notifyListeners();
  }

  /// Mark the running app as confirmed up to date. Called by
  /// the controller from the "probe returned no newer release"
  /// branch (whether the probe was background or manual).
  /// Idempotent — short-circuits if the flag is already set so
  /// the periodic 1 h probe doesn't trigger spurious rebuilds.
  void markUpToDate() {
    if (_isUpToDate) return;
    _isUpToDate = true;
    notifyListeners();
  }

  void reset() {
    _state = UpdateState.idle;
    _release = null;
    _progress = null;
    _downloaded = null;
    _error = null;
    _changesCtrl.add(_state);
    notifyListeners();
  }

  void _scrubSidePayloads(UpdateState newState) {
    if (newState != UpdateState.updateAvailable &&
        newState != UpdateState.downloading &&
        newState != UpdateState.downloaded) {
      _release = null;
    }
    if (newState != UpdateState.downloading) {
      _progress = null;
    }
    if (newState != UpdateState.downloaded &&
        newState != UpdateState.installing) {
      _downloaded = null;
    }
    if (newState != UpdateState.error) {
      _error = null;
    }
  }

  @override
  void dispose() {
    _changesCtrl.close();
    super.dispose();
  }
}
