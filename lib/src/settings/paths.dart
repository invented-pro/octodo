// Settings file path resolution. Octodo persists user settings to a
// single file living under the current user's home directory:
//
//   <userHome>/.config/Octodo/settings.json
//
// Where [userHome] is resolved in this order (first non-empty wins):
//   1. Injected argument (test seam).
//   2. %USERPROFILE% (Windows).
//   3. $HOME (POSIX).
//
// On non-Windows hosts, %USERPROFILE% is unavailable so $HOME is used.
// There is no APPDATA / XDG_CONFIG_HOME override — the file lives at
// the same location on every host so users can sync it via a dotfiles
// repo, rsync, or symlink without worrying about per-OS branching.

import 'dart:io';
import 'package:path/path.dart' as p;

class SettingsPaths {
  /// Absolute path of the single settings file
  /// (`<userHome>/.config/Octodo/settings.json`).
  final File file;

  /// Absolute path of the rotating WARNING+ diagnostics log
  /// (`<userHome>/.config/Octodo/logs/octodo.log`), or `null` when no
  /// user home could be resolved. Kept in a `logs/` subdirectory so a
  /// dotfiles-synced config dir isn't churned by log writes; the file
  /// itself is only created on the first WARNING+ record (see
  /// [attachLogFileSink] in `lib/src/log.dart`).
  final File? logFile;

  const SettingsPaths({required this.file, this.logFile});

  /// Resolve the settings file location for the current host.
  ///
  /// [userHome] can be injected for tests. When not supplied, the
  /// resolver walks `Platform.environment['USERPROFILE']` (Windows)
  /// then `Platform.environment['HOME']` (POSIX).
  factory SettingsPaths.resolve({String? userHome}) {
    final home = userHome ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    final dir = Directory(p.join(home, '.config', 'Octodo'));
    return SettingsPaths(
      file: File(p.join(dir.path, 'settings.json')),
      logFile: home.isEmpty
          ? null
          : File(p.join(dir.path, 'logs', 'octodo.log')),
    );
  }
}