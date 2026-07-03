// Single-file JSONC settings store. Watches the file for external
// edits via a poll loop (dart:io doesn't have a reliable file
// watcher on Windows; the polling interval is 250ms which is
// imperceptible for human edits and cheap for an idle app).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import '../log.dart';
import 'jsonc.dart';
import 'setting.dart';
import 'settings_store.dart';

final Logger _log = moduleLogger('settings.json_store');

/// Result of the off-isolate initial load. Bundled into a record so
/// it round-trips through `Isolate.run` (records are sendable).
typedef _LoadResult = ({
  Map<String, Object?> values,
  DateTime mtime,
  int size,
  Object? error,
});

class JsonSettingsStore implements SettingsStore {
  final File _file;
  final _values = <String, Object?>{};
  final _controllers = <String, StreamController<dynamic>>{};
  final StreamController<Object> _loadErrorsCtrl =
      StreamController<Object>.broadcast();
  Timer? _watcher;
  DateTime _lastMtime = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSize = -1;

  // ── Construction ────────────────────────────────────────────────

  /// Private constructor used by the async [create] factory. The
  /// initial values + the file's mtime/size are pre-resolved on a
  /// background isolate (so the UI isolate isn't blocked by a sync
  /// file read at startup) and the file watcher is started here on
  /// the UI isolate.
  JsonSettingsStore._({
    required this._file,
    required Map<String, Object?> initialValues,
    required DateTime initialMtime,
    required int initialSize,
  })  : _lastMtime = initialMtime,
        _lastSize = initialSize {
    _values.addAll(initialValues);
    _startWatcher();
  }

  /// Async factory: reads + parses the settings file on a
  /// background isolate, then returns a fully-loaded store on the
  /// UI isolate. This is the only public way to build a
  /// [JsonSettingsStore] — the previous sync constructor blocked
  /// the UI isolate for ~5–50 ms at startup (file read + JSONC
  /// parse), which is enough to drop a frame on a cold disk or
  /// large file.
  ///
  /// The watcher (250 ms `statSync` poll) and all read/write
  /// operations stay on the UI isolate; only the one-time initial
  /// load moves off.
  static Future<JsonSettingsStore> create(File file) async {
    final result = await Isolate.run<_LoadResult>(
      () => _readInBackground(file.path),
      debugName: 'JsonSettingsStore.load',
    );
    final store = JsonSettingsStore._(
      file: file,
      initialValues: result.values,
      initialMtime: result.mtime,
      initialSize: result.size,
    );
    if (result.error != null && !store._loadErrorsCtrl.isClosed) {
      final err = result.error!;
      _log.log(Level.SEVERE,
          'Failed to load settings from ${file.path}; falling back to defaults',
          err);
      store._loadErrorsCtrl.add(err);
    }
    return store;
  }

  /// All keys currently defined in this file.
  Iterable<String> get definedKeys => _values.keys;

  bool has(String key) => _values.containsKey(key);

  @override
  T get<T>(Setting<T> key) {
    if (_values.containsKey(key.key)) {
      return key.codec.fromJson(_values[key.key]);
    }
    return key.defaultValue;
  }

  @override
  Future<void> set<T>(Setting<T> key, T value) async {
    _values[key.key] = key.codec.toJson(value);
    // Pass the typed value straight through to the per-key watcher —
    // it avoids both firing unrelated keys' streams AND the
    // get<T>(key) re-read on the changed key.
    await _flushAndEmit(changedKey: key.key, changedValue: value);
  }

  @override
  Future<void> reset<T>(Setting<T> key) async {
    _values.remove(key.key);
    // Null tells the watcher to re-read (it'll fall back to
    // defaultValue because the JSON map no longer has the key).
    await _flushAndEmit(changedKey: key.key);
  }

  @override
  Future<void> resetAll() async {
    _values.clear();
    // Multiple keys changed — fan out to every per-key stream so
    // each watcher re-reads against the now-empty map.
    await _flushAndEmit();
  }

  @override
  bool isExplicitlySet<T>(Setting<T> key) => _values.containsKey(key.key);

  @override
  Stream<T> watch<T>(Setting<T> key) {
    final controller = _controllers.putIfAbsent(
      key.key,
      () => StreamController<dynamic>.broadcast(),
    );
    // Per-key event is either:
    //   * the typed value pushed directly by [set] (skips the
    //     get+re-codec round-trip on self-writes), OR
    //   * `null` from [reset], [resetAll], or the file-watcher's
    //     external-change path — fall back to a fresh [get<T>]
    //     against the in-memory map.
    // `is T` correctly distinguishes the two cases because the typed
    // values pushed by [set] always satisfy `is T` for the
    // corresponding watch call.
    return controller.stream
        .map((v) => v is T ? v : get<T>(key))
        .distinct()
        .asBroadcastStream();
  }

  /// Subscribe to file-level changes (for layered store).
  Stream<void> watchFile() {
    return _controllers.putIfAbsent(
      '__file__',
      () => StreamController<void>.broadcast(),
    ).stream;
  }

  /// Fires whenever a write completes on this file. Emits only
  /// after the atomic-rename succeeds (a failed write does NOT
  /// emit — callers can rely on this for "Saved" indicators).
  @override
  Stream<void> watchWrites() {
    return _controllers.putIfAbsent(
      '__writes__',
      () => StreamController<void>.broadcast(),
    ).stream;
  }

  /// Stream of load failures (corrupt file, unreadable, parse
  /// error, etc.). Each event is the exception that caused the
  /// load to fall back to defaults. Use this to surface a banner
  /// in the Settings UI instead of silently dropping the user's
  /// config.
  @override
  Stream<Object> watchLoadErrors() => _loadErrorsCtrl.stream;

