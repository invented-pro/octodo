// Unit tests for the terminal link scheme gate (GH issue #5, item 1).
//
// The gate's contract:
//   * http/https/mailto           → openDirectly
//   * file:// local + non-exec    → openDirectly (debugging workflow)
//   * file:// executable or UNC   → confirmFirst
//   * every other scheme          → confirmFirst (search-ms:, ms-msdt:,
//     vbscript:, third-party handlers, scheme-less text, …)
//
// These pin the classification so a refactor can't silently loosen
// the gate (e.g. by breaking the UNC-host check or the dotfile
// handling in the extension parser).

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/link_gate.dart';

void main() {
  LinkGateDecision classify(String raw) => classifyLinkUri(Uri.parse(raw));

  group('classifyLinkUri — openDirectly', () {
    test('web and mail schemes', () {
      expect(classify('https://example.com'), LinkGateDecision.openDirectly);
      expect(classify('http://example.com/a?b=1#frag'),
          LinkGateDecision.openDirectly);
      expect(classify('mailto:someone@example.com'),
          LinkGateDecision.openDirectly);
    });

    test('scheme casing is normalized by Uri', () {
      // Uri lowercases the scheme — the gate must not re-check casing.
      expect(classify('HTTPS://EXAMPLE.COM'), LinkGateDecision.openDirectly);
      expect(classify('FILE:///C:/logs/app.log'),
          LinkGateDecision.openDirectly);
    });

    test('local file:// documents (logs, configs, source)', () {
      expect(classify('file:///C:/Users/me/logs/app.log'),
          LinkGateDecision.openDirectly);
      expect(classify('file:///home/me/project/README.md'),
          LinkGateDecision.openDirectly);
      expect(classify('file:///etc/os-release'), // no extension
          LinkGateDecision.openDirectly);
      expect(classify('file:///home/me/.bashrc'), // dotfile — no extension
          LinkGateDecision.openDirectly);
      expect(classify('file:///C:/tools/'), // directory
          LinkGateDecision.openDirectly);
    });

    test('RFC 8089 local-host forms skip the UNC branch', () {
      // macOS emitters use the explicit localhost authority.
      expect(classify('file://localhost/Users/me/notes.txt'),
          LinkGateDecision.openDirectly);
      // Windows software often leaks the drive letter into the
      // authority — Dart parses the host as a single character `c`.
      expect(classify('file://C:/Users/me/logs/app.log'),
          LinkGateDecision.openDirectly);
    });
  });

  group('classifyLinkUri — confirmFirst', () {
    test('shell protocol handlers', () {
      // The named offenders from the issue plus the general class.
      for (final raw in [
        'search-ms:query=evil&displayname=Documents',
        'ms-msdt:-di MSDT-Id',
        'vbscript:MsgBox(1)',
        'ms-word:ofe|u|https://evil/doc.docx',
        'zoommtg://join?confno=1',
        'steam://run/440',
        'some-unknown-scheme:whatever',
      ]) {
        expect(classify(raw), LinkGateDecision.confirmFirst, reason: raw);
      }
    });

    test('file:// pointing at executables', () {
      for (final ext in [
        'exe', 'bat', 'cmd', 'msi', 'lnk', 'ps1', 'vbs', 'hta', 'reg',
        'jar', 'app', 'appx', 'msu', 'py',
      ]) {
        final raw = 'file:///C:/Users/me/Downloads/setup.$ext';
        expect(classify(raw), LinkGateDecision.confirmFirst, reason: raw);
      }
    });

    test('Win32 shell normalization tricks still hit the extension set',
        () {
      // ShellExecute strips trailing dots/spaces and truncates at the
      // first control character after fully decoding escapes — all
      // four of these resolve to `setup.exe` on the Windows side, so
      // the gate must classify them on the NORMALIZED name.
      expect(classify('file:///C:/Users/me/Downloads/setup.exe.'),
          LinkGateDecision.confirmFirst);
      expect(classify('file:///C:/Users/me/Downloads/setup.exe%20'),
          LinkGateDecision.confirmFirst);
      expect(classify('file:///C:/Users/me/Downloads/setup.exe%2E'),
          LinkGateDecision.confirmFirst);
      expect(classify('file:///C:/Users/me/Downloads/setup.exe%00.pdf'),
          LinkGateDecision.confirmFirst);
      // The same tricks on a harmless document stay openDirectly —
      // normalization must not over-prompt the debugging workflow.
      expect(classify('file:///C:/logs/app.log.'),
          LinkGateDecision.openDirectly);
      expect(classify('file:///C:/logs/app%2Elog'),
          LinkGateDecision.openDirectly);
    });

    test('file:// executable check is case-insensitive on the extension',
        () {
      expect(classify('file:///C:/tools/INSTALLER.EXE'),
          LinkGateDecision.confirmFirst);
      expect(classify('file:///home/me/script.SH'), // not in the set
          LinkGateDecision.openDirectly);
    });

    test('file:// UNC shares (non-empty host)', () {
      // The share target itself is harmless (.txt) — the SMB
      // connection is the reason to confirm, not the extension.
      expect(classify('file://attacker/share/readme.txt'),
          LinkGateDecision.confirmFirst);
      expect(classify('file://server/data/log.txt'),
          LinkGateDecision.confirmFirst);
    });

    test('scheme-less URIs (auto-detected bare text)', () {
      expect(classify('example.com'), LinkGateDecision.confirmFirst);
      expect(classify('readme.txt'), LinkGateDecision.confirmFirst);
    });
  });

  group('linkConfirmReason', () {
    test('covers every confirmFirst branch with non-empty text', () {
      for (final raw in [
        'search-ms:query=x',
        'file:///C:/x/setup.exe',
        'file://server/share/doc.txt',
      ]) {
        final reason = linkConfirmReason(Uri.parse(raw));
        expect(reason, isNotEmpty, reason: raw);
      }
    });

    test('names the scheme for non-file URIs', () {
      expect(linkConfirmReason(Uri.parse('search-ms:query=x')),
          contains('"search-ms"'));
    });

    test('scheme-less text gets its own message, not empty quotes', () {
      final reason = linkConfirmReason(Uri.parse('example.com'));
      expect(reason, isNot(contains('""')));
      expect(reason, contains('no scheme'));
    });
  });
}
