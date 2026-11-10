import 'dart:async' show StreamSubscription;
import 'dart:convert' show utf8;
import 'dart:io' show File, FileMode, FileSystemException, RandomAccessFile;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

export 'package:logging/logging.dart' show Level, LogRecord, Logger;

/// The root logger name used by every module in this app. Module loggers
/// are created as `Logger('octodo.<dotted.module.path>')` so that the
/// hierarchical logger tree is namespaced under a single root.
const String kLoggerRoot = 'octodo';

/// Installs the root-logger handler. Call once, early in `main()` —
/// before any other logger is used — so that records produced during
/// startup are captured.
///
/// Two independent gates:
///
/// * [rootLevel] caps which records *exist at all* (package:logging
///   filters at the call site). Defaults to [Level.FINE] in debug
///   builds and **[Level.WARNING]** in release/profile builds — not
///   OFF, because the rotating file sink ([attachLogFileSink]) needs
///   WARNING+ records to survive in shipped builds for user-reportable
///   diagnostics (e.g. the `terminal.defaultShell` fallback). Records
///   below WARNING cost nothing in release: they are filtered before
///   a [LogRecord] is allocated.
/// * [consoleLevel] gates the `debugPrint` handler inside this file.
///   Defaults to [Level.FINE] in debug and [Level.OFF] in release, so
///   shipped builds stay silent on the console even though WARNING+
///   records exist for the file sink.
///
/// Pass either explicitly to override — useful for tests that want
/// log output regardless of build mode.
void configureLogging({Level? rootLevel, Level? consoleLevel}) {
  Logger.root.level = rootLevel ?? (kDebugMode ? Level.FINE : Level.WARNING);
  // Detach any previously installed handler so calling this twice
  // (e.g. from a hot-restart) doesn't double-print. Note this also
  // detaches a file sink installed by [attachLogFileSink]; re-attach
  // it afterwards if you reconfigure mid-run.
  Logger.root.clearListeners();
  final console = consoleLevel ?? (kDebugMode ? Level.FINE : Level.OFF);
  Logger.root.onRecord.listen((r) => _emit(r, console));
}

void _emit(LogRecord r, Level consoleLevel) {
  // Defensive double-gate. `package:logging` already filters records
  // against `Logger.level` at the call site (so when the root level is
  // below the record, no record is ever created), but explicit gating
  // here makes the intent obvious and is the branch the CPU is going
  // to predict correctly every time. Cost in the gated-off path: one
  // integer compare. Cost in the active path: zero (the framework's
  // check already passed).
  if (r.level < consoleLevel) return;
  debugPrint(_formatRecord(r));
  if (r.stackTrace != null) {
    debugPrint(r.stackTrace.toString());
  }
}

/// One line per record, shared by the console handler and the file
/// sink so the two outputs stay byte-identical (a user-reported log
/// file then reads exactly like a debug console session).
String _formatRecord(LogRecord r) {
  final buf = StringBuffer()
    ..write(r.time.toIso8601String())
    ..write(' ')
    ..write(r.level.name.padRight(7))
    ..write(' ')
    ..write(r.loggerName)
    ..write(': ')
    ..write(r.message);
  if (r.error != null) {
    buf
      ..write(' error=')
      ..write(r.error);
  }
  return buf.toString();
}

/// Teardown handle returned by [attachLogFileSink]. Flushes state,
/// closes the file, and stops the sink from observing further records.
typedef LogSinkDetach = void Function();

/// Append records at [level] or above to [file], rotating it once it
/// grows past [maxBytes].
///
/// This is the shipped-build diagnostics path: the console handler is
/// compiled to silence in release (see [configureLogging]), so without
/// a file there is nothing to look at when a user reports e.g.
/// "my default shell didn't stick" — which resolves to the WARNING
/// the `terminal.defaultShell` fallback leaves behind. Rotation keeps
/// a bounded history: when [file] is already at [maxBytes] and the
/// next record arrives, the file is renamed to `<file>.1` (replacing
/// any previous `.1`) and the record starts a fresh [file]. The live
/// file therefore always holds the newest records and disk usage is
/// capped at roughly 2×[maxBytes] (cap + one record of overshoot
/// while a large record with a stack trace is being written).
///
/// * Sync `dart:io` writes, opened lazily on the first matching
///   record: an app that never logs WARNING+ never creates the file
///   (and never clutters a dotfiles-synced config dir).
/// * Never throws into the logging stream: the first I/O failure
///   (read-only home, full disk, permission denied) detaches the sink
///   and the app keeps running console-only. Failure is reported once
///   via `debugPrint` — invisible in release by design; the sink must
///   not be able to take the app down with it.
/// * Attach **after** [configureLogging]: `configureLogging` clears
///   root listeners, so a re-configure drops a previously attached
///   sink.
///
/// Returns a [LogSinkDetach]; call it in tests (or to stop the sink
/// mid-run) to release the file handle.
LogSinkDetach attachLogFileSink(
  File file, {
  Level level = Level.WARNING,
  int maxBytes = 1 << 20,
}) {
  var detached = false;
  StreamSubscription<LogRecord>? sub;
  RandomAccessFile? raf;
  var written = 0;

  void fail(Object error) {
    if (detached) return;
    detached = true;
    sub?.cancel();
    try {
      raf?.closeSync();
    } catch (_) {
      // Already closing/closed — nothing else to do.
    }
    debugPrint('octodo log file sink disabled: $error');
  }

  // Rename the live file to `<file>.1` (replacing any previous `.1`)
  // and reset the byte counter; the caller reopens lazily on the next
  // write. Only ever called once the file has content.
  void rotate() {
    try {
      raf?.closeSync();
    } catch (_) {
      // Fall through: the rename below is the part that matters.
    }
    raf = null;
    written = 0;
    final previous = File('${file.path}.1');
    if (previous.existsSync()) previous.deleteSync();
    if (file.existsSync()) file.renameSync(previous.path);
  }

  sub = Logger.root.onRecord.listen((r) {
    if (detached || r.level < level) return;
    try {
      var line = _formatRecord(r);
      if (r.stackTrace != null) line = '$line\n${r.stackTrace}';
      final data = utf8.encode('$line\n');
      if (raf == null) {
        file.parent.createSync(recursive: true);
        raf = file.openSync(mode: FileMode.append);
        // Seed from any leftover log of a previous run so a stale
        // multi-MB file still rotates instead of growing forever.
        written = file.lengthSync();
      }
      if (written >= maxBytes) rotate();
      // rotate() above closed the handle (and renamed the file away);
      // reopen lazily — this is also the fresh-file path after a
      // rotation.
      raf ??= file.openSync(mode: FileMode.append);
      raf!.writeFromSync(data);
      written += data.length;
    } on FileSystemException catch (e) {
      fail(e);
    } catch (e) {
      fail(e);
    }
  });

  return () {
    if (detached) return;
    detached = true;
    sub?.cancel();
    try {
      raf?.closeSync();
    } catch (_) {
      // Already closing/closed — nothing else to do.
    }
    raf = null;
  };
}

/// Convenience: build a child logger under [kLoggerRoot] from a dotted
/// module path. Equivalent to `Logger('octodo.<path>')`.
///
/// Example: `moduleLogger('terminal.shell_profiles')` → 'octodo.terminal.shell_profiles'.
Logger moduleLogger(String modulePath) {
  final name =
      modulePath.isEmpty ? kLoggerRoot : '$kLoggerRoot.$modulePath';
  return Logger(name);
}
