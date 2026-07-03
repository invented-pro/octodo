import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// A selectable shell profile.
///
/// Each profile describes a shell executable that can be spawned in a new
/// terminal tab. The [icon] and [color] are used in the tab bar and the
/// shell-selector dropdown.
class ShellProfile {
  /// Human-readable name shown in the dropdown (e.g. "PowerShell 7", or a
  /// WSL distro name like "Ubuntu").
  final String label;

  /// Absolute path to the shell executable, e.g.
  /// `C:\Program Files\PowerShell\7\pwsh.exe` or
  /// `C:\Windows\System32\wsl.exe`. Stored separately from [args] so the
  /// spawn layer never has to re-tokenize a serialized command line — the
  /// old `command` string field used to round-trip through a hand-rolled
  /// tokenizer plus a re-quoting pass; the program and its arguments now
  /// arrive pre-split.
  final String program;

  /// Arguments handed to [program] at spawn, e.g. `['-NoLogo']` for pwsh,
  /// `['--login', '-i']` for Git Bash, or `['-d', 'Ubuntu']` for a WSL
  /// distro. Excludes `-NoProfile`, which the spawn layer appends itself
  /// for the PowerShell families.
  final List<String> args;

  /// Material icon representing this shell type. Used as the fallback
  /// when [iconAsset] is null (currently just CMD, which has no official
  /// logo). For everything else the SVG in [iconAsset] is preferred
  /// because distro and project branding is more recognisable than any
  /// of the available Material glyphs.
  final IconData icon;

  /// Path to an SVG asset under `assets/icons/` that visually represents
  /// this shell (e.g. `assets/icons/powershell.svg`,
  /// `assets/icons/ubuntu.svg`). `null` means no asset is shipped —
  /// renderers fall back to [icon].
  final String? iconAsset;

  /// Tint colour for the icon in the tab bar.
  final Color color;

  /// Short tag used as the initial tab title before the shell sets its
  /// own OSC title (e.g. "pwsh", "cmd", or a lowercased distro name).
  final String shortName;

  /// Whether this shell's tab title should include the cwd (updated via
  /// OSC 7 from the shell). Defaults to `false` because the native
  /// Windows shells (PowerShell 7, Windows PowerShell, CMD) emit an
  /// OSC 7 path that mixes a drive letter with a forward-slash URI,
  /// plus ConPTY occasionally drops or duplicates the OSC 7 sequence on
  /// prompt redraw — both leave the chip showing garbled paths like
  /// `pwsh C:/Users/<user>/projects` that don't match what the user typed
  /// `cd` to. Set to `true` for shells that emit a stable, reliable
  /// OSC 7 by default (modern WSL distros, git-bash with a configured
  /// `PROMPT_COMMAND`).
  final bool showCwdInTitle;

  /// WSL only: the distro name passed to `wsl.exe -d <distro>`. null for
  /// every other shell. Lets the workspace query each distro's own `$HOME`
  /// (via `wsl -d <distro> wslpath -w ~`) instead of always resolving the
  /// default distro's home — which previously drifted when a tab launched a
  /// non-default distro.
  final String? wslDistro;

  /// `true` for `wsl.exe`-backed profiles. The workspace uses this to decide
  /// whether to translate the initial cwd to the `/mnt/<drive>/…` layout and
  /// whether to query the distro `$HOME`.
  bool get isWsl => p.basename(program).toLowerCase() == 'wsl.exe';

  const ShellProfile({
    required this.label,
    required this.program,
    required this.args,
    required this.icon,
    required this.color,
    required this.shortName,
    this.showCwdInTitle = false,
    this.wslDistro,
    this.iconAsset,
  });

  @override
  String toString() => 'ShellProfile($label)';
}

// ── Predefined icon colours ──────────────────────────────────────────

const _pwshBlue = Color(0xFF0078D4); // Microsoft blue
const _cmdAmber = Color(0xFFE8A838); // CMD amber
const _wslGreen = Color(0xFF22C55E); // Linux green (Tux)
const _bashOrange = Color(0xFFF05033); // Git orange-red

