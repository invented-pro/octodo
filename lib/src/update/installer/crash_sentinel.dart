// Helper-process crash sentinel.
//
// The auto-update helper runs in release/profile builds with all
// logging silenced, so a failed `Process.start`, a thrown
// `StagedApplyException`, or a relaunched child that dies
// immediately leaves *no* observable trace. This helper writes a
// short append to `%TEMP%\octodo_apply_crash.log` (best effort)
// so a forensic signal exists on disk.
//
// Callers:
//   * `apply_main.dart` — helper entry; writes on top-level
//     failure or invalid env.
//   * `staged_apply.dart` — partial-copy failure (install dir is
//     in an inconsistent state) and a relaunched child that
//     exits non-zero shortly after spawn.
//   * the POSIX apply script (`posix_apply_script.dart`) appends
//     to the same file from /bin/sh on macOS.
import 'dart:io';

import 'package:path/path.dart' as p;

const String kHelperCrashFileName = 'octodo_apply_crash.log';

/// Resolve the crash-sentinel file location. Windows sets `TEMP`
/// for every process; macOS GUI apps do NOT — they set `TMPDIR`
/// (`/var/folders/…/T/`). The old `TEMP`-only resolution sent the
/// macOS sentinel to `Directory.systemTemp` (which may or may not
/// equal `$TMPDIR`), leaving applies undiagnosable. Order: TEMP →
/// TMPDIR → systemTemp — identical behavior on Windows, correct
/// per-user temp on macOS.
File resolveHelperCrashSentinelFile() {
  final temp = Platform.environment['TEMP'] ??
      Platform.environment['TMPDIR'] ??
      Directory.systemTemp.path;
  return File(p.join(temp, kHelperCrashFileName));
}

/// Best-effort write of [message] to the helper crash sentinel.
Future<void> writeHelperCrashSentinel(String message) async {
  try {
    final contents = '${DateTime.now().toIso8601String()}\n$message\n';
    await resolveHelperCrashSentinelFile().writeAsString(contents, flush: true);
  } catch (_) {
    // Best effort; nothing more we can do from here.
  }
}