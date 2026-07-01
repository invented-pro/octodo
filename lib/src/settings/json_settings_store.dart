// Single-file JSONC settings store. Watches the file for external
// edits via a poll loop (dart:io doesn't have a reliable file
// watcher on Windows; the polling interval is 250ms which is
// imperceptible for human edits and cheap for an idle app).

import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../log.dart';
import 'jsonc.dart';
import 'setting.dart';
import 'settings_store.dart';

final Logger _log = moduleLogger('settings.json_store');

class JsonSettingsStore implements SettingsStore {
  final File _file;
  final _values = <String, Object?>{};
  final _controllers = <String, StreamController<dynamic>>{};
  final StreamController<Object> _loadErrorsCtrl =
      StreamController<Object>.broadcast();
  Timer? _watcher;
  DateTime _lastMtime = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSize = -1;

  JsonSettingsStore(this._file) {
    _load();
    _startWatcher();
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
    await _flush();
  }

  @override
  Future<void> reset<T>(Setting<T> key) async {
    _values.remove(key.key);
    await _flush();
  }

  @override
  Future<void> resetAll() async {
    _values.clear();
    await _flush();
  }

  @override
  bool isExplicitlySet<T>(Setting<T> key) => _values.containsKey(key.key);

  @override
  Stream<T> watch<T>(Setting<T> key) {
    final controller = _controllers.putIfAbsent(
      key.key,
      () => StreamController<dynamic>.broadcast(),
    );
    return controller.stream.cast<dynamic>().map((_) => get<T>(key)).distinct().asBroadcastStream();
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
    if (!_file.existsSync()) {
      _values.clear();
      _lastMtime = DateTime.fromMillisecondsSinceEpoch(0);
      _lastSize = 0;
      return;
    }
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
        // Root is not an object — treat as corrupt.
        throw const FormatException(
            'Settings file root is not a JSON object');
      }
    } catch (e, st) {
      // Corrupt or unreadable: fall back to defaults AND surface
      // the error. Without the surface the user has no way to
      // know their settings were dropped.
      _log.log(Level.SEVERE,
          'Failed to load settings from ${_file.path}; falling back to defaults',
          e, st);
      _values.clear();
      if (!_loadErrorsCtrl.isClosed) _loadErrorsCtrl.add(e);
    }
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(jsoncEncode(_values));
      tmp.renameSync(_file.path);
      final stat = _file.statSync();
      _lastMtime = stat.modified;
      _lastSize = stat.size;
      _emitAll();
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
