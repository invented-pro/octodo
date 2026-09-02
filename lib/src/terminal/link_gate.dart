// Scheme gate for links opened from the terminal surface.
//
// Trust model: any program running in the terminal can emit OSC 8
// hyperlinks — or text the URL detector picks up — whose display text
// is fully decoupled from the underlying URI. Handing such URIs
// straight to the OS lets a `cat`ed file (README, log, chat paste)
// reach registered protocol handlers (`search-ms:`, `ms-msdt:`,
// `vbscript:`, third-party app schemes, …) with one modifier+click.
// The modifier signals intent to open *a link*; it cannot signal
// informed consent to whatever handler the scheme dispatches to,
// because the user never sees the scheme (GH issue #5, item 1).
//
// Policy:
//   * http / https / mailto              → open directly.
//   * file:// local, non-executable      → open directly (debugging:
//     jumping from terminal output to a local log / config file).
//   * file:// pointing at an executable or a UNC share, and EVERY
//     other scheme → stop at a confirm-and-reveal dialog that shows
//     the full URI before the OS touches it.
//
// Deliberately NOT a blanket https-only allowlist: local file links
// are a real debugging workflow, and the confirm dialog keeps the
// escape hatch for the remaining cases instead of hard-blocking.

/// What the terminal should do with a link the user activated.
enum LinkGateDecision {
  /// Hand straight to the OS without prompting.
  openDirectly,

  /// Show the confirm-and-reveal dialog first — the URI either uses
  /// a non-web scheme or points at an executable / network share, so
  /// the user should see exactly what would be dispatched before it
  /// happens.
  confirmFirst,
}

/// File name extensions that EXECUTE (or inject, for `.reg` /
/// `.lnk`-style shortcuts) when "opened" through the OS shell —
/// ShellExecute on Windows, Launch Services on macOS — instead of
/// landing in a viewer or editor. Lowercase only; compare against
/// the lowercased extension from [classifyLinkUri].
const Set<String> kExecutableLinkExtensions = {
  // Windows PE / installer / control-plane formats.
  'exe', 'bat', 'cmd', 'com', 'pif', 'scr', 'cpl', 'msc',
  'msi', 'msp', 'mst',
  // Modern Windows package / update installers.
  'appx', 'appxbundle', 'msu', 'diagcab', 'settingcontent-ms', 'gadget',
  // Script-host formats (WSH / PowerShell / HTA) and interpreter
  // files whose associations run them (py launcher).
  'ps1', 'ps1xml', 'psd1', 'psm1',
  'vbs', 'vbe', 'js', 'jse', 'ws', 'wsf', 'wsh', 'hta',
  'py', 'pyw',
  // Shortcut / redirector files — "open" follows them somewhere else.
  'lnk', 'url', 'scf', 'reg',
  // macOS application bundles (Launch Services runs them).
  'app',
  // Executable on double-click where a JRE is installed.
  'jar',
};

/// Classify [uri] (already parsed and non-null) into the action the
/// terminal should take. Pure function — unit-tested in
/// `test/terminal_link_gate_test.dart`.
///
/// Dart's [Uri] lowercases the scheme, so `FILE:///…` lands in the
/// `file` case; a scheme-less URI (bare `example.com` text that the
/// detector picked up) has `scheme == ''` and falls through to
/// [LinkGateDecision.confirmFirst].
LinkGateDecision classifyLinkUri(Uri uri) {
  switch (uri.scheme) {
    case 'http':
    case 'https':
    case 'mailto':
      return LinkGateDecision.openDirectly;
    case 'file':
      // `file://server/share/…` is a UNC path: opening it makes an
      // SMB connection (NTLM credential exposure on Windows) and can
      // serve remote payloads from the share. Three host forms are
      // LOCAL per RFC 8089 / real-world emitters and must not take
      // the UNC branch:
      //   * empty host        — `file:///C:/logs/app.log` (canonical)
      //   * `localhost`       — `file://localhost/…` (macOS emitters)
      //   * single character  — `file://C:/Users/…`, where Windows
      //     software often leaks the drive letter into the authority
      //     (Dart parses host as `c`).
      final host = uri.host;
      final isUncShare =
          host.isNotEmpty && host != 'localhost' && host.length != 1;
      if (isUncShare) return LinkGateDecision.confirmFirst;
      final ext = _extensionOf(uri.path);
      if (ext != null && kExecutableLinkExtensions.contains(ext)) {
        return LinkGateDecision.confirmFirst;
      }
      return LinkGateDecision.openDirectly;
    default:
      return LinkGateDecision.confirmFirst;
  }
}

/// Human-readable reason line for the confirm dialog's body. Must
/// stay in sync with the branches of [classifyLinkUri] that return
/// [LinkGateDecision.confirmFirst].
String linkConfirmReason(Uri uri) {
  switch (uri.scheme) {
    case 'file':
      final host = uri.host;
      final isUncShare =
          host.isNotEmpty && host != 'localhost' && host.length != 1;
      if (isUncShare) {
        return 'This link points at a network file share, not a local '
            'file. Opening it can connect to a remote server.';
      }
      return 'This link points at an executable file. Opening it may '
          'run a program on this machine.';
    case '':
      return 'This text was detected as a link but has no scheme. '
          'Opening it asks the system to guess which program to use, '
          'which can run code.';
    default:
      return 'This link uses the "${uri.scheme}" scheme instead of a '
          'normal web address. Opening it asks the system to launch '
          'whatever program is registered for that scheme, which can '
          'run code.';
  }
}

/// Lowercased extension of the last path segment, or `null` when the
/// name has no extension (`Makefile`) or is a dotfile (`.bashrc` —
/// the leading dot is part of the name, not an extension marker).
///
/// The segment is normalized BEFORE the extension check to defeat the
/// Win32 tricks ShellExecute applies after us: it fully decodes
/// percent-escapes (Dart's `uri.path` only decodes unreserved ones,
/// so `%20` survives), truncates at the first control character
/// (the `%00` NUL trick turns `setup.exe%00` into `setup.exe`), and
/// strips trailing dots/spaces from the final segment (`setup.exe.`
/// and `setup.exe%20` both resolve to `setup.exe`). Classification
/// uses the normalized name; the ORIGINAL URI is still what gets
/// handed to the OS.
String? _extensionOf(String path) {
  final slash = path.lastIndexOf('/');
  final raw = slash >= 0 ? path.substring(slash + 1) : path;
  // Lenient decode (never throws, leaves malformed escapes alone).
  var base = Uri.decodeFull(raw);
  // Truncate at the FIRST control character — Win32 string handling
  // stops at NUL, so `setup.exe%00.pdf` resolves to `setup.exe`.
  final ctrl = RegExp(r'[\x00-\x1f\x7f]').firstMatch(base);
  if (ctrl != null) base = base.substring(0, ctrl.start);
  // Strip trailing dots/whitespace from the final segment.
  base = base.replaceAll(RegExp(r'[ .]+$'), '');
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return null;
  return base.substring(dot + 1).toLowerCase();
}
