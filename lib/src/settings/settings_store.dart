// Abstract settings store. The single implementation is
// [JsonSettingsStore] — a JSONC file at a fixed on-disk path.
//
// Reads are synchronous (cached). Writes are async (file I/O).
// `watch` returns a broadcast stream that re-emits when the value
// changes for any reason (file edit, in-app edit, other instance).

import 'dart:async';
import 'setting.dart';

abstract class SettingsStore {
  /// Synchronous read. Returns the value stored on disk, or the
  /// default if the file doesn't define [key].
  T get<T>(Setting<T> key);

  /// Async write. Persists to disk.
  Future<void> set<T>(Setting<T> key, T value);

  /// Reset this key to the default (removes it from disk).
  Future<void> reset<T>(Setting<T> key);

  /// Reset everything to defaults (clears the file).
  Future<void> resetAll();

  /// Returns true if the file has an explicit value for [key].
  bool isExplicitlySet<T>(Setting<T> key);

  /// Hot-reload stream. Emits the *resolved* value whenever the
  /// file changes (external edit, in-app edit, or another
  /// Octodo instance).
  Stream<T> watch<T>(Setting<T> key);

  /// Fires whenever a write completes. Use this for "Saved"
  /// status indicators in the UI.
  Stream<void> watchWrites();

  /// Stream of load failures (corrupt file, parse error, etc.).
  /// Each event is the exception that caused the load to fall
  /// back to defaults. Use this to surface a banner in the
  /// Settings UI instead of silently dropping the user's config.
  Stream<Object> watchLoadErrors();
}