// Tests for the Linux /bin/sh AppImage apply orchestrator
// (lib/src/update/installer/linux_apply_script.dart).
//
// Contract tests (static script shape) run on every host; the
// behavioural tests actually EXECUTE /bin/sh + coreutils, so they
// are Linux-only (the target platform of the script) and skip
// elsewhere — same gating strategy as the macOS ditto tests in
// staged_apply_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/update/digest.dart';
import 'package:octodo/src/update/installer/linux_apply_script.dart';
import 'package:path/path.dart' as p;

void main() {
  group('kLinuxApplyScript contract', () {
    test('takes exactly five positional arguments', () {
      // The argv builder and the script's $1..$5 usage must stay
      // in lockstep — a mismatch silently assigns the wrong value
      // to a step and the apply fails only on a real user machine.
      for (var i = 1; i <= 5; i++) {
        expect(kLinuxApplyScript, contains('"${r'$'}$i"'));
      }
      expect(kLinuxApplyScript, isNot(contains('"${r'$'}6"')));
    });

    test('uses coreutils sha256sum (not macOS shasum)', () {
      expect(kLinuxApplyScript, contains('sha256sum'));
      expect(kLinuxApplyScript, isNot(contains('shasum')));
      expect(kLinuxApplyScript, isNot(contains('ditto')));
    });

    test('performs the swap steps in order', () {
      // TOCTOU re-hash of the staged file…
      expect(kLinuxApplyScript, contains(r'sha256sum "$STAGED"'));
      // …bounded wait for the original app's pid…
      expect(kLinuxApplyScript, contains(r'kill -0 "$PID"'));
      // …executable bit before the swap…
      expect(kLinuxApplyScript, contains(r'chmod +x "$STAGED"'));
      // …stale-aside sweep + rename-aside swap + cross-device
      // fallback + rollback…
      expect(kLinuxApplyScript, contains(r'for f in "$TARGET".old-*; do'));
      expect(kLinuxApplyScript,
          contains(r'mv -f "$TARGET" "$ASIDE" || fail "cannot set aside running AppImage: $TARGET"'));
      expect(kLinuxApplyScript, contains(r'cp "$STAGED" "$TARGET"'));
      expect(kLinuxApplyScript, contains(r'rollback failed'));
      // …detached relaunch of the NEW target…
      expect(kLinuxApplyScript, contains(r'nohup "$TARGET"'));
      // …and the success sentinel.
      expect(kLinuxApplyScript, contains(r'log "OK: applied update to $TARGET'));
    });
  });

  group('linuxApplyArgv', () {
    test('order matches the script header comment', () {
      final argv = linuxApplyArgv(
        pid: 42,
        stagedPath: '/staged.AppImage',
        targetPath: '/target.AppImage',
        sentinelPath: '/sentinel.log',
        expectedDigestHex: 'abc',
      );
      expect(argv, <String>['42', '/staged.AppImage', '/target.AppImage',
        '/sentinel.log', 'abc']);
    });

    test('missing digest becomes empty string (legacy skip)', () {
      final argv = linuxApplyArgv(
        pid: 1,
        stagedPath: '/s',
        targetPath: '/t',
        sentinelPath: '/l',
      );
      expect(argv.last, '');
    });
  });

  group('spawnLinuxApply plumbing', () {
    test('writes the script and spawns /bin/sh with script + argv',
        () async {
      final tmp = await Directory.systemTemp.createTemp('octodo_lxapply_');
      addTearDown(() => tmp.delete(recursive: true));

      final scriptFile = File(p.join(tmp.path, 'staging', 'apply.sh'));
      final sentinelFile =
          File(p.join(tmp.path, 'cache', 'octodo_apply_crash.log'));
      final recorded = <List<String>>[];
      await spawnLinuxApply(
        pid: 7,
        stagedFile: File('/staged.AppImage'),
        targetFile: File('/target.AppImage'),
        scriptFile: scriptFile,
        sentinelFile: sentinelFile,
        expectedDigestHex: 'deadbeef',
        starter: (exe, args) async {
          expect(exe, '/bin/sh');
          recorded.add(args);
        },
      );
      expect(recorded, hasLength(1));
      expect(recorded.single.first, scriptFile.path);
      expect(recorded.single.skip(1).toList(), <String>[
        '7',
        '/staged.AppImage',
        '/target.AppImage',
        sentinelFile.path,
        'deadbeef',
      ]);
      expect(scriptFile.readAsStringSync(), kLinuxApplyScript);
      expect(sentinelFile.parent.existsSync(), isTrue);
    });
  });

  // ---------------------------------------------------------------------
  // Behavioural tests: run the real script under /bin/sh with fake
  // AppImages (executable shell scripts). Linux-only.
  // ---------------------------------------------------------------------
  if (!Platform.isLinux) return;

  group('kLinuxApplyScript behaviour (real /bin/sh)', () {
    late Directory tmp;
    late File target;
    late File staged;
    late File sentinel;
    late File sleeper;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('octodo_lxrun_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final dir = tmp.path;

      // The "running app": a live process the script waits on; it
      // exits by itself within a second (simulates the GUI quit).
      sleeper = File(p.join(dir, 'sleeper.out'));
      await sleeper.writeAsString('v1-old\n');

      // The running AppImage (old version): plain bytes; the script
      // never executes the OLD target, only compares/replaces it.
      target = File(p.join(dir, 'Octodo.AppImage'));
      await target.writeAsString('#!/bin/sh\necho old > "\$0".oldmarker\n');

      // The staged payload (new version): when the script relaunches
      // $TARGET after the swap, THIS runs — its marker proves the
      // relaunch executed the swapped-in bytes.
      staged = File(p.join(dir, 'staged.AppImage'));
      await staged.writeAsString(
          '#!/bin/sh\ncd "\$(dirname "\$0")" && echo new > relaunch.marker\n'
          'sleep 5\n');

      sentinel = File(p.join(dir, 'apply_crash.log'));
    });

    Future<int> runScript({required int pid, String? digest}) async {
      final scriptFile = File(p.join(tmp.path, 'apply.sh'));
      var exitCode = -1;
      await spawnLinuxApply(
        pid: pid,
        stagedFile: staged,
        targetFile: target,
        scriptFile: scriptFile,
        sentinelFile: sentinel,
        expectedDigestHex: digest,
        starter: (exe, args) async {
          final r = await Process.run(exe, args);
          exitCode = r.exitCode;
        },
      );
      return exitCode;
    }

    test('swaps, relaunches, sweeps asides; sentinel OK', () async {
      final oldAside =
          File('${target.path}.old-1700000000');
      await oldAside.writeAsString('stale\n');

      final app = await Process.start('sleep', ['1']);
      final digest = await sha256HexOfFile(staged);
      // Captured BEFORE the swap — the script consumes the staged
      // file (mv), so it cannot be read afterwards.
      final stagedBytes = await staged.readAsString();
      final r = await runScript(pid: app.pid, digest: digest);
      expect(r, 0, reason: sentinel.readAsStringSync());

      // Target now holds the staged bytes and is executable.
      expect(await target.readAsString(), stagedBytes);
      expect(target.statSync().modeString().contains('x'), isTrue);
      // Staged file consumed by the swap.
      expect(staged.existsSync(), isFalse);
      // Stale + fresh asides both swept.
      expect(oldAside.existsSync(), isFalse);
      expect(File('${target.path}.old-1').existsSync(), isFalse);
      // Relaunch executed the swapped-in payload.
      final marker = File(p.join(tmp.path, 'relaunch.marker'));
      expect(marker.readAsStringSync(), 'new\n');
      // Sentinel records digest + OK.
      final log = sentinel.readAsStringSync();
      expect(log, contains('digest re-verified'));
      expect(log, contains('OK: applied update'));
    });

    test('digest mismatch refuses and leaves the target untouched',
        () async {
      final before = await target.readAsString();
      final app = await Process.start('sleep', ['1']);
      final r = await runScript(pid: app.pid, digest: '00' * 32);
      expect(r, 1);
      expect(await target.readAsString(), before);
      expect(staged.existsSync(), isTrue);
      expect(sentinel.readAsStringSync(),
          contains('digest changed after download'));
    });

    test('missing staged file fails fast', () async {
      await staged.delete();
      final app = await Process.start('sleep', ['1']);
      final r = await runScript(pid: app.pid, digest: 'x');
      expect(r, 1);
      expect(sentinel.readAsStringSync(),
          contains('staged AppImage missing'));
    });

    test('empty expected digest skips the re-hash (legacy callers)',
        () async {
      final app = await Process.start('sleep', ['1']);
      final r = await runScript(pid: app.pid, digest: '');
      expect(r, 0, reason: sentinel.readAsStringSync());
      expect(await target.readAsString(), contains('relaunch.marker'));
      expect(
          sentinel.readAsStringSync(), isNot(contains('re-verified')));
    });
  });
}
