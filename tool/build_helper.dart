// Builds the octodo_helper binary and places it next to the app
// executable in the release output dir, so the in-app updater can
// spawn it on apply.
//
// Windows: the production apply path (per-file copy over the
// install dir).
//
// macOS: the CURRENT app code applies updates via /bin/sh instead
// (see lib/src/update/installer/posix_apply_script.dart) because a
// Dart AOT binary is killed by Hardened Runtime's W^X enforcement.
// We still ship octodo_helper inside Contents/MacOS/ as belt-and-
// braces (a fallback if the sh path is ever unavailable), and CI
// signs it WITHOUT Hardened Runtime so the shipped binary is at
// least runnable rather than a guaranteed kernel kill. NOTE: this
// does NOT rescue 2.0.x/2.1.x installs — those exec their OWN
// HR-signed helper and need one manual update to reach the sh-based
// updater.
//
// Run AFTER `flutter build windows --release` /
// `flutter build macos --release` (the output dir must already
// exist). For `flutter run` dev sessions, invoke once before
// triggering the in-app upgrade flow.
//
// Usage:
//   dart run tool/build_helper.dart
//
// CI invokes this same command in .github/workflows/release.yml —
// keeping a single source of truth for output path + post-build
// existence check so the dev and release paths can't drift.
//
// Implemented in Dart (not shell) so it runs regardless of the
// system's ExecutionPolicy / shell defaults.

import 'dart:io';

Future<void> main(List<String> args) async {
  // Platform.script.path is the path of this file. Resolving its
  // parent gives the project root regardless of the current working
  // directory at invocation.
  final scriptPath = Platform.script.toFilePath();
  final projectRoot = File(scriptPath).parent.parent.path;
  final src = '$projectRoot/tool/update_helper.dart';

  // Windows: the portable-zip layout — everything sits next to
  // octodo.exe. macOS: the .app bundle layout — the helper ships
  // inside Contents/MacOS/ so it travels with the bundle through
  // the zip → download → bundle-swap pipeline (and gets covered by
  // the bundle's code signature).
  final String dstDir;
  final String dst;
  if (Platform.isMacOS) {
    dstDir = '$projectRoot/build/macos/Build/Products/Release/Octodo.app'
        '/Contents/MacOS';
    dst = '$dstDir/octodo_helper';
  } else {
    dstDir = '$projectRoot/build/windows/x64/runner/Release';
    dst = '$dstDir/octodo_helper.exe';
  }

  final dstDirExists = await Directory(dstDir).exists();
  if (!dstDirExists) {
    stderr.writeln(
      'Release dir does not exist yet: $dstDir\n'
      "Run 'flutter build ${Platform.isMacOS ? 'macos' : 'windows'} "
      "--release' first.",
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
