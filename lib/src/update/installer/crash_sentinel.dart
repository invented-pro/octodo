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
import 'dart:io';

import 'package:path/path.dart' as p;

const String kHelperCrashFileName = 'octodo_apply_crash.log';

/// Best-effort write of [message] to the helper crash sentinel.
/// Uses `p.join` so the path is portable even though the auto-
/// update flow itself is Windows-only for v1.
Future<void> writeHelperCrashSentinel(String message) async {
  try {
    final temp = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    final f = File(p.join(temp, kHelperCrashFileName));
    final contents = '${DateTime.now().toIso8601String()}\n$message\n';
    await f.writeAsString(contents, flush: true);
  } catch (_) {
    // Best effort; nothing more we can do from here.
  }
}