// ── WSL distro icon resolution ───────────────────────────────────────

/// Asset path for the per-distro SVG icon used in the tab bar and
/// shell dropdown, or `null` when no specific icon ships — the renderer
/// then falls back to the Material glyph on [ShellProfile.icon].
///
/// Matching is prefix-based on the distro name returned by
/// `wsl.exe --list` (e.g. `Ubuntu`, `Ubuntu-22.04`, `kali-linux` all
/// resolve to the same icon). The first match wins; entries are
/// checked in the order they appear below. A trailing entry for
/// [wslFallbackAsset] is consulted last so unknown distros still get
/// a "Linux" placeholder instead of the Material fallback.
const String kWslFallbackAsset = 'assets/icons/wsl-fallback.svg';

const List<({String prefix, String asset})> _wslIconTable = [
  (prefix: 'ubuntu', asset: 'assets/icons/ubuntu.svg'),
  (prefix: 'debian', asset: 'assets/icons/debian.svg'),
  (prefix: 'fedora', asset: 'assets/icons/fedora.svg'),
  (prefix: 'arch', asset: 'assets/icons/arch.svg'),
  (prefix: 'manjaro', asset: 'assets/icons/arch.svg'),
  // openSUSE ships both Leap and Tumbleweed; the prefix also catches
  // SUSE Linux Enterprise (SLES), which uses the same chameleon.
  (prefix: 'opensuse', asset: 'assets/icons/opensuse.svg'),
  (prefix: 'suse', asset: 'assets/icons/opensuse.svg'),
  (prefix: 'sles', asset: 'assets/icons/opensuse.svg'),
  (prefix: 'kali', asset: 'assets/icons/kali.svg'),
  (prefix: 'alpine', asset: 'assets/icons/alpine.svg'),
  (prefix: 'centos', asset: 'assets/icons/centos.svg'),
  // RHEL/CentOS Stream/Rocky/Alma share a family look — the CentOS
  // icon is the closest visual match we ship.
  (prefix: 'rhel', asset: 'assets/icons/centos.svg'),
  (prefix: 'rocky', asset: 'assets/icons/centos.svg'),
  (prefix: 'alma', asset: 'assets/icons/centos.svg'),
  (prefix: 'oracle', asset: 'assets/icons/oracle.svg'),
  (prefix: 'nixos', asset: 'assets/icons/nixos.svg'),
  // Nix (without the trailing OS) is the package manager invocation
  // — still show the NixOS snowflake.
  (prefix: 'nix', asset: 'assets/icons/nixos.svg'),
];

/// Resolve a WSL distro name (as reported by `wsl.exe --list`) to the
/// icon asset to display. Returns [kWslFallbackAsset] when no
/// prefix match is found. The match is case-insensitive against the
/// distro's lower-cased leading token (e.g. `Ubuntu-22.04` → `ubuntu`).
@visibleForTesting
String resolveWslIconAsset(String distro) {
  final first = distro.trim().toLowerCase().split(RegExp(r'[\s\-]+')).first;
  for (final entry in _wslIconTable) {
    if (first.startsWith(entry.prefix)) return entry.asset;
  }
  return kWslFallbackAsset;
}

// ── Detection ────────────────────────────────────────────────────────

// NOTE: We previously tried injecting a PowerShell init snippet
// (via `-File` and later `-Command`) that wrapped `prompt` to emit
// OSC 0 + OSC 7 on every prompt. The plumbing on the Dart side
// (`Surface.currentCwd`, the `onPwdChanged` chain through
// `flutter_alacritty`'s `TerminalEngine` → `TerminalView` → `Surface`
// → chip `ListenableBuilder`) all works correctly — but the init
// script itself was unreliable inside ConPTY (sometimes the
// script never ran at all; sometimes it ran but the OSC sequences
// weren't picked up by the engine). We reverted to a clean
// `pwsh -NoLogo` launch and let the user rely on whatever they
// have configured in their $PROFILE if they want a dynamic title.
// Shells that emit OSC 7 by default (modern WSL distros, git-bash
// with a configured PROMPT_COMMAND) will still update the cwd in
// the chip via the existing `onPwdChanged` chain.

