// Regression guard for the fresh-environment channel
// (`octodo/environment`, windows/runner/environment.cpp):
//
// The historical behavior — every spawned shell inheriting the app
// process's launch-time `Platform.environment` — meant an installer
// appending to the user PATH after octodo started was invisible to
// every new tab until the app restarted (the mimo/scoop class of
// reports). `FreshEnvironment.read()` is the seam the workspace uses
// to base each spawn on a fresh registry snapshot instead.
//
// These tests pin the channel contract on every host (the class
// deliberately carries no Platform check):
//   * a map reply is parsed into Map<String, String>
//   * a null reply (native registry failure) resolves to null
//   * a missing plugin (non-Windows runner, `flutter test`) and a
//     PlatformException both resolve to null — never a throw, so a
//     channel hiccup can never block tab creation.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/fresh_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('octodo/environment');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('FreshEnvironment.read', () {
    test('parses a map reply into Map<String, String>', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'get');
        return <Object?, Object?>{
          'Path': r'C:\Windows\system32;C:\Users\Sun\.mimocode\bin',
          'USERNAME': 'Sun',
        };
      });

      final env = await FreshEnvironment.read();

      expect(env, isNotNull);
      expect(env!['USERNAME'], 'Sun');
      // read() canonicalizes the PATH key's spelling against the
      // host's own launch environment (Path on Windows, PATH on
      // POSIX CI), so look the var up case-insensitively.
      final pathValue =
          env.entries.where((e) => e.key.toLowerCase() == 'path').single.value;
      expect(
        pathValue,
        contains(r'C:\Users\Sun\.mimocode\bin'),
        reason: 'the whole point of the channel: a PATH entry added '
            'after app launch must be visible to the next spawn',
      );
    });

    test('null reply (registry failure) resolves to null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      expect(await FreshEnvironment.read(), isNull);
    });

    test('PlatformException resolves to null, never throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'registry-error');
      });

      expect(await FreshEnvironment.read(), isNull);
    });

    test('missing plugin (no handler) resolves to null', () async {
      expect(await FreshEnvironment.read(), isNull);
    });
  });

  group('FreshEnvironment.canonicalize', () {
    test('re-keys fresh vars to the launch-env spelling (case-insensitive '
        'name collision would otherwise duplicate the var)', () {
      final result = FreshEnvironment.canonicalize(
        // MSYS2/WSL-interop launchers spell it PATH; the registry
        // block emits Path. The spread must replace, not duplicate.
        // The launch PATH entry dedupes against the fresh one
        // (case-insensitively), so the merged value is exactly the
        // fresh one — proving the replacement, not the merge.
        {'Path': r'C:\Windows\system32', 'Home': r'C:\Users\Sun'},
        {'PATH': r'c:\windows\SYSTEM32', 'HOME': r'C:\Users\Sun'},
      );

      expect(result.keys, containsAll(<String>['PATH', 'HOME']));
      expect(result.keys.where((k) => k.toLowerCase() == 'path'), hasLength(1),
          reason: 'duplicate differently-cased PATH entries make the '
              'flattened env block ambiguous (first occurrence wins — '
              'the stale launch value)');
      expect(result['PATH'], r'C:\Windows\system32');
    });

    test('keeps the fresh spelling for vars absent from the launch env', () {
      final result = FreshEnvironment.canonicalize(
        {'NewVar': 'installed-after-launch'},
        {'Other': 'x'},
      );

      expect(result['NewVar'], 'installed-after-launch');
    });

    test('merges session-only launch PATH entries ahead of the fresh PATH',
        () {
      final result = FreshEnvironment.canonicalize(
        {'Path': r'C:\Windows\system32;C:\Windows'},
        {
          'PATH': r'C:\venv\Scripts;C:\Windows\system32;C:\session-only',
        },
      );

      // venv and the session-only dir survive, prepended in launch
      // order (venv keeps precedence — an activated venv must still
      // win the `python` lookup); the shared system32 entry appears
      // once, from the registry side.
      expect(
        result['PATH'],
        r'C:\venv\Scripts;C:\session-only;C:\Windows\system32;C:\Windows',
      );
    });
  });

  group('FreshEnvironment.mergePath', () {
    test('no session extras → fresh path returned verbatim', () {
      const fresh = r'A;B';
      const launch = r'A;B';
      expect(
        FreshEnvironment.mergePath(freshPath: fresh, launchPath: launch),
        fresh,
      );
    });

    test('dedupes case-insensitively and ignores trailing separators', () {
      expect(
        FreshEnvironment.mergePath(
          freshPath: r'C:\Tools',
          launchPath: r'c:\tools\;D:\Extra',
        ),
        r'D:\Extra;C:\Tools',
      );
    });

    test('drops empty entries from the launch side', () {
      expect(
        FreshEnvironment.mergePath(
          freshPath: r'A;B',
          launchPath: r'; ;C',
        ),
        r'C;A;B',
      );
    });
  });
}
