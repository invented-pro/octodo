// Dart side of the `octodo/environment` platform channel (Windows).
//
// Method surface (Dart → native):
//   * get — returns the CURRENT system + user environment as a map,
//     rebuilt from the registry at call time via
//     CreateEnvironmentBlock (see windows/runner/environment.cpp).
//     Unlike `Platform.environment` — a frozen snapshot of whatever
//     the app process inherited at launch — successive calls observe
//     environment edits made after octodo started (installer PATH
//     appends, `setx`, System Properties, …).
//
// Consumers gate on `Platform.isWindows` themselves, so this class
// carries no platform check: the channel is mockable in tests on
// every host. Every failure mode (missing plugin on non-Windows
// runners / flutter test, a PlatformException from a registry hiccup,
// a null reply) resolves to `null`, which callers translate to "keep
// using Platform.environment" — the historical behavior. A fresh-env
// read can never block tab creation.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../log.dart';

class FreshEnvironment {
  static const MethodChannel _channel = MethodChannel('octodo/environment');

  static final Logger _log = moduleLogger('terminal.fresh_environment');

  FreshEnvironment._();

  /// Reads the latest system + user environment from the Windows
  /// registry, or `null` when the channel is unavailable or failed
  /// (non-Windows hosts, tests, registry errors).
  ///
  /// The result is aligned against the launch environment via
  /// [canonicalize] (name casing) and [mergePath] (session-only PATH
  /// entries) before being returned — see those docstrings for why.
  ///
  /// Cheap enough to call per spawn (one registry read behind the
  /// platform channel, single-digit milliseconds); do NOT cache, or
  /// the "latest" guarantee is lost.
  static Future<Map<String, String>?> read() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('get');
      if (raw == null) {
        _log.fine('native returned null — falling back to launch env');
        return null;
      }
      final parsed = {
        for (final entry in raw.entries)
          entry.key.toString(): entry.value.toString(),
      };
      return canonicalize(parsed, Platform.environment);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      _log.warning('fresh env read failed (${e.code}) — '
          'falling back to launch env');
      return null;
    }
  }

  /// Aligns a fresh registry snapshot with the launch environment so
  /// the consumer's plain map spread (`{...Platform.environment,
  /// ...fresh}`) replaces vars in place instead of duplicating them.
  ///
  /// Windows environment names are case-insensitive; Dart maps are
  /// not. `CreateEnvironmentBlock` emits canonical registry casing
  /// (`Path`), but the launch env may spell the same var differently
  /// (`PATH` — MSYS2/Cygwin/WSL-interop launchers do). Without this
  /// alignment the spread would produce BOTH keys, and the flattened
  /// env block's first occurrence (the stale launch value) would win
  /// — silently no-op'ing the refresh for exactly the vars it
  /// targets. Each fresh key that case-insensitively matches a launch
  /// key is re-keyed to the launch spelling.
  ///
  /// Also merges PATH via [mergePath].
  @visibleForTesting
  static Map<String, String> canonicalize(
    Map<String, String> fresh,
    Map<String, String> launchEnv,
  ) {
    final launchByLower = {
      for (final key in launchEnv.keys) key.toLowerCase(): key,
    };
    final result = <String, String>{};
    for (final entry in fresh.entries) {
      final launchSpelling = launchByLower[entry.key.toLowerCase()];
      result[launchSpelling ?? entry.key] = entry.value;
    }
    final launchPathKey = launchByLower['path'];
    if (launchPathKey != null && result.containsKey(launchPathKey)) {
      result[launchPathKey] = mergePath(
        freshPath: result[launchPathKey]!,
        launchPath: launchEnv[launchPathKey] ?? '',
      );
    }
    return result;
  }

  /// Merges the launch-time PATH into the fresh registry PATH:
  /// entries present in the launch PATH but NOT in the registry PATH
  /// are prepended, in launch order; registry entries are kept intact
  /// in registry order; entries in both appear once (registry copy).
  ///
  /// Without this, launching octodo from a shell with session-scoped
  /// PATH additions — an activated venv/conda, an nvm shim dir, VS
  /// Code task env injection, a plain `$env:PATH += …` — would
  /// silently drop them from every new tab, because the registry
  /// value wins for registry-defined names. Prepending (not
  /// appending) the session extras also preserves the session's
  /// precedence for tools that shadow registry ones (the venv
  /// `python` case), matching the previous launch-inherit behavior.
  ///
  /// Comparison is case-insensitive and ignores trailing separators,
  /// so `C:\foo\` and `c:\FOO` dedupe as the same directory.
  @visibleForTesting
  static String mergePath({
    required String freshPath,
    required String launchPath,
  }) {
    final freshEntries = freshPath
        .split(';')
        .map(_normalizePathEntry)
        .where((entry) => entry.isNotEmpty)
        .toSet();
    final extras = launchPath
        .split(';')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .where((entry) => !freshEntries.contains(_normalizePathEntry(entry)))
        .toList();
    if (extras.isEmpty) return freshPath;
    return '${extras.join(';')};$freshPath';
  }

  static String _normalizePathEntry(String entry) {
    var normalized = entry.trim();
    while (normalized.endsWith('\\') || normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.toLowerCase();
  }
}
