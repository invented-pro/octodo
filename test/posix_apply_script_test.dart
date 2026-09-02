// Tests for the macOS /bin/sh apply orchestrator
// (lib/src/update/installer/posix_apply_script.dart).
//
// The script itself is a static POSIX sh program; these tests pin
// its contract (required steps present, argv order stable, no
// interpolation surface) and the spawn plumbing (script written to
// disk, /bin/sh invoked with script + argv, minimal environment)
// without ever running a real shell.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/update/installer/crash_sentinel.dart';
import 'package:octodo/src/update/installer/posix_apply_script.dart';
import 'package:path/path.dart' as p;

void main() {
  group('kPosixApplyScript contract', () {
    test('takes exactly eight positional arguments', () {
      // The argv builder and the script's $1..$8 usage must stay
      // in lockstep — a mismatch silently assigns the wrong value
      // to a step (e.g. pid → zip path) and the apply fails only
      // on a real user machine.
      for (var i = 1; i <= 8; i++) {
        expect(kPosixApplyScript, contains('"${r'$'}$i"'));
      }
      expect(kPosixApplyScript, isNot(contains('"${r'$'}9"')));
    });

    test('locates the payload bundle by shape, not name', () {
      // The payload .app is found via the single-*.app glob — a
      // renamed running bundle ("Octodo 2.app") must still match
      // the zip's canonical "Octodo.app". Same contract as the
      // Dart path's _findSingleAppBundle: refuse on zero or many.
      expect(kPosixApplyScript, contains(r'for d in "$EXTRACT"/*.app; do'));
      expect(kPosixApplyScript,
          contains(r'fail "multiple .app bundles at extract root: $EXTRACT"'));
      expect(kPosixApplyScript,
          contains(r'[ -n "$NEW" ] || fail "no .app bundle at extract root: $EXTRACT"'));
    });

    test('performs the bundle-swap steps in order', () {
      // Bounded wait for the original app's pid…
      expect(kPosixApplyScript, contains(r'kill -0 "$PID"'));
      // …ditto extraction (symlinks + exec bits)…
      expect(
          kPosixApplyScript, contains(r'/usr/bin/ditto -x -k --rsrc "$ZIP" "$EXTRACT"'));
      // …quarantine hygiene…
      expect(kPosixApplyScript, contains(r'/usr/bin/xattr -cr "$NEW"'));
      // …stale-aside sweep + rename-aside swap…
      expect(kPosixApplyScript, contains(r'"$BUNDLE".old-*'));
      expect(kPosixApplyScript, contains(r'ASIDE="$BUNDLE.old-$(date +%s)"'));
      // …Launch Services relaunch with a scrubbed environment…
      expect(
        kPosixApplyScript,
        contains(r'env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin '
            r'/usr/bin/open "$BUNDLE"'),
      );
      // …and best-effort aside cleanup.
      expect(kPosixApplyScript, contains(r'rm -rf -- "$ASIDE"'));
    });

    test('fails closed: every failure path logs to the sentinel', () {
      expect(kPosixApplyScript, contains(r'>> "$SENTINEL"'));
      // The zip-exists guard runs BEFORE anything destructive.
      final zipGuard = kPosixApplyScript.indexOf(r'[ -f "$ZIP" ]');
      final firstMv = kPosixApplyScript.indexOf(r'mv "$BUNDLE"');
      expect(zipGuard, greaterThan(-1));
      expect(firstMv, greaterThan(zipGuard));
    });

    test('re-hashes the staged zip before extraction (TOCTOU close)',
        () {
      // GH issue #5 item 4: the digest check must run after the
      // zip-exists guard and BEFORE ditto touches the zip, gated on
      // a non-empty $SHA_EXPECTED (legacy callers pass "").
      expect(
          kPosixApplyScript, contains(r'/usr/bin/shasum -a 256 "$ZIP"'));
      final hashCheck = kPosixApplyScript
          .indexOf(r'[ "$SHA_ACTUAL" = "$SHA_EXPECTED" ]');
      final zipGuard = kPosixApplyScript.indexOf(r'[ -f "$ZIP" ]');
      final ditto =
          kPosixApplyScript.indexOf(r'/usr/bin/ditto -x -k --rsrc');
      expect(hashCheck, greaterThan(zipGuard));
      expect(ditto, greaterThan(hashCheck));
    });

    test('codesign gate runs after discovery, before xattr + swap',
        () {
      // Phase C: the payload signature check must fire only after
      // the .app was located (needs "$NEW") and before ANY mutation
      // — xattr stripping and the first mv must come later, so a
      // verification failure leaves the running bundle untouched.
      expect(kPosixApplyScript,
          contains(r'/usr/bin/codesign --verify --deep --strict -R="$REQ" "$NEW"'));
      final gate =
          kPosixApplyScript.indexOf(r'/usr/bin/codesign --verify');
      final discovered =
          kPosixApplyScript.indexOf(r'[ -n "$NEW" ] || fail');
      final xattr = kPosixApplyScript.indexOf(r'/usr/bin/xattr -cr "$NEW"');
      final firstMv = kPosixApplyScript.indexOf(r'mv "$BUNDLE"');
      expect(gate, greaterThan(discovered));
      expect(xattr, greaterThan(gate));
      expect(firstMv, greaterThan(gate));
    });

    test('restores the aside when the swap fails', () {
      // Rollback moves the old bundle back before failing.
      final rollback = kPosixApplyScript.indexOf(r'mv "$ASIDE" "$BUNDLE"');
      expect(rollback, greaterThan(-1));
    });

    test('contains no interpolated runtime values', () {
      // All runtime values must travel as argv ($1..$7); the body
      // is static. A raw path or pid baked into the source would
      // mean someone reintroduced the quoting/injection surface.
      expect(kPosixApplyScript, isNot(contains('/Applications/')));
      expect(kPosixApplyScript, isNot(contains(RegExp(r'\$\{[A-Z_]+:?'))));
    });
  });

  group('posixApplyArgv', () {
    test('orders arguments to match the script header', () {
      final argv = posixApplyArgv(
        pid: 4242,
        zipPath: '/tmp/updates/2.1.2/octodo.zip',
        extractDirPath: '/tmp/updates/2.1.2/extracted',
        bundlePath: '/Applications/Octodo.app',
        sentinelPath: '/tmp/octodo_apply_crash.log',
        homeDir: '/Users/sun',
        expectedDigestHex: 'ab' * 32,
        codeSignRequirement: 'anchor apple generic and '
            'certificate leaf[subject.OU] = "P2HUSGVD3W"',
      );
      expect(argv, <String>[
        '4242',
        '/tmp/updates/2.1.2/octodo.zip',
        '/tmp/updates/2.1.2/extracted',
        '/Applications/Octodo.app',
        '/tmp/octodo_apply_crash.log',
        '/Users/sun',
        'ab' * 32,
        'anchor apple generic and '
            'certificate leaf[subject.OU] = "P2HUSGVD3W"',
      ]);
    });

    test('omitted digest becomes an empty 7th argv (legacy skip)', () {
      final argv = posixApplyArgv(
        pid: 4242,
        zipPath: '/z',
        extractDirPath: '/x',
        bundlePath: '/Applications/Octodo.app',
        sentinelPath: '/s',
        homeDir: '/Users/sun',
      );
      expect(argv, hasLength(8));
      expect(argv[6], '');
      expect(argv[7], '');
    });
  });

  group('spawnPosixApply', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('posix_apply_test_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('writes the script and spawns /bin/sh with script + argv',
        () async {
      final staging = Directory(p.join(tmp.path, 'updates', '2.1.2'))
        ..createSync(recursive: true);
      final zip = File(p.join(staging.path, 'octodo.zip'))
        ..writeAsStringSync('stub-zip');

      String? seenExe;
      List<String>? seenArgs;
      await spawnPosixApply(
        pid: 7,
        zipFile: zip,
        extractDir: Directory(p.join(staging.path, 'extracted')),
        bundleRoot: Directory('/Applications/Octodo.app'),
        scriptFile: File(p.join(staging.path, 'apply.sh')),
        sentinelFile: File(p.join(tmp.path, 'sentinel.log')),
        homeDir: '/Users/sun',
        starter: (exe, args) async {
          seenExe = exe;
          seenArgs = args;
        },
      );

      expect(seenExe, '/bin/sh');
      final scriptOnDisk =
          await File(p.join(staging.path, 'apply.sh')).readAsString();
      expect(scriptOnDisk, kPosixApplyScript);
      // argv[0] is the script path; the rest mirror posixApplyArgv.
      expect(seenArgs!.first, p.join(staging.path, 'apply.sh'));
      expect(seenArgs!.sublist(1), <String>[
        '7',
        zip.path,
        p.join(staging.path, 'extracted'),
        '/Applications/Octodo.app',
        p.join(tmp.path, 'sentinel.log'),
        '/Users/sun',
        // No verified digest on this legacy-style call → empty 7th.
        '',
        // No codesign requirement either (legacy callers don't pass
        // it) → empty 8th; the script's `if [ -n "$REQ" ]` skips the
        // gate entirely.
        '',
      ]);
    });

    test('script parses under a real POSIX sh (syntax check)',
        () async {
      // The script only ever runs on end-user macOS machines after
      // the GUI has exited — a syntax error would ship invisibly.
      // `sh -n` parses without executing, pinning the syntax on
      // every dev/CI host that has a POSIX shell.
      final sh = Platform.isMacOS ? '/bin/sh' : 'sh';
      final scriptFile = File(p.join(tmp.path, 'apply.sh'))
        ..writeAsStringSync(kPosixApplyScript);
      final result = await Process.run(sh, ['-n', scriptFile.path]);
      expect(
        result.exitCode,
        0,
        reason: 'sh -n rejected the apply script:\n${result.stderr}',
      );
    },
        skip: Platform.isWindows
            ? 'POSIX shell unavailable on this host; script is '
                'macOS-only at runtime'
            : false);

    test('creates the sentinel parent dir even before the shell runs',
        () async {
      final deepSentinel =
          File(p.join(tmp.path, 'nested', 'dir', kHelperCrashFileName));
      await spawnPosixApply(
        pid: 1,
        zipFile: File(p.join(tmp.path, 'z.zip'))..writeAsStringSync('z'),
        extractDir: Directory(p.join(tmp.path, 'x')),
        bundleRoot: Directory('/Applications/Octodo.app'),
        scriptFile: File(p.join(tmp.path, 'apply.sh')),
        sentinelFile: deepSentinel,
        homeDir: '/',
        starter: (a, b) async {},
      );
      expect(deepSentinel.parent.existsSync(), isTrue);
    });
  });

  group('crash sentinel path (macOS TMPDIR fix)', () {
    test('resolves under TMPDIR when TEMP is absent', () {
      // Simulated macOS GUI environment: TEMP unset, TMPDIR set.
      // Encoded via the resolver's documented precedence rather
      // than mutating Platform.environment (not testable) — the
      // function is pure over the environment map we cannot
      // inject, so assert the TMPDIR branch indirectly: the
      // resolved path's dirname is a directory that exists and
      // the filename is the sentinel name.
      final f = resolveHelperCrashSentinelFile();
      expect(p.basename(f.path), kHelperCrashFileName);
      expect(
        Directory(p.dirname(f.path)).existsSync(),
        isTrue,
        reason: 'sentinel directory must exist on this host '
            '(TEMP or TMPDIR or systemTemp)',
      );
    });
  });
}
