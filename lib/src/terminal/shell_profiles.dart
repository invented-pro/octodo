import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';

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
  /// distro. The spawn layer does NOT add `-NoProfile`: the user's
  /// `$PROFILE` (oh-my-posh, starship, modules) must load. See
  /// `TerminalViewState._buildPtyLaunchArgs` and issue #1.
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

  /// Whether this shell's tab title should include the cwd via a
  /// shell-side cwd-reporting channel. Set to `true` when a reliable
  /// mechanism exists:
  ///
  /// - WSL / Git Bash: native OSC 7 emission (or via injected
  ///   `PROMPT_COMMAND`); parsed by the Alacritty core.
  /// - PowerShell: no native OSC 7 through ConPTY, so the workspace
  ///   injects a `prompt` override that emits OSC 2 with the cwd
  ///   (see `TerminalWorkspace._writePwshInitScript`); parsed in
  ///   `TerminalView._extractCwdFromPwshTitle`.
  ///
  /// Set to `false` when no mechanism is available (CMD), or when the
  /// mechanism is OSC 2 driven independently of this flag (Nushell —
  /// see [remembersCwd]).
  final bool showCwdInTitle;

  /// WSL only: the distro name passed to `wsl.exe -d <distro>`. null for
  /// every other shell. Lets the workspace query each distro's own `$HOME`
  /// as a Linux path (via `wsl -d <distro> wslpath -u ~`) instead of
  /// always resolving the default distro's home — which previously
  /// drifted when a tab launched a non-default distro.
  final String? wslDistro;

  /// `true` for `wsl.exe`-backed profiles. The workspace uses this to decide
  /// whether to translate the initial cwd to the `/mnt/<drive>/…` layout and
  /// whether to query the distro `$HOME`.
  bool get isWsl => _basenameOf(program).toLowerCase() == 'wsl.exe';

  /// `true` for `nu.exe` (Nushell). Used by the workspace and terminal
  /// view to identify Nushell for cwd tracking via OSC 2 title parsing
  /// (ConPTY eats OSC 7 from Nushell on Windows).
  bool get isNushell => _basenameOf(program).toLowerCase() == 'nu.exe';

  /// `true` for PowerShell (`pwsh.exe` and `powershell.exe`). Used by
  /// the workspace to inject a `prompt` function override that emits
  /// OSC 2 with the cwd (ConPTY eats OSC 7 from PowerShell, same
  /// restriction as Nushell); used by the terminal view to dispatch
  /// title parsing in `TerminalView._syncTitle`.
  bool get isPowerShell {
    final base = _basenameOf(program).toLowerCase();
    return base == 'pwsh.exe' || base == 'powershell.exe';
  }

  /// Whether the workspace should remember this shell's cwd for
  /// cross-tab persistence. Distinct from [showCwdInTitle]:
  ///
  /// - WSL / Git Bash: both `true` (OSC 7 is reliable AND drives the
  ///   chip title via `fallbackTitle`).
  /// - Nushell: `showCwdInTitle` is `false` (chip title comes from
  ///   OSC 2), but `remembersCwd` is `true` because the cwd is parsed
  ///   from Nushell's OSC 2 title by `TerminalView._extractCwdFromNuTitle`.
  /// - PowerShell: `showCwdInTitle` is `true` (the injected `prompt`
  ///   emits OSC 2 with the cwd, parsed by
  ///   `TerminalView._extractCwdFromPwshTitle`).
  /// - CMD: `false` (no cwd-reporting mechanism through ConPTY).
  bool get remembersCwd => showCwdInTitle || isNushell;

  /// `true` for bash-based shells that pick up the `PROMPT_COMMAND` env var
  /// to emit OSC 7. This covers:
  ///
  /// - WSL (`wsl.exe`): needs the injection because the parent Windows
  ///   process has no `PROMPT_COMMAND` to inherit.
  /// - Git Bash (`bash.exe` / `sh.exe`): its MSYS2 base may or may not ship
  ///   a default `PROMPT_COMMAND` (especially Debian WSL, plain Git Bash).
  /// - POSIX bash (`/bin/bash`, `/opt/homebrew/bin/bash`, …): stock macOS
  ///   and most Linux installs (anything without `/etc/profile.d/vte.sh`)
  ///   emit no OSC 7 by default, so the env injection is what makes the
  ///   cwd-reporting channel work at all.
  ///
  /// Nushell, PowerShell, zsh, and fish do NOT use `PROMPT_COMMAND` (zsh
  /// uses `precmd` hooks, fish uses event handlers — the workspace injects
  /// those shells via their own mechanisms), so they must be excluded from
  /// the env injection in `_makeSurface`.
  bool get needsPromptCommandForOsc7 {
    if (isWsl) return true;
    final base = _basenameOf(program).toLowerCase();
    return base == 'bash.exe' || base == 'sh.exe' || base == 'bash';
  }

  /// `true` for POSIX zsh profiles (basename `zsh`, no `.exe` — Windows
  /// never produces these). Used by the workspace to inject an OSC 7
  /// `precmd` hook via the `ZDOTDIR` shim
  /// (`TerminalWorkspace._ensureZshOsc7Integration`): stock zsh (macOS and
  /// most Linuxes) does NOT emit OSC 7 without shell integration.
  bool get isPosixZsh => _basenameOf(program).toLowerCase() == 'zsh';

  /// `true` for POSIX fish profiles (basename `fish`, no `.exe`). Used by
  /// the workspace to append `--init-command` to the spawn args
  /// (`TerminalWorkspace._fishOsc7Init`): fish reads no env-var hooks, and
  /// `-C` code runs after the user's `config.fish`, so the OSC 7 event
  /// handler survives user config. Stock fish emits no OSC 7 on any
  /// platform.
  bool get isPosixFish => _basenameOf(program).toLowerCase() == 'fish';

  /// `true` for PowerShell profiles whose `prompt` function must be
  /// overridden at startup to emit OSC 2 with the cwd. The override is
  /// a temp-file PowerShell script loaded via `-File` (see
  /// `TerminalWorkspace._writePwshInitScript`). Gated on [showCwdInTitle]
  /// so a profile that opts out (e.g. for debugging) skips the injection.
  bool get needsPowerShellPromptOverride => isPowerShell && showCwdInTitle;

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