typedef PathProbe = bool Function(String path);
typedef WslDistroLister = List<String> Function(String wslPath);

/// Detect available shells on this Windows host.
///
/// Includes Command Prompt, Windows PowerShell, PowerShell 7, Git Bash, and
/// one profile per installed WSL distro — when their executables are found.
/// CMD and Windows PowerShell ship with virtually every desktop Windows
/// install; the others are added only when detected at standard locations
/// (PowerShell 7 also via PATH, WSL distros via `wsl.exe --list --quiet`).
///
/// Called once at app startup. The returned list is ordered by preference
/// (PowerShell 7, Windows PowerShell, CMD, then each WSL distro, then Git
/// Bash).
///
/// This function is synchronous on purpose: the work is a handful of
/// `File.existsSync` calls plus one `wsl.exe --list --quiet` (a fast
/// registry query that does NOT launch a distro — measured ~90 ms). All of
/// it runs before the first frame, where a brief blocking step cannot drop
/// an interactive frame. Distros are enumerated synchronously here so the
/// shell list is complete by the time the workspace builds.
List<ShellProfile> detectShells() => detectShellsFrom(
      fileExists: (p) => File(p).existsSync(),
      environment: Platform.environment,
      listWslDistros: _listWslDistros,
    );

/// Off-isolate variant of [detectShells]. The probe work
/// (`existsSync` × ~6, plus a `Process.runSync` for WSL) is fast in
/// absolute terms (~90 ms measured on a typical box) but blocks
/// the UI isolate — and that's right inside `_AppShellState.initState`,
/// between `runApp` and the first frame. Running the probe on a
/// background isolate via `Isolate.run` lets the first frame paint
/// while the shell list is being assembled; the workspace shows a
/// loading placeholder until the future resolves.
///
/// Returns the same `List<ShellProfile>` shape as [detectShells].
/// Errors are swallowed (mirroring [detectShells]'s try/catch
/// around `Process.runSync`); on failure an empty list is
/// returned, which the UI handles by showing the same loading
/// placeholder.
Future<List<ShellProfile>> detectShellsAsync() {
  return Isolate.run<List<ShellProfile>>(
    () => detectShellsFrom(
      fileExists: (p) => File(p).existsSync(),
      environment: Platform.environment,
      listWslDistros: _listWslDistros,
    ),
    debugName: 'ShellProfile.detect',
  );
}

