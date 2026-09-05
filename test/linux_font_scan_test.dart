// Tests for the Linux font-family enumeration backend
// (`fc-list`-via-fontconfig) in font_family_options.dart.
//
// The parser (`parseFontconfigFamilyLines`) is a pure function, so
// its contract is pinned cross-platform — the same suite runs on
// Windows/macOS dev machines and CI. The end-to-end scan test is
// Linux-only (it invokes the real fc-list); it self-skips when
// fc-list isn't on PATH so the suite stays green in containers.

import 'dart:io' show Platform, Process;

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/font_family_options.dart';

void main() {
  group('parseFontconfigFamilyLines — --format=%{family[0]} shape', () {
    test('one family per line is kept, deduplicated and sorted', () {
      const output = 'Noto Sans\nDejaVu Sans Mono\nNoto Sans\n';
      expect(
        parseFontconfigFamilyLines(output),
        equals(['DejaVu Sans Mono', 'Noto Sans']),
      );
    });

    test('blank lines and whitespace are dropped', () {
      const output = '\n  \nNoto Sans\n\t\n  DejaVu Sans \n\n';
      expect(
        parseFontconfigFamilyLines(output),
        equals(['DejaVu Sans', 'Noto Sans']),
      );
    });

    test('fontconfig escapes are preserved verbatim', () {
      // fc-list serialises punctuation in family names with
      // backslash escapes. These must NOT be unescaped: the value
      // round-trips back into fontconfig when the renderer resolves
      // `terminal.fontFamily`, and fc-list's escaped spelling is
      // what fontconfig's pattern parser matches.
      const output = 'UKIJ Orxun\\-Yensey\nNoto Sans\n';
      expect(
        parseFontconfigFamilyLines(output),
        contains('UKIJ Orxun\\-Yensey'),
      );
    });

    test('empty input yields empty list', () {
      expect(parseFontconfigFamilyLines(''), isEmpty);
      expect(parseFontconfigFamilyLines('\n \n'), isEmpty);
    });

    test('commas are kept (index form never emits them, but be robust)', () {
      // If a future fontconfig starts comma-joining in --format
      // mode, the name still surfaces rather than being mangled.
      expect(parseFontconfigFamilyLines('A,B\n'), equals(['A,B']));
    });
  });

  group('parseFontconfigFamilyLines — legacy `fc-list : family` shape', () {
    test('only the first comma field of each line is kept', () {
      // Legacy output comma-joins a face's family list; fields
      // after the first are per-face compound names
      // ("Noto Sans Khmer SemiBold"), not families.
      const output =
          'Noto Sans,Noto Sans Condensed SemiBold\n'
          'Noto Sans Khmer,Noto Sans Khmer SemiBold\n'
          'Yrsa\n';
      expect(
        parseFontconfigFamilyLines(output, firstCommaFieldOnly: true),
        equals(['Noto Sans', 'Noto Sans Khmer', 'Yrsa']),
      );
    });

    test('duplicates across faces collapse, result is sorted', () {
      const output =
          'Noto Sans,Noto Sans Bold\n'
          'Noto Sans,Noto Sans Italic\n'
          'DejaVu Sans,DejaVu Sans Bold\n';
      expect(
        parseFontconfigFamilyLines(output, firstCommaFieldOnly: true),
        equals(['DejaVu Sans', 'Noto Sans']),
      );
    });

    test('trailing comma does not produce an empty entry', () {
      expect(
        parseFontconfigFamilyLines('A,\n', firstCommaFieldOnly: true),
        equals(['A']),
      );
    });

    test('escaped comma inside a family does not truncate the name', () {
      // A family literally named "Foo,Bar" is serialised by
      // fontconfig as `Foo\,Bar`; the list separator is the
      // *unescaped* comma after it. Splitting at the first raw
      // comma would yield the garbage entry `Foo\`.
      expect(
        parseFontconfigFamilyLines(
          'Foo\\,Bar,Foo Bold\n',
          firstCommaFieldOnly: true,
        ),
        equals(['Foo\\,Bar']),
      );
      // Doubled backslash is an escaped *backslash* — the comma
      // after it is a real separator. A family literally named
      // "Weird\,Name" serialises as Weird\\\,Name.
      expect(
        parseFontconfigFamilyLines(
          'Weird\\\\\\,Name,Other\n',
          firstCommaFieldOnly: true,
        ),
        equals(['Weird\\\\\\,Name']),
      );
      // No separator at all — whole line is the family.
      expect(
        parseFontconfigFamilyLines('A\\,B\n', firstCommaFieldOnly: true),
        equals(['A\\,B']),
      );
    });
  });

  group('scanInstalledFontFamilies on Linux', () {
    // End-to-end: exercises _enumerateLinux -> fc-list -> parser.
    // Requires fc-list on PATH (universal on desktop Linux); if
    // it's absent (container/minimal install) the e2e assertions
    // self-skip — that configuration is covered by the parser
    // tests plus the "scan returns empty" fallback contract.
    final fcListAvailable = _probeFcList();

    test('returns a non-empty, deduplicated family list', () async {
      if (!Platform.isLinux || !fcListAvailable) {
        // No fontconfig backend on this host — the scan contract
        // is "empty list", which the curated-fallback path in the
        // dropdown already covers.
        expect(await scanInstalledFontFamilies(), isA<List<String>>());
        return;
      }
      final fonts = await scanInstalledFontFamilies();
      expect(fonts, isNotEmpty,
          reason: 'fc-list is present; the enumeration must report '
              'the installed families');
      for (final f in fonts) {
        expect(f, isNotEmpty);
      }
      expect(fonts.toSet().length, fonts.length,
          reason: 'enumeration result must be deduplicated');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('result merges cleanly into the dropdown option list', () async {
      if (!Platform.isLinux || !fcListAvailable) return;
      final installed = await scanInstalledFontFamilies();
      final merged = mergeFontFamilies(
        installed: installed,
        pinCurrent: 'Some Custom Face',
      );
      // Pin first, curated fallbacks next, scan results sorted after.
      expect(merged.first, 'Some Custom Face');
      expect(merged, containsAll(<String>['monospace', 'JetBrains Mono']));
      if (installed.isNotEmpty) {
        expect(merged, contains(installed.first));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('warmDefaultPlatformMonospace seeds the getter off-isolate',
        () async {
      if (!Platform.isLinux) return; // no-op on other platforms
      await warmDefaultPlatformMonospace();
      final value = defaultPlatformMonospaceFont;
      expect(value, isNotEmpty);
      final probe = _probeFcMatchMonospace();
      if (probe != null) {
        // With fontconfig available the getter must carry the
        // concrete resolved family, not the generic literal.
        expect(value, equals(probe));
        expect(value, isNot(equals('monospace')));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

/// Mirror of the production `fc-match --format=%{family} monospace`
/// resolution, computed independently of the code under test.
String? _probeFcMatchMonospace() {
  try {
    final result = Process.runSync(
      'fc-match',
      const ['--format=%{family}', 'monospace'],
    );
    if (result.exitCode != 0) return null;
    var name = (result.stdout as String).trim();
    final comma = name.indexOf(',');
    if (comma >= 0) name = name.substring(0, comma);
    name = name.trim();
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}

/// True when `fc-list` is on PATH and exits cleanly. Probed with
/// `--version`, which touches no font files.
bool _probeFcList() {
  try {
    final result = Process.runSync('fc-list', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