  /// Public path accessor (for the "Reveal in Explorer" UI and
/// the "Open settings file" action).
String get path => _file.path;

  // ── Internals ──────────────────────────────────────────────────

  void _load() {
    // Re-read [_file] on the UI isolate and update [_values] in
    // place. Used by the file watcher when it detects an external
    // edit. Sync I/O is fine here — the watcher runs every 250 ms
    // and the file is small (~1 KB of JSONC in typical configs).
    try {
      final stat = _file.statSync();
      _lastMtime = stat.modified;
      _lastSize = stat.size;
      final raw = _file.readAsStringSync();
      if (raw.trim().isEmpty) {
        _values.clear();
        return;
      }
      final decoded = jsoncDecode(raw);
      if (decoded is Map) {
        _values.clear();
        decoded.forEach((k, v) => _values[k.toString()] = v);
      } else {
        throw const FormatException(
            'Settings file root is not a JSON object');
      }
    } catch (e, st) {
      _log.log(Level.SEVERE,
          'Failed to reload settings from ${_file.path}', e, st);
      _values.clear();
      if (!_loadErrorsCtrl.isClosed) _loadErrorsCtrl.add(e);
    }
  }

  /// Persist the in-memory [_values] to disk and notify watchers.
///
/// Pass [changedKey] (and optionally [changedValue]) for a targeted
/// notification — only that key's stream is fired. Omit both to fan
/// out to every per-key stream (used by [resetAll] and the
/// file-watcher path).
///
/// On write failure we skip the emit entirely so callers don't see
/// a "Saved" / reconfigure event for a value that didn't actually
/// land on disk. The next periodic reload reapplies whatever the
/// file does contain.
Future<void> _flushAndEmit({String? changedKey, Object? changedValue}) async {
  try {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsoncEncode(_values));
    tmp.renameSync(_file.path);
    final stat = _file.statSync();
    _lastMtime = stat.modified;
    _lastSize = stat.size;
    if (changedKey != null) {
      _emitKey(changedKey, changedValue);
    } else {
      _emitAll();
    }
    _emitWrites();
  } catch (e, st) {
    // Don't emit `watchWrites` on failure — the on-disk state
    // doesn't match the in-memory state, so a "Saved" indicator
    // would be lying. The user will see the next periodic reload
    // reapply the previous on-disk version.
    _log.log(Level.SEVERE,
        'Failed to write settings to ${_file.path}', e, st);
  }
}

  void _emitWrites() {
    final c = _controllers['__writes__'];
    if (c != null && !c.isClosed) c.add(null);
  }

  void _startWatcher() {
    _watcher?.cancel();
    _watcher = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_file.existsSync()) {
        if (_values.isNotEmpty) {
          _values.clear();
          _emitAll();
        }
        return;
      }
      try {
        final stat = _file.statSync();
        if (stat.modified != _lastMtime || stat.size != _lastSize) {
          _load();
          _emitAll();
        }
      } catch (e, st) {
        _log.log(Level.SEVERE,
            'Settings watcher tick failed for ${_file.path}', e, st);
      }
    });
  }

  void _emitAll() {
    for (final c in _controllers.values) {
      if (!c.isClosed) c.add(null);
    }
  }

  /// Fire [value] on the per-key controller for [key]. Watchers for
  /// every OTHER key are unaffected — this is the targeted equivalent
  /// of [_emitAll]. Used by [set] / [reset] so a single-key write
  /// only wakes one listener instead of N.
  void _emitKey(String key, Object? value) {
    final c = _controllers[key];
    if (c != null && !c.isClosed) c.add(value);
  }

  /// Pretty-print the file path for status messages.
  String get directory => p.dirname(_file.path);

  void dispose() {
    _watcher?.cancel();
    for (final c in _controllers.values) {
      c.close();
    }
    _controllers.clear();
    _loadErrorsCtrl.close();
  }
}

/// Read + parse the settings file at [path] on a background isolate.
///
/// Returns the decoded map plus the file's mtime/size (so the
/// watcher can start without a false-positive "file changed" tick
/// on its first poll) and any load error encountered.
///
/// Sentinel mtime (epoch 0) and size (0) are returned for the
/// "file does not exist" case so the watcher's first `statSync`
/// will notice if the file appears later.
_LoadResult _readInBackground(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return (
      values: <String, Object?>{},
      mtime: DateTime.fromMillisecondsSinceEpoch(0),
      size: 0,
      error: null,
    );
  }
  try {
    final stat = file.statSync();
    final raw = file.readAsStringSync();
    if (raw.trim().isEmpty) {
      return (
        values: <String, Object?>{},
        mtime: stat.modified,
        size: stat.size,
        error: null,
      );
    }
    final decoded = jsoncDecode(raw);
    if (decoded is Map) {
      return (
        values: decoded.map((k, v) => MapEntry(k.toString(), v)),
        mtime: stat.modified,
        size: stat.size,
        error: null,
      );
    }
    // Root is not an object — treat as corrupt.
    throw const FormatException(
        'Settings file root is not a JSON object');
  } catch (e) {
    // Corrupt or unreadable: fall back to defaults. The error is
    // surfaced on the UI isolate by [create] so the banner /
    // watchLoadErrors stream see it exactly once.
    return (
      values: <String, Object?>{},
      mtime: DateTime.fromMillisecondsSinceEpoch(0),
      size: 0,
      error: e,
    );
  }
}
