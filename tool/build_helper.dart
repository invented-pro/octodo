// Builds octodo_helper.exe and places it next to octodo.exe in the
// Windows Release output dir, so the in-app updater can spawn it on
// apply.
//
// Run AFTER `flutter build windows --release` (the Release dir must
// already exist). For `flutter run -d windows` dev sessions, invoke
// once before triggering the in-app upgrade flow.
//
// Usage:
//   dart run tool/build_helper.dart
//
// CI invokes this same command in .github/workflows/release.yml —
// keeping a single source of truth for output path + post-build
// existence check so the dev and release paths can't drift.
//
// Implemented in Dart (not PowerShell) so it runs regardless of the
// system's ExecutionPolicy, which on Windows client SKUs defaults to
// `Restricted` and blocks bare `.\tool\build_helper.ps1` invocation.

import 'dart:io';

Future<void> main(List<String> args) async {
  // Platform.script.path is the path of this file. Resolving its
  // parent gives the project root regardless of the current working
  // directory at invocation.
  final scriptPath = Platform.script.toFilePath();
  final projectRoot = File(scriptPath).parent.parent.path;
  final src = '$projectRoot/tool/update_helper.dart';
  final dstDir = '$projectRoot/build/windows/x64/runner/Release';
  final dst = '$dstDir/octodo_helper.exe';

  final dstDirExists = await Directory(dstDir).exists();
  if (!dstDirExists) {
    stderr.writeln(
      'Release dir does not exist yet: $dstDir\n'
      "Run 'flutter build windows --release' first.",
    );
    exit(1);
  }

  stdout.writeln('Compiling $src -> $dst');
  // Platform.resolvedExecutable is the dart binary currently running
  // this script, so `dart run tool/build_helper.dart` uses the same
  // SDK that owns the surrounding pubspec — no PATH lookups.
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['compile', 'exe', src, '-o', dst],
    runInShell: true,
  );
  stdout.write(result.stdout);
  if (result.stderr.isNotEmpty) stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('dart compile exe failed (exit=${result.exitCode})');
    exit(result.exitCode);
  }

  final size = await File(dst).length();
  stdout.writeln('Built $dst ($size bytes)');
}
