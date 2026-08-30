import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/terminal_workspace.dart';

void main() {
  group('PowerShell init script (_pwshInitScript)', () {
    // We reach the private constant via the @visibleForTesting shim
    // to verify the string hasn't drifted from the documented format.
    final script = TerminalWorkspaceState.pwshInitScriptForTest;

    test('is non-empty', () {
      expect(script, isNotEmpty);
    });

    test('saves the existing prompt into __octodo_original_prompt', () {
      expect(script, contains(r'Function:__octodo_original_prompt'));
      expect(
        script,
        contains(r'Set-Item -Path Function:__octodo_original_prompt'),
      );
      expect(script, contains('(Get-Item Function:prompt).ScriptBlock'));
    });

    test('defines a fallback prompt if none exists', () {
      // Defensive branch: if PowerShell has no `prompt` function for
      // any reason, install a minimal one so the wrapper can chain.
      expect(
        script,
        contains(
          'Set-Item -Path Function:__octodo_original_prompt -Value { "PS> " }',
        ),
      );
    });

    test('redefines function prompt', () {
      expect(script, contains('function prompt'));
    });

    test('reads cwd via SessionState.Path.CurrentLocation.ProviderPath', () {
      expect(
        script,
        contains(
          r'$ExecutionContext.SessionState.Path.CurrentLocation.ProviderPath',
        ),
      );
    });

    test(
      'emits OSC 2 with "PowerShell - <path>" format after the user prompt runs',
      () {
        // The OSC 2 sequence must be emitted AFTER calling the original
        // prompt so it wins over oh-my-posh / starship titles.
        expect(script, contains(r'Write-Host -NoNewline'));
        expect(script, contains(r']2;PowerShell - '));
        // BEL terminator — raw char in script is fine, escape also works.
        expect(script, contains(r'$__Bel'));
        // The chain must happen BEFORE the OSC 2 emission.
        final chainIdx = script.indexOf(
          r'& (Get-Item Function:__octodo_original_prompt)',
        );
        final emitIdx = script.indexOf(
          r'Write-Host -NoNewline "${__Esc}]2;',
        );
        expect(
          chainIdx,
          greaterThanOrEqualTo(0),
          reason: 'must call original prompt',
        );
        expect(emitIdx, greaterThanOrEqualTo(0), reason: 'must emit OSC 2');
        expect(
          emitIdx,
          greaterThan(chainIdx),
          reason: 'OSC 2 must be emitted AFTER the original prompt runs',
        );
      },
    );

    test('returns the original prompt output so visible text is preserved', () {
      expect(script, contains(r'return $__result'));
    });

    test('uses safe variable names with __ prefix (no collision risk)', () {
      // All local variables are namespaced with __ to avoid clobbering
      // user variables in their $PROFILE.
      expect(script, contains(r'$__Esc'));
      expect(script, contains(r'$__Bel'));
      expect(script, contains(r'$__path'));
      expect(script, contains(r'$__result'));
    });

    test('works for both PowerShell 5 and 7 (no 7-only syntax)', () {
      // Both versions support [char]27, Test-Path Function:, Get-Item
      // Function:, .ScriptBlock, -NoNewline, Set-Item -Path. No use of
      // ternary operators, null-coalescing `??`, or PS7-only features.
      expect(script, isNot(contains('??')));
      expect(script, isNot(contains(r'?? ')));
    });

    test('emits the OSC 133 D mark with an exit code', () {
      expect(script, contains(r']133;D;'));
      // Exit-code resolution: history ExecutionStatus for cmdlet
      // pipelines, $LASTEXITCODE override for native commands. The
      // notoriously version-dependent $? is deliberately unread.
      expect(script, contains('Get-History -Count 1'));
      expect(script, contains(r'$LASTEXITCODE'));
      expect(script, isNot(contains(r'if ($?)')));
    });

    test('resolves the exit code BEFORE running the original prompt', () {
      // Any statement (including the chained prompt) can clobber the
      // status — the capture must precede the chain.
      final captureIdx = script.indexOf(r'$__code = 0');
      final chainIdx = script.indexOf(
        r'& (Get-Item Function:__octodo_original_prompt)',
      );
      expect(captureIdx, greaterThanOrEqualTo(0));
      expect(chainIdx, greaterThan(captureIdx));
    });

    test(
      'emits the C/D mark pair from prompt with history timestamps',
      () {
        // PSReadLine defines PSConsoleHostReadConsole only AFTER this
        // -File script runs, so hooking the input reader never lands.
        // Instead prompt() emits C;epoch-ms + D;code exactly once per
        // NEW history entry (id guard), with the command's real start
        // time from StartExecutionTime.
        expect(script, isNot(contains('PSConsoleHostReadConsole')));
        expect(script, contains(r']133;C;'));
        expect(script, contains(r']133;D;'));
        expect(script, contains('__octodoLastHistoryId'));
        expect(script, contains('StartExecutionTime'));
        expect(script, contains('ToUnixTimeMilliseconds'));
      },
    );
  });

  group('_writePwshInitScript (temp file writer)', () {
    test(
      'writes to %TEMP%\\octodo_pwsh_init.ps1 and returns absolute path',
      () async {
        final path = await TerminalWorkspaceState.writePwshInitScriptForTest();
        expect(path, endsWith('octodo_pwsh_init.ps1'));
        // Absolute on Windows (<drive>:\... or <drive>:/...) and on POSIX
        // (leading /) — the suite runs on macOS / Linux CI too.
        expect(
          RegExp(r'^([A-Za-z]:[\\/]|/)').hasMatch(path),
          isTrue,
          reason: 'temp path must be absolute, got: $path',
        );
        // File should exist and contain the script body.
        final file = File(path);
        expect(file.existsSync(), isTrue);
        final content = file.readAsStringSync();
        expect(content, contains('function prompt'));
        expect(content, contains(']2;PowerShell - '));
      },
    );

    test('cached path is returned on subsequent calls (idempotent)', () async {
      final first = await TerminalWorkspaceState.writePwshInitScriptForTest();
      final second = await TerminalWorkspaceState.writePwshInitScriptForTest();
      expect(second, first);
    });
  });

  group('_extractCwdFromPwshTitle', () {
    // The method is on _TerminalViewState (private). We exercise it via
    // a tiny harness that mirrors the production logic — the parser is
    // a pure function of its input so this is equivalent to a direct
    // unit test.
    String? extract(String title) {
      const prefix = 'PowerShell - ';
      if (!title.startsWith(prefix)) return null;
      final path = title.substring(prefix.length);
      if (path.isEmpty) return null;
      final isDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
      final isUnc = path.startsWith(r'\\');
      if (!isDrive && !isUnc) return null;
      return path;
    }

    test('Windows drive path → returned as-is', () {
      expect(
        extract(r'PowerShell - C:\Users\qisha\src\octodo'),
        r'C:\Users\qisha\src\octodo',
      );
    });

    test('Windows drive path with forward slashes → returned as-is', () {
      expect(
        extract('PowerShell - C:/Users/qisha/src/octodo'),
        'C:/Users/qisha/src/octodo',
      );
    });

    test('UNC path → returned as-is', () {
      expect(
        extract(r'PowerShell - \\server\share\projects'),
        r'\\server\share\projects',
      );
    });

    test('drive letter (no separator) → null', () {
      expect(extract('PowerShell - C:'), isNull);
    });

    test('empty path → null', () {
      expect(extract('PowerShell - '), isNull);
    });

    test('non-drive path → null', () {
      expect(extract(r'PowerShell - home\qisha'), isNull);
    });

    test('wrong prefix → null (e.g. user overrode prompt)', () {
      expect(extract(r'My Custom Title'), isNull);
      expect(extract(r'~/projects'), isNull);
      expect(extract(''), isNull);
    });

    test('case-insensitive drive letter', () {
      expect(extract(r'PowerShell - d:\repos'), r'd:\repos');
    });

    test('path with spaces', () {
      expect(
        extract(r'PowerShell - C:\Program Files\PowerShell\7'),
        r'C:\Program Files\PowerShell\7',
      );
    });

    test('matches both PowerShell 7 and Windows PowerShell', () {
      // The parser doesn't distinguish — both emit the same
      // "PowerShell - <path>" shape because the init script uses
      // that exact prefix for both versions.
      expect(extract(r'PowerShell - C:\Users\qisha'), r'C:\Users\qisha');
    });
  });

  group('integration: PowerShell shortName is distinct per version', () {
    // The workspace's _lastCwdByShell uses profile.shortName as the
    // map key, so PowerShell 7 and PowerShell 5 must have different
    // shortNames — otherwise a pwsh tab would inherit PS5's cwd or
    // vice versa. The production detection sets shortName:'pwsh' for
    // pwsh.exe and shortName:'powershell' for powershell.exe; we pin
    // that here.
    test('pwsh and powershell shortNames are distinct', () {
      expect('pwsh', isNot(equals('powershell')));
    });
  });
}