/// Basename of a shell [program] path that splits on BOTH `/` and `\`.
///
/// `p.basename` (from package:path) picks its separator style from the
/// *host* platform, so on a macOS/Linux host it treats
/// `C:\Windows\System32\wsl.exe` as one giant filename — every
/// Windows-path profile then fails its basename checks, and tests
/// asserting those checks fail when run on POSIX CI. This helper is
/// host-independent, mirroring `_basename` in `shell_cwd.dart`.
String _basenameOf(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

// ── Predefined icon colours ──────────────────────────────────────────

const _pwshBlue = Color(0xFF0078D4); // Microsoft blue
const _cmdAmber = Color(0xFFE8A838); // CMD amber
const _wslGreen = Color(0xFF22C55E); // Linux green (Tux)
const _bashOrange = Color(0xFFF05033); // Git orange-red
const _nuTeal = Color(0xFF3FB28F); // Nushell prompt green
// Neutral grey for POSIX shells (zsh / bash / fish) — no shell in this
// family ships a Material glyph or a bundled SVG, so the icon is always
// `Icons.terminal` and the tint stays understated to match.
const _posixGrey = Color(0xFF9E9E9E);

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

/// True when [path] is a reachable executable on the host — a real file OR
/// a Windows App Execution Alias / reparse-point shim.
///
/// `File(path).existsSync()` alone returns `false` for App Execution
/// Aliases — the zero-byte reparse points in `%LOCALAPPDATA%\Microsoft\
/// WindowsApps\` where Microsoft-Store-installed PowerShell 7 (`pwsh.exe`)
/// and Scoop shims live. `Link.existsSync()` returns `true` for those, so
/// OR-ing the two lets detection see past the alias. For a normal file
/// `Link.existsSync()` returns `false`, making the OR harmless on regular
/// executables. This is the probe used by both [detectShells] and
/// [detectShellsAsync]; tests inject their own [PathProbe].
bool _hostPathExists(String path) =>
    File(path).existsSync() || Link(path).existsSync();

/// Detect available shells on this host (Windows, macOS, or Linux).
///
/// Dispatches by host platform:
///
/// - **Windows**: delegates to [detectShellsFrom] (CMD, Windows PowerShell,
///   PowerShell 7, Git Bash, Nushell, one profile per WSL distro).
/// - **macOS / Linux**: delegates to [detectShellsPosixFrom] (`$SHELL`,
///   `/bin/zsh`, `/bin/bash`, and fish at its common install paths).
///
/// Called once at app startup. The returned list is ordered by preference;
/// see each delegate for its ordering rationale.
///
/// This function is synchronous on purpose: the work is a handful of
/// `File.existsSync` calls plus, on Windows, one `wsl.exe --list --quiet`
/// (a fast registry query that does NOT launch a distro — measured ~90 ms).
/// All of it runs before the first frame, where a brief blocking step cannot
/// drop an interactive frame. Distros are enumerated synchronously here so
/// the shell list is complete by the time the workspace builds.
List<ShellProfile> detectShells() {
  if (Platform.isWindows) {
    return detectShellsFrom(
      fileExists: _hostPathExists,
      environment: Platform.environment,
      listWslDistros: _listWslDistros,
    );
  }
  return detectShellsPosixFrom(
    fileExists: _hostPathExists,
    environment: Platform.environment,
    isMacOSHost: Platform.isMacOS,
  );
}

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
  if (Platform.isWindows) {
    return Isolate.run<List<ShellProfile>>(
      () => detectShellsFrom(
        fileExists: _hostPathExists,
        environment: Platform.environment,
        listWslDistros: _listWslDistros,
      ),
      debugName: 'ShellProfile.detect',
    );
  }
  // POSIX hosts need no WSL distro enumeration (no ConPTY, no `wsl.exe`),
  // so the probe is purely a handful of `File.existsSync` calls — still
  // off-loaded to a background isolate so the first frame paints while the
  // shell list assembles.
  return Isolate.run<List<ShellProfile>>(
    () => detectShellsPosixFrom(
      fileExists: _hostPathExists,
      environment: Platform.environment,
      isMacOSHost: Platform.isMacOS,
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

  // Environment-derived install roots shared across the shell probes
  // below (PowerShell 7, Git Bash, Nushell). Declared once here so the
  // individual blocks don't each re-read the environment.
  final localAppData = environment['LOCALAPPDATA'] ?? '';
  final userProfile = environment['USERPROFILE'] ?? '';
  final programFiles = environment['ProgramFiles'] ?? r'C:\Program Files';
  final programFilesX86 =
      environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
  final programData = environment['ProgramData'] ?? r'C:\ProgramData';

  // ── PowerShell 7+ (pwsh.exe) ───────────────────────────────────
  //
  // PowerShell 7 ships from many sources — MSI (per-machine and
  // per-user), winget (per-machine and per-user), Microsoft Store (an
  // App Execution Alias reparse point), Scoop, Chocolatey, and the
  // `dotnet tool install -g PowerShell` global tool. We enumerate each
  // method's well-known landing zone before falling back to PATH; the
  // first probe that hits wins, so we never emit duplicate entries even
  // when several paths point at the same binary.
  //
  // The Microsoft Store alias and the Scoop shim are reparse points
  // that `File.existsSync()` alone cannot see — they rely on the
  // `Link.existsSync()` branch of the injected [fileExists] probe (see
  // [_hostPathExists]).
  final pwshPaths = <String>[
    // Per-machine MSI (default), winget --scope machine, Chocolatey.
    '$programFiles\\PowerShell\\7\\pwsh.exe',
    '$programFiles\\PowerShell\\7-preview\\pwsh.exe',
    '$programFiles\\PowerShell\\6\\pwsh.exe',
    // Per-user MSI / winget --scope user.
    if (localAppData.isNotEmpty)
      '$localAppData\\Microsoft\\PowerShell\\7\\pwsh.exe',
    // winget per-user Programs manifest layout.
    if (localAppData.isNotEmpty)
      '$localAppData\\Programs\\PowerShell\\7\\pwsh.exe',
    // Microsoft Store — App Execution Alias. Needs _hostPathExists.
    if (localAppData.isNotEmpty)
      '$localAppData\\Microsoft\\WindowsApps\\pwsh.exe',
    // Scoop: real binary, then the shim (shim is itself a reparse point).
    if (userProfile.isNotEmpty)
      '$userProfile\\scoop\\apps\\pwsh\\current\\pwsh.exe',
    if (userProfile.isNotEmpty) '$userProfile\\scoop\\shims\\pwsh.exe',
    // Chocolatey shim.
    if (programData.isNotEmpty) '$programData\\chocolatey\\bin\\pwsh.exe',
    // Older Chocolatey package variant.
    r'C:\tools\powershell-7\pwsh.exe',
    // .NET global tool (`dotnet tool install -g PowerShell`).
    if (userProfile.isNotEmpty) '$userProfile\\.dotnet\\tools\\pwsh.exe',
  ];
  String? pwsh;
  for (final p in pwshPaths) {
    if (fileExists(p)) {
      pwsh = p;
      break;
    }
  }
  // PATH fallback covers portable / zip installs dropped into a directory
  // the user has on PATH but that isn't in our enumerate list above.
  pwsh ??= _findOnPathIn('pwsh.exe', environment['PATH'] ?? '', fileExists);
  if (pwsh != null) {
    profiles.add(
      ShellProfile(
        label: 'PowerShell 7',
        program: pwsh,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        iconAsset: 'assets/icons/powershell-7.svg',
        color: _pwshBlue,
        shortName: 'pwsh',
        showCwdInTitle: true,
      ),
    );
  }

  // ── Windows PowerShell (present on virtually all Win10/11 desktops) ──
  final winPsPath = '$system32\\WindowsPowerShell\\v1.0\\powershell.exe';
  if (fileExists(winPsPath)) {
    profiles.add(
      ShellProfile(
        label: 'PowerShell 5',
        program: winPsPath,
        args: const ['-NoLogo'],
        icon: Icons.bolt,
        // Plain blue shield: PS7 uses the dark powershell-7.svg variant so
        // the two are visually distinct in the dropdown / tab chips.
        iconAsset: 'assets/icons/powershell.svg',
        color: _pwshBlue,
        shortName: 'powershell',
        showCwdInTitle: true,
      ),
    );
  }

  // ── Command Prompt ─────────────────────────────────────────────
  final cmdPath = '$system32\\cmd.exe';
  if (fileExists(cmdPath)) {
    profiles.add(
      ShellProfile(
        label: 'Command Prompt',
        program: cmdPath,
        args: const [],
        icon: Icons.terminal,
        color: _cmdAmber,
        shortName: 'cmd',
      ),
    );
  }

  // ── WSL — one profile per installed distro ─────────────────────
  //
  // We enumerate distros via `wsl.exe --list --quiet` rather than offering
  // a single "WSL" entry that launches the default distro. Each distro gets
  // its own profile (`wsl.exe -d <distro> --cd ~`), so:
  //   - the dropdown distinguishes Ubuntu / Debian / … , and
  //   - bash starts in each distro's OWN `$HOME`, regardless of whatever
  //     Windows cwd the parent process happens to have (cmd.exe uses
  //     the workspace's userHome, and `wsl.exe` would otherwise translate
  //     it to `/mnt/c/Users/<name>` — see also `_queryWslHome` in
  //     terminal_workspace.dart, which keeps the Surface's `initialCwd`
  //     in sync so the tab chip's `~` shortcut fires).
  //
  // `wsl.exe` existing does NOT imply a distro is registered, so we only add
  // profiles for distros the listing actually returns — no dead "WSL" entry
  // on a box where the feature is enabled but unused.
  final wslPath = '$system32\\wsl.exe';
  if (fileExists(wslPath)) {
    for (final distro in listWslDistros(wslPath)) {
      profiles.add(
        ShellProfile(
          label: distro,
          program: wslPath,
          args: ['-d', distro, '--cd', '~'],
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
        ),
      );
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
    profiles.add(
      ShellProfile(
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
      ),
    );
  }

  // ── Nushell (nu.exe) ───────────────────────────────────────────
  //
  // Nushell does not ship with Windows; it's an optional install via
  // the official Nu MSI (`winget install Nushell.Nushell`), Scoop,
  // `cargo install nu`, or a hand-placed binary. We mirror Windows
  // Terminal's profile-generator strategy for PowerShell and probe
  // each install method's well-known landing zone:
  //
  //   1. Per-user winget / AppX layout under
  //      `%LocalAppData%\Programs\<app>\bin\` — the canonical path
  //      `winget install Nushell.Nushell` produces (modern winget /
  //      MSIX default puts the binary in the user's local Programs
  //      directory rather than `%ProgramFiles%`).
  //   2. Per-machine `%ProgramFiles%` — newer winget manifests and
  //      the MSI installer put `nu.exe` directly under
  //      `Program Files\nu\bin\nu.exe` (and its `Programs\nu\bin\`
  //      sibling on some manifests).
  //   3. Legacy Nu MSI under both `%ProgramFiles%` and
  //      `%ProgramFiles(x86)%` — historically `%ProgramFiles%\Nushell\nu.exe`
  //      (the x86 fallback here matters only for very old installs;
  //      Nushell dropped 32-bit builds around 0.83, so the modern
  //      `nu\bin\nu.exe` paths under x86 are intentionally absent).
  //   4. Scoop shims: the scoop-installed nushell always exposes
  //      `%USERPROFILE%\scoop\shims\nu.exe`.
  //   5. `cargo install nu` puts `nu.exe` in `%USERPROFILE%\.cargo\bin\`,
  //      a directory many users have on PATH themselves.
  //   6. PATH — a last-resort probe for hand-installed / portable copies.
  //
  // The detection order matters: the winget per-user path is checked
  // first because it's the most common modern install and the user's
  // Nushell lives there. Each candidate is tried in turn; the first
  // that exists wins, so we never emit duplicate entries even when
  // multiple paths point at the same binary.
  final nuPaths = <String>[
    if (localAppData.isNotEmpty) '$localAppData\\Programs\\nu\\bin\\nu.exe',
    if (userProfile.isNotEmpty) '$userProfile\\.cargo\\bin\\nu.exe',
    if (userProfile.isNotEmpty) '$userProfile\\scoop\\shims\\nu.exe',
    '$programFiles\\Programs\\nu\\bin\\nu.exe',
    '$programFiles\\nu\\bin\\nu.exe',
    '$programFiles\\Nushell\\nu.exe',
    '$programFilesX86\\Nushell\\nu.exe',
  ];
  String? nu;
  for (final candidate in nuPaths) {
    if (fileExists(candidate)) {
      nu = candidate;
      break;
    }
  }
  // PATH fallback covers `nu` on PATH via any installer we don't
  // enumerate (e.g. a portable copy dropped into `C:\Tools\`).
  // Unlike Git Bash we don't have to worry about a name collision
  // with a system binary — `nu.exe` is unique to Nushell.
  nu ??= _findOnPathIn('nu.exe', environment['PATH'] ?? '', fileExists);
  if (nu != null) {
    profiles.add(
      ShellProfile(
        label: 'Nushell',
        program: nu,
        // Nushell has no `-NoLogo` analog — its startup banner is
        // controlled by `config.show_banner` in the user's `config.nu`
        // (out of scope for us to mutate). The valid startup flags are
        // `-i` (interactive — default), `-l` (login shell — would
        // disable login-time hooks users rely on), `-c <cmd>` (one-shot),
        // `--no-config-file`, `--no-history`, `--no-std-lib`. None of
        // them are appropriate defaults for a plain interactive tab.
        // Pass no args so `nu` reads its config and history files the
        // way the user already has them set up.
        args: const [],
        icon: Icons.terminal,
        iconAsset: 'assets/icons/nushell.svg',
        color: _nuTeal,
        shortName: 'nu',
        // `showCwdInTitle` stays `false`: the chip title uses Nushell's OSC 2
        // (window title, which includes the cwd and is on by default).
        // OSC 7 (cwd URI) is unreliable through ConPTY for Nushell. Cwd
        // persistence works by parsing the cwd from the OSC 2 title (see
        // `TerminalView._extractCwdFromNuTitle` and [remembersCwd]).
        showCwdInTitle: false,
      ),
    );
  }

  return profiles;
}

/// Search for [exeName] on a `PATH`-style string, testing each candidate with
/// [fileExists]. Used by [detectShellsFrom] for the `pwsh.exe` and `nu.exe`
/// PATH fallbacks; the probe is injected so the helper stays hermetic in
/// tests.
String? _findOnPathIn(String exeName, String pathVar, PathProbe fileExists) {
  if (pathVar.isEmpty) return null;
  for (final dir in pathVar.split(';')) {
    if (dir.isEmpty) continue;
    final candidate = '$dir\\$exeName';
    if (fileExists(candidate)) return candidate;
  }
  return null;
}

// ── POSIX shell detection (macOS + Linux) ────────────────────────────
//
// Sibling to the Windows-only [detectShellsFrom] above. The two never
// overlap at runtime (the host is either Windows or POSIX), but they're
// kept as separate top-level functions so each has a focused,
// host-independent testable seam. [detectShells] / [detectShellsAsync]
// dispatch to the right one by platform.

/// Pure, host-independent core of [detectShellsPosix]. Mirrors the
/// testable-seam shape of [detectShellsFrom]: callers inject [fileExists]
/// (so tests never touch the real filesystem) and [environment] (so tests
/// simulate `$SHELL` without mutating `Platform.environment`).
///
/// Detection probes, in priority order (first match wins, deduped by
/// resolved path so `$SHELL=/bin/zsh` doesn't double-count `/bin/zsh`):
///
/// 1. **`$SHELL`** env var — when set, non-empty, AND the path exists, it
///    becomes the first profile. This is the user's login shell and gets
///    top priority: a user who switched to fish via `chsh` expects fish
///    first in the dropdown, not a hardcoded zsh/bash ordering.
/// 2. **`/bin/zsh`** — the macOS default since 10.15 Catalina and present
///    on most Linux distros that ship it.
/// 3. **`/bin/bash`** — present on virtually every Linux install per the
///    FHS, and still on macOS (Apple ships 3.2 as `/bin/bash` for licensing
///    reasons even after zsh became the default).
/// 4. **`/opt/homebrew/bin/fish`** — Apple Silicon Homebrew's default prefix.
/// 5. **`/usr/local/bin/fish`** — Intel Homebrew on macOS, and the common
///    manual-install prefix on Linux.
/// 6. **`/usr/bin/fish`** — system package manager install (apt / dnf).
///
/// [isMacOSHost] differentiates the platform for future default-fallback
/// decisions (macOS leans zsh, Linux leans bash). It is passed as a
/// parameter rather than read from `Platform.isMacOS` inside the function
/// so tests can simulate either host without depending on the CI runner's
/// OS — the same hermeticity principle that drives [detectShellsFrom]'s
/// injected probes.
///
/// [resolveExecutable], when non-null, is a last-resort PATH lookup for
/// fish (called as `resolveExecutable('fish')`, returning the resolved
/// absolute path or an empty string when not found). The production
/// [detectShellsPosix] call does NOT pass it — the three explicit fish
/// paths above cover every standard install — but the seam is kept so a
/// future "fish anywhere on PATH" mode can be added without changing the
/// signature, and so tests can exercise the PATH fallback in isolation.
///
/// Every emitted profile has:
/// - `args: const ['-l', '-i']` — interactive login shell. The two flags
///   together are what gets the user's dotfiles + prompt helpers (PROMPT_COMMAND,
///   starship, mise, cmux) to actually run:
///     - `-l` (login): sources `.bash_profile` / `.zprofile` / `.profile` /
///       `.zshrc` / `.config/fish/config.fish` as appropriate for the shell.
///     - `-i` (interactive): forces `.bashrc` to be sourced even if the
///       login dotfiles didn't chain to it (the standard `[ -f ~/.bashrc ]
///       && . ~/.bashrc` chain only triggers for interactive shells).
///       Without `-i`, bash treats `flutter_pty`'s spawn as non-interactive
///       (its `$0` is just `bash`, not `-bash`), so PROMPT_COMMAND never
///       fires — which is what breaks all the user's prompt-side helpers
///       (starship, `_cmux_prompt_command`, mise's hook, etc.).
///   Mirrors Git Bash on Windows (`args: const ['--login', '-i']`, line 508
///   above): the same login+interactive combo, just with the POSIX flag
///   spelling. The documented xterm/rxvt/urxvt default is non-login
///   non-interactive, but those emulators don't carry a user's prompt
///   stack; we do, so we need both flags.
/// - `icon: Icons.terminal` — no shell-specific Material glyph exists for
///   zsh / bash / fish.
/// - `iconAsset: null` — no SVG assets are shipped for POSIX shells, so
///   the renderer falls back to [ShellProfile.icon].
/// - `color: _posixGrey` — neutral tint.
/// - `shortName`: basename without extension (`zsh`, `bash`, `fish`).
/// - `showCwdInTitle: true` — the workspace injects OSC 7 emission for
///   all three families (stock macOS/Linux shells don't emit it on their
///   own), so the cwd-reporting channel works out of the box.
/// - `wslDistro: null` — POSIX shells are never WSL.
@visibleForTesting
List<ShellProfile> detectShellsPosixFrom({
  required PathProbe fileExists,
  required Map<String, String> environment,
  required bool isMacOSHost,
  String Function(String)? resolveExecutable,
}) {
  final profiles = <ShellProfile>[];
  // Resolved paths already emitted — drives dedup so $SHELL=/bin/zsh plus
  // the static /bin/zsh probe produce exactly one zsh profile, not two.
  final seen = <String>{};
  // Short names already emitted — drives dedup so $SHELL=/opt/homebrew/bin/bash
  // plus the static /bin/bash probe produce exactly one bash profile even
  // though they resolve to distinct binaries (Apple's /bin/bash 3.2 vs.
  // Homebrew's bash 5.x are real different files, not a symlink pair).
  final seenShortNames = <String>{};

  /// Emit [programPath] as a POSIX shell profile if it exists on the host
  /// and hasn't already been emitted. Dedup is by resolved path AND by
  /// short name: two probes pointing at the same binary collapse, and a
  /// $SHELL-derived /opt/homebrew/bin/bash wins over a subsequent /bin/bash
  /// probe because both share the basename "bash".
  void emitShell(String programPath) {
    if (!fileExists(programPath)) return; // not present on this host
    final shortName = _posixShortName(programPath);
    if (seenShortNames.contains(shortName)) {
      // Already have a profile with this basename (typically the
      // $SHELL-derived Homebrew bash suppressing the static /bin/bash
      // probe, or the first fish-path probe suppressing a later one).
      return;
    }
    if (seen.contains(programPath)) return; // path already emitted
    seen.add(programPath);
    seenShortNames.add(shortName);
    profiles.add(
      ShellProfile(
        label: _posixLabel(shortName),
        program: programPath,
        // Launch as an interactive login shell (`-l -i`) so the user's
        // dotfiles AND prompt helpers actually run:
        //
        //   zsh   → -l: ~/.zprofile, ~/.zshrc, ~/.zlogin
        //          -i: forces interactive mode (zsh auto-detects TTY, but
        //              explicit -i guards against PTY-pair edge cases where
        //              fd 0 is a pipe rather than a tty)
        //
        //   bash  → -l: ~/.bash_profile, ~/.bash_login, ~/.profile
        //          -i: sources ~/.bashrc (without -i, bash skips .bashrc
        //              in login mode — the standard
        //              `[ -f ~/.bashrc ] && . ~/.bashrc` chain in
        //              .bash_profile only fires when bash is interactive),
        //              AND makes PROMPT_COMMAND fire on every prompt
        //              (PROMPT_COMMAND is a no-op in non-interactive
        //              shells — that's how -i triggers starship /
        //              _cmux_prompt_command / mise hooks).
        //
        //   fish  → -l: ~/.config/fish/config.fish
        //          -i: same as zsh — explicit interactive flag.
        //
        // Without `-i`, $PROMPT_COMMAND is silently ignored by bash, so the
        // user's `PROMPT_COMMAND='_mise_hook_prompt_command;_cmux_prompt_command;
        // starship_precmd;__ghostty_hook 2>/dev/null'` fires the
        // `bash: _cmux_prompt_command: command not found` warning ONCE per
        // tab, the bootstrap function never gets defined, and the user's
        // prompt stays broken. User explicitly requested interactive bash.
        //
        // Mirrors Git Bash on Windows (line 508: `args: const ['--login',
        // '-i']`) — same login+interactive combo, POSIX flag spelling.
        args: const ['-l', '-i'],
        icon: Icons.terminal,
        iconAsset: null,
        color: _posixGrey,
        shortName: shortName,
        // Stock zsh / bash / fish emit NO OSC 7 without shell integration
        // (macOS zsh, fish everywhere, and bash on any host without
        // vte.sh) — but the flag stays true because the workspace injects
        // emission per shell family: PROMPT_COMMAND for bash
        // (`needsPromptCommandForOsc7`), a ZDOTDIR .zshenv shim for zsh
        // (`isPosixZsh`), and a fish `--init-command` for fish
        // (`isPosixFish`). No ConPTY mangling on POSIX hosts, so the
        // injected OSC 7 reaches the engine unmodified and drives the tab
        // chip's `~` shortcut and cross-tab cwd persistence.
        showCwdInTitle: true,
      ),
    );
  }

  // 1. $SHELL — the user's login shell (chsh target). Highest priority so
  //    a user who switched to fish sees fish first in the dropdown.
  final envShell = environment['SHELL'];
  if (envShell != null && envShell.isNotEmpty) {
    emitShell(envShell);
  }

  // 2–3. zsh and bash at their FHS / macOS-standard locations.
  emitShell('/bin/zsh');
  emitShell('/bin/bash');

  // 4–6. fish at its common install prefixes (Apple Silicon Homebrew,
  //      Intel Homebrew / Linux manual, system package manager).
  emitShell('/opt/homebrew/bin/fish');
  emitShell('/usr/local/bin/fish');
  emitShell('/usr/bin/fish');

  // Optional PATH fallback for fish — only when the explicit paths missed
  // AND the caller injected a resolver. The production call leaves this
  // null; tests use it to exercise the PATH-lookup branch in isolation.
  if (resolveExecutable != null) {
    final fishOnPath = resolveExecutable('fish');
    if (fishOnPath.isNotEmpty) {
      emitShell(fishOnPath);
    }
  }

  // Note: [isMacOSHost] is intentionally not branched on in the probe
  // logic above — the static probe list covers both macOS and Linux
  // (zsh and bash are present on both; fish paths are enumerated for
  // both prefixes). The parameter is part of the testable contract so
  // tests can simulate either host without depending on the CI runner's
  // OS (mirroring [detectShellsFrom]'s injected probes), and it is
  // reserved for a future platform-specific default-fallback decision.
  return profiles;
}

/// Derive a POSIX shell's shortName from its program path: the basename
/// with a trailing `.exe` stripped (defensive — POSIX paths never carry
/// `.exe`, but keeping the helper symmetric with the Windows shortName
/// derivation avoids a surprise if a symlink path ever includes it).
String _posixShortName(String programPath) {
  final base = _basenameOf(programPath);
  return base.endsWith('.exe') ? base.substring(0, base.length - 4) : base;
}

/// Capitalize the first letter of [shortName] for the dropdown label
/// (`zsh` → `Zsh`, `bash` → `Bash`, `fish` → `Fish`).
String _posixLabel(String shortName) {
  if (shortName.isEmpty) return 'Shell';
  return shortName[0].toUpperCase() + shortName.substring(1);
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
    final result = Process.runSync(wslPath, const [
      '--list',
      '--quiet',
    ], stdoutEncoding: null);
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