/// Pure, host-independent core of [detectShells]. Builds the profile list
/// from explicit probes ([fileExists], [environment], [listWslDistros]) so it
/// can be exercised in tests without the real filesystem, registry, or
/// process environment. Driving the real host from a test would (a) leak the
/// developer's machine config — installed distros, install paths,
/// `%USERPROFILE%` — into the repo / CI logs, and (b) make the tests pass or
/// fail based on whoever's machine runs them. Both are unacceptable for a
/// unit test, hence this seam.
@visibleForTesting
List<ShellProfile> detectShellsFrom({
  required PathProbe fileExists,
  required Map<String, String> environment,
  required WslDistroLister listWslDistros,
}) {
  final profiles = <ShellProfile>[];
  final systemRoot = environment['SystemRoot'] ?? r'C:\Windows';
  final system32 = '$systemRoot\\System32';

  // ── PowerShell 7+ (pwsh.exe) ───────────────────────────────────
  //
  // Check well-known install paths and the user's PATH.
  final pwshPaths = [
    r'C:\Program Files\PowerShell\7\pwsh.exe',
    r'C:\Program Files\PowerShell\7-preview\pwsh.exe',
    r'C:\Program Files\PowerShell\6\pwsh.exe',
  ];
  String? pwsh;
  for (final p in pwshPaths) {
    if (fileExists(p)) {
      pwsh = p;
      break;
    }
  }
  // Also try PATH-based lookup.
  pwsh ??= _findOnPathIn('pwsh.exe', environment['PATH'] ?? '', fileExists);
  if (pwsh != null) {
    profiles.add(ShellProfile(
      label: 'PowerShell 7',
      program: pwsh,
      args: const ['-NoLogo'],
      icon: Icons.bolt,
      iconAsset: 'assets/icons/powershell.svg',
      color: _pwshBlue,
      shortName: 'pwsh',
    ));
  }

  // ── Windows PowerShell (present on virtually all Win10/11 desktops) ──
  final winPsPath = '$system32\\WindowsPowerShell\\v1.0\\powershell.exe';
  if (fileExists(winPsPath)) {
    profiles.add(ShellProfile(
      label: 'Windows PowerShell',
      program: winPsPath,
      args: const ['-NoLogo'],
      icon: Icons.bolt,
      // Same SVG as PowerShell 7: Microsoft uses one logo for both.
      iconAsset: 'assets/icons/powershell.svg',
      color: _pwshBlue,
      shortName: 'powershell',
    ));
  }

  // ── Command Prompt ─────────────────────────────────────────────
  final cmdPath = '$system32\\cmd.exe';
  if (fileExists(cmdPath)) {
    profiles.add(ShellProfile(
      label: 'Command Prompt',
      program: cmdPath,
      args: const [],
      icon: Icons.terminal,
      color: _cmdAmber,
      shortName: 'cmd',
    ));
  }

  // ── WSL — one profile per installed distro ─────────────────────
  //
  // We enumerate distros via `wsl.exe --list --quiet` rather than offering
  // a single "WSL" entry that launches the default distro. Each distro gets
  // its own profile (`wsl.exe -d <distro>`), so:
  //   - the dropdown distinguishes Ubuntu / Debian / … , and
  //   - the workspace can query each distro's OWN `$HOME`
  //     (`wsl -d <distro> wslpath -w ~`) instead of always resolving the
  //     default distro's home and drifting on non-default launches.
  //
  // `wsl.exe` existing does NOT imply a distro is registered, so we only add
  // profiles for distros the listing actually returns — no dead "WSL" entry
  // on a box where the feature is enabled but unused.
  final wslPath = '$system32\\wsl.exe';
  if (fileExists(wslPath)) {
    for (final distro in listWslDistros(wslPath)) {
      profiles.add(ShellProfile(
        label: distro,
        program: wslPath,
        args: ['-d', distro],
        wslDistro: distro,
        // Windows Terminal ships per-distro Tux-style PNGs for WSL
        // profiles (ms-appx:///ProfileIcons/wsl.png + per-distro
        // variants for Ubuntu/Debian/Fedora). Octodo goes one
        // further and ships per-distro SVGs resolved by
        // [resolveWslIconAsset]; the Material `laptop_chromebook`
        // is kept as a last-resort fallback for any distro the
        // resolver doesn't recognise.
        icon: Icons.laptop_chromebook,
        iconAsset: resolveWslIconAsset(distro),
        color: _wslGreen,
        shortName: _sanitizeShortName(distro),
        // Modern WSL distros (Ubuntu 22.04+, Debian 12+, Fedora 38+)
        // emit OSC 7 reliably — bash's default `PROMPT_COMMAND`
        // reports `\w`, and the shell's `__set_pwd` writes the
        // `file://host/path` URI the engine decodes into
        // `_engine.workingDir`.
        showCwdInTitle: true,
      ));
    }
  }

  // ── Git Bash ───────────────────────────────────────────────────
  //
  // We deliberately do NOT fall back to a PATH lookup for `bash.exe`:
  // every WSL install drops `C:\Windows\System32\bash.exe` (the "Bash on
  // Ubuntu on Windows" launcher) on PATH, and Cygwin / standalone MSYS2
  // installs add their own `bash.exe` too. None of those are Git Bash —
  // they have different startup semantics and (for WSL) a different cwd
  // mount layout (`/mnt/c/…` vs MSYS `/c/…`), so `translateCwdForShell`
  // would mis-translate the initial cwd and the tab would be mislabelled.
  // We therefore only trust the well-known Git for Windows / Scoop paths.
  final userProfile = environment['USERPROFILE'] ?? '';
  final gitBashPaths = [
    r'C:\Program Files\Git\bin\bash.exe',
    r'C:\Program Files (x86)\Git\bin\bash.exe',
    if (userProfile.isNotEmpty)
      '$userProfile\\scoop\\apps\\git\\current\\bin\\bash.exe',
  ];
  String? gitBash;
  for (final p in gitBashPaths) {
    if (fileExists(p)) {
      gitBash = p;
      break;
    }
  }
  if (gitBash != null) {
    profiles.add(ShellProfile(
      label: 'Git Bash',
      program: gitBash,
      args: const ['--login', '-i'],
      // `call_split` is the canonical "branching" glyph — the
      // visual identity of Git. Distinct from `code` (which reads
      // as a generic "code" button) and `terminal` (CMD). The
      // official Git branch-mark SVG in `iconAsset` supersedes it
      // where the renderer supports it.
      icon: Icons.call_split,
      iconAsset: 'assets/icons/git-bash.svg',
      color: _bashOrange,
      shortName: 'bash',
      // Git Bash's MSYS2 base ships a `PROMPT_COMMAND` that emits
      // OSC 7 reliably (the `\w` from `pwd` lands in the URI).
      // Users with a custom `.bashrc` that nukes it can edit this
      // to `false` — but the default config works.
      showCwdInTitle: true,
    ));
  }

  return profiles;
}

