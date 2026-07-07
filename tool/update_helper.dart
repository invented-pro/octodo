// Standalone helper executable for the in-app updater.
//
// This is compiled with `dart compile exe` to `octodo_helper.exe` and
// placed next to `octodo.exe` in the install dir. When the running app
// wants to apply a staged update, it spawns THIS executable (not
// `octodo.exe`) with the env vars `OCTODO_UPDATE_PAYLOAD=<version>`
// and `OCTODO_UPDATE_PID=<pid-of-original-app>`.
//
// Why a separate executable: `octodo.exe` statically imports several
// plugin DLLs (`desktop_drop_plugin.dll`, `flutter_windows.dll`,
// `screen_retriever_windows_plugin.dll`, `url_launcher_windows_plugin.dll`,
// `window_manager_plugin.dll`). The Windows loader maps them into the
// process address space *before* `main()` runs, so a helper-mode spawn
// of `octodo.exe` itself cannot overwrite them — Windows returns
// `ERROR_ALREADY_EXISTS` (errno 183) on every retry. A standalone
// Dart executable doesn't link against those DLLs, so it can freely
// overwrite every file in the install dir.
//
// Build (local dev):
//   dart run tool/build_helper.dart
// or:
//   dart compile exe tool/update_helper.dart \
//     -o build/windows/x64/runner/Release/octodo_helper.exe
//
// Build (CI): see `.github/workflows/release.yml` — runs the same
// `dart run tool/build_helper.dart` after `flutter build windows`
// so the Release dir already exists.

import 'dart:io';

import 'package:octodo/src/update/installer/apply_main.dart';

Future<void> main(List<String> args) async {
  // Same env-var protocol as the legacy in-process helper path.
  // apply_main.runUpdateHelper reads OCTODO_UPDATE_PAYLOAD /
  // OCTODO_UPDATE_PID, resolves the staged zip, runs StagedApply.run,
  // and returns a process exit code (0 = success, 1 = bad env,
  // 2 = staged-apply failure). We exit with the same code so the
  // spawning parent (already gone) and the relaunched child pick up
  // a consistent signal.
  final code = await runUpdateHelper();
  // dart:io exit; this is a standalone exe with no Flutter binding.
  exit(code);
}
