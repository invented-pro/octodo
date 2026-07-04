// Helper-mode entry point.
//
// When the running app wants to apply a downloaded update, it
// spawns itself with `OCTODO_UPDATE_HELPER=1` set in the
// environment, plus `OCTODO_UPDATE_PAYLOAD=<version>` and
// `OCTODO_UPDATE_PID=<pid-of-original-app>`. The new process
// boots, sees the env var at the top of `main()`, and routes here
// — bypassing any Flutter / window initialization.
//
// The helper:
//   1. waits for the original process to exit (bounded),
//   2. extracts the staged zip into a temp dir,
//   3. copies the contents over the install dir,
//   4. relaunches the freshly-replaced executable.
//
// Logs are silenced by the same `configureLogging()` gating as
// the rest of the app (debug-only FINE / release-OFF), so a real
// helper run produces no terminal output. A crash sentinel at
// `%TEMP%\octodo_apply_crash.log` is the only forensic record.

import 'dart:io';

import 'crash_sentinel.dart';
import 'install_paths.dart';
import 'staged_apply.dart';

const String kHelperFlagEnv = 'OCTODO_UPDATE_HELPER';
const String kHelperPayloadEnv = 'OCTODO_UPDATE_PAYLOAD';
const String kHelperPidEnv = 'OCTODO_UPDATE_PID';

/// True when the current process was started in helper mode. The
/// `main()` entry checks this BEFORE doing any Flutter init.
bool get isHelperMode =>
    Platform.environment[kHelperFlagEnv] == '1';

/// Entry for helper-mode invocations. Reads env vars, runs the
/// installer, and returns a process exit code. The caller (in
/// `main.dart`) is expected to follow this with `exit(code)`.
Future<int> runUpdateHelper() async {
  final env = Platform.environment;
  final payloadVersion = env[kHelperPayloadEnv];
  if (payloadVersion == null || payloadVersion.isEmpty) {
    await writeHelperCrashSentinel(
      'helper invoked without $kHelperPayloadEnv',
    );
    return 1;
  }
  final pidStr = env[kHelperPidEnv];
  final pidToIgnore = int.tryParse(pidStr ?? '') ?? 0;

  try {
    final paths = InstallerPaths.fromVersion(version: payloadVersion);
    await StagedApply.run(paths: paths, pidToIgnore: pidToIgnore);
    return 0;
  } catch (e) {
    await writeHelperCrashSentinel(
      'helper run failed: ${e.runtimeType}: $e',
    );
    return 2;
  }
}