/// Search for [exeName] on a `PATH`-style string, testing each candidate with
/// [fileExists]. Used by [detectShellsFrom] for the pwsh.exe PATH lookup; the
/// probe is injected so the helper stays hermetic in tests.
String? _findOnPathIn(String exeName, String pathVar, PathProbe fileExists) {
  if (pathVar.isEmpty) return null;
  for (final dir in pathVar.split(';')) {
    if (dir.isEmpty) continue;
    final candidate = '$dir\\$exeName';
    if (fileExists(candidate)) return candidate;
  }
  return null;
}

/// Return the installed WSL distro names, via `wsl.exe --list --quiet`.
///
/// This is a fast registry query — it does NOT launch a distro or the WSL
/// VM — so the synchronous call is safe at startup (measured ~90 ms). An
/// empty result means WSL is present but has no distro registered (or the
/// query failed): callers then emit no WSL profiles rather than a dead
/// entry that would error at spawn time.
///
/// Docker Desktop registers private utility distros (`docker-desktop`,
/// `docker-desktop-data`) that are not meant to be driven interactively;
/// they are filtered out so the dropdown only lists real user distros.
List<String> _listWslDistros(String wslPath) {
  try {
    final result = Process.runSync(
      wslPath,
      const ['--list', '--quiet'],
      stdoutEncoding: null,
    );
    if (result.exitCode != 0) return const [];
    final names = decodeWslDistroList(result.stdout as List<int>);
    return names
        .where((n) => !n.toLowerCase().startsWith('docker-desktop'))
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

/// Decode the UTF-16LE body of `wsl.exe --list` output into distro names.
///
/// `wsl.exe` writes UTF-16LE regardless of the console codepage. Some
/// versions prefix a BOM (`FF FE`); `--quiet` on current builds omits it.
/// We strip the BOM only when present (so a BOM-less body is not shifted by
/// two bytes), then split on newlines and trim a trailing `(Default)` tag
/// that the non-quiet listing appends to the default distro.
@visibleForTesting
List<String> decodeWslDistroList(List<int> bytes) {
  if (bytes.length < 2) return const [];
  var start = 0;
  if (bytes[0] == 0xFF && bytes[1] == 0xFE) start = 2; // UTF-16LE BOM
  final codeUnits = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(codeUnits)
      .split(RegExp(r'[\r\n]+'))
      .map((s) => s.trim())
      .map((s) => s.replaceAll(RegExp(r'\s*\(Default\)\s*$'), '').trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

/// Build a stable, unique chip shortName from a distro name (lower-cased,
/// internal whitespace collapsed to `-`). Falls back to `wsl` for an empty
/// input so the chip always has something to render.
String _sanitizeShortName(String distro) {
  final s = distro.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
  return s.isEmpty ? 'wsl' : s;
}
