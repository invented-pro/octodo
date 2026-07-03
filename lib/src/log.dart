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
/// By default the root level is [Level.FINE] in debug builds and
/// [Level.OFF] in release/profile builds, so the app is silent in
/// shipped builds without any caller-side gating. Pass [rootLevel]
/// explicitly to override — useful for tests that want log output
/// regardless of build mode.
void configureLogging({Level? rootLevel}) {
  Logger.root.level = rootLevel ?? (kDebugMode ? Level.FINE : Level.OFF);
  // Detach any previously installed handler so calling this twice
  // (e.g. from a hot-restart) doesn't double-print.
  Logger.root.clearListeners();
  Logger.root.onRecord.listen(_emit);
}

void _emit(LogRecord r) {
  // Defensive double-gate. `package:logging` already filters records
  // against `Logger.level` at the call site (so when root level is
  // OFF, no record is ever created), but explicit gating here makes
  // the intent obvious and is the branch the CPU is going to predict
  // correctly every time. Cost in the gated-off path: one integer
  // compare. Cost in the active path: zero (the framework's check
  // already passed).
  if (r.level < Logger.root.level) return;
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
  debugPrint(buf.toString());
  if (r.stackTrace != null) {
    debugPrint(r.stackTrace.toString());
  }
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