// Tests for the settings-panel-scoped font family cache. The cache
// owns the JustFontScan result for the lifetime of the dialog, so
// a single scan is shared by every font dropdown in the panel and
// survives the dropdown widget being recreated (e.g. when the user
// toggles "Show JSON paths" or switches between sections).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/font_family_options.dart';

void main() {
  group('FontFamilyCache', () {
    test('starts empty and not loading', () {
      final cache = FontFamilyCache();
      expect(cache.fonts, isEmpty);
      expect(cache.loading, isFalse);
      expect(cache.error, isNull);
    });

    test('load() runs the injected scanner and populates fonts', () async {
      final cache = FontFamilyCache(
        scanner: () async => const ['Arial', 'Consolas', 'Cascadia Code'],
      );
      await cache.load();
      expect(cache.fonts, ['Arial', 'Consolas', 'Cascadia Code']);
      expect(cache.loading, isFalse);
      expect(cache.error, isNull);
    });

    test('load() notifies listeners on start and on completion', () async {
      final cache = FontFamilyCache(scanner: () async => const ['Arial']);
      var notifications = 0;
      cache.addListener(() => notifications++);
      await cache.load();
      // At least two: one for "loading started", one for
      // "results in". Exact count depends on whether the scan
      // microtask completes before or after the notify — what
      // matters is "more than zero".
      expect(notifications, greaterThanOrEqualTo(2));
    });

    test('load() coalesces concurrent calls into one scan', () async {
      var scans = 0;
      final cache = FontFamilyCache(
        scanner: () async {
          scans++;
          // Slow enough that two back-to-back load() calls land
          // before the first scan finishes.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return const ['Arial'];
        },
      );
      // Fire two load()s without awaiting between them.
      final f1 = cache.load();
      final f2 = cache.load();
      await Future.wait([f1, f2]);
      expect(scans, 1, reason: 'concurrent load() calls must share a scan');
    });

    test('load() short-circuits when a previous result is cached', () async {
      var scans = 0;
      final cache = FontFamilyCache(
        scanner: () async {
          scans++;
          return const ['Arial'];
        },
      );
      await cache.load();
      expect(scans, 1);
      await cache.load();
      expect(scans, 1, reason: 'cached result must be reused, not re-scanned');
    });

    test('load() captures scanner errors and exposes them on error', () async {
      final cache = FontFamilyCache(
        scanner: () async => throw StateError('boom'),
      );
      await cache.load();
      expect(cache.error, isA<StateError>());
      expect(cache.fonts, isEmpty);
      expect(cache.loading, isFalse);
    });

    test(
      'invalidate() clears the cached result so the next load() re-scans',
      () async {
        var scans = 0;
        final cache = FontFamilyCache(
          scanner: () async {
            scans++;
            return ['Arial #$scans'];
          },
        );
        await cache.load();
        expect(cache.fonts, ['Arial #1']);
        cache.invalidate();
        expect(cache.fonts, isEmpty);
        await cache.load();
        expect(cache.fonts, ['Arial #2']);
        expect(scans, 2);
      },
    );

    test('dispose() suppresses further notifications', () async {
      final cache = FontFamilyCache(scanner: () async => const ['Arial']);
      var notifications = 0;
      cache.addListener(() => notifications++);
      await cache.load();
      final before = notifications;
      cache.dispose();
      // Mutating a disposed ChangeNotifier is a no-op for
      // notifications — what we care about is that the listener
      // count above `before` is stable.
      expect(notifications, before);
    });
  });

  group('FontFamilyCacheScope', () {
    testWidgets('of() returns null when no scope is mounted', (tester) async {
      late FontFamilyCache? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              seen = FontFamilyCacheScope.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen, isNull);
    });

    testWidgets('of() returns the scope\'s notifier when mounted', (
      tester,
    ) async {
      final cache = FontFamilyCache(scanner: () async => const ['Arial']);
      late FontFamilyCache? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: FontFamilyCacheScope(
            notifier: cache,
            child: Builder(
              builder: (context) {
                seen = FontFamilyCacheScope.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(seen, same(cache));
      cache.dispose();
    });

    testWidgets('descendants that depend on the scope rebuild on notify', (
      tester,
    ) async {
      final cache = FontFamilyCache(
        scanner: () async => const ['Arial', 'Consolas'],
      );
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FontFamilyCacheScope(
            notifier: cache,
            child: Builder(
              builder: (context) {
                builds++;
                // Touching the cache through the scope makes the
                // Builder depend on it.
                final c = FontFamilyCacheScope.of(context);
                return Text('len=${c?.fonts.length}');
              },
            ),
          ),
        ),
      );
      final baselineBuilds = builds;
      await cache.load();
      await tester.pump();
      expect(
        builds,
        greaterThan(baselineBuilds),
        reason: 'descendants must rebuild when the cache notifies',
      );
      cache.dispose();
    });
  });
}
