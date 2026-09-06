// Pins sanitizeAppImageLdLibraryPath — the AppImage LD_LIBRARY_PATH
// containment for spawned shells. Pure string logic (injected env +
// resolved executable), so the suite is host-agnostic.
//
// The real-world failure mode this guards: the AppRun exports
// LD_LIBRARY_PATH="<mount>/usr/lib:<mount>/usr/bin/lib:<inherited>";
// resolveShellSpec spreads it into every tab, and host tools linking
// the system libsystemd (procps' `w` on Debian 13) resolve the
// bundled, older copy and abort with `LIBSYSTEMD_254 not found`.

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/terminal/appimage_spawn_env.dart';

void main() {
  group('sanitizeAppImageLdLibraryPath', () {
    const mount = '/tmp/.mount_octodoFCIEId';
    const exe = '$mount/usr/bin/octodo';

    Map<String, String> envWith({String? ld}) => {
          'APPIMAGE': '/home/u/octodo-v1.2.3-linux-x64.AppImage',
          'LD_LIBRARY_PATH': ?ld,
        };

    test('strips both AppRun entries, keeps the inherited tail', () {
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(
              ld: '$mount/usr/lib:$mount/usr/bin/lib:/opt/custom/lib'),
          resolvedExecutable: exe,
        ),
        '/opt/custom/lib',
      );
    });

    test('empty override when only mount entries remain', () {
      // NOT null: resolveShellSpec spreads the launch env underneath
      // the overlay, so an absent override would let the leaked value
      // win. '' is the drop-seam (adds no loader search dirs).
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(ld: '$mount/usr/lib:$mount/usr/bin/lib'),
          resolvedExecutable: exe,
        ),
        '',
      );
    });

    test('null without APPIMAGE (dev / deb / tarball builds)', () {
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: const {'LD_LIBRARY_PATH': '$mount/usr/lib'},
          resolvedExecutable: exe,
        ),
        isNull,
      );
    });

    test('null with empty APPIMAGE (runtime never exports that)', () {
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: {'APPIMAGE': '', 'LD_LIBRARY_PATH': '$mount/usr/lib'},
          resolvedExecutable: exe,
        ),
        isNull,
      );
    });

    test('null when LD_LIBRARY_PATH is unset or empty', () {
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(),
          resolvedExecutable: exe,
        ),
        isNull,
      );
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(ld: ''),
          resolvedExecutable: exe,
        ),
        isNull,
      );
    });

    test('null when the executable is not under <root>/usr/bin', () {
      // Tarball-style layout: a mount root must never be guessed from
      // an arbitrary executable path.
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(ld: '/opt/octodo/lib'),
          resolvedExecutable: '/opt/octodo/bin/octodo',
        ),
        isNull,
      );
    });

    test('system /usr/bin location is not a mount root', () {
      // lastIndexOf finds index 0 — rejected, so a system-installed
      // binary can never strip entries via an empty root.
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(ld: '/usr/lib/foo'),
          resolvedExecutable: '/usr/bin/octodo',
        ),
        isNull,
      );
    });

    test('--appimage-extract-and-run roots are stripped too', () {
      const root = '/tmp/appimage_extracted_3302820139';
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(ld: '$root/usr/lib:$root/usr/bin/lib'),
          resolvedExecutable: '$root/usr/bin/octodo',
        ),
        '',
      );
    });

    test('lookalike prefixes survive the strip', () {
      // '<mount>-evil/usr/lib' shares the textual prefix but is NOT
      // inside the mount; the guard requires the entry to equal the
      // root or continue with '/'.
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(
              ld: '$mount/usr/lib:$mount/usr/bin/lib:$mount-evil/usr/lib'),
          resolvedExecutable: exe,
        ),
        '$mount-evil/usr/lib',
      );
    });

    test('APPDIR is the authoritative mount root when exported', () {
      // Our AppRun exports APPDIR="${HERE}"; when present it wins
      // over the executable-derived root (it is exactly the prefix
      // the AppRun injects into LD_LIBRARY_PATH).
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: {
            'APPIMAGE': '/home/u/octodo.AppImage',
            'APPDIR': mount,
            'LD_LIBRARY_PATH': '$mount/usr/lib:/keep/lib',
          },
          resolvedExecutable: '/somewhere/else/octodo',
        ),
        '/keep/lib',
      );
    });

    test('nested non-AppImage launch inherits APPDIR → no-op on user paths',
        () {
      // An octodo tarball (usr/bin layout under $HOME) started from
      // inside an AppImage-spawned tab: APPIMAGE/APPDIR leak through
      // from the outer AppImage, but LD_LIBRARY_PATH carries no
      // outer-mount entries (the tab's env was already sanitized), so
      // the user's own entries under the tarball root survive.
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: {
            'APPIMAGE': '/home/u/octodo.AppImage',
            'APPDIR': '/tmp/.mount_outerXXX',
            'LD_LIBRARY_PATH': '/home/u/apps/octodo/lib',
          },
          resolvedExecutable: '/home/u/apps/octodo/usr/bin/octodo',
        ),
        isNull,
      );
    });

    test('empty APPDIR falls back to the executable-derived root', () {
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: {
            'APPIMAGE': '/home/u/octodo.AppImage',
            'APPDIR': '',
            'LD_LIBRARY_PATH': '$mount/usr/lib:/keep/lib',
          },
          resolvedExecutable: exe,
        ),
        '/keep/lib',
      );
    });

    test('non-mount entries pass through verbatim, separators included', () {
      // A trailing empty element in the user's own value must survive
      // the rebuild untouched.
      expect(
        sanitizeAppImageLdLibraryPath(
          environment: envWith(ld: '$mount/usr/lib:/a:'),
          resolvedExecutable: exe,
        ),
        '/a:',
      );
    });
  });
}
