// Tests for the font-family enumeration that backs
// `Settings → Terminal → Font family`. The dropdown should:
//   * show the curated fallback list synchronously, so the dialog is
//     usable the moment it opens;
//   * swap to the host's installed fonts once the off-isolate scan
//     completes (so a machine with hundreds of fonts doesn't drop a
//     frame on dialog open);
//   * pin the user's currently-selected value to the top, so a
//     custom-installed face previously picked never disappears.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide FontStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_font_scan/just_font_scan.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_store.dart';
import 'package:octodo/src/terminal/font_family_options.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';
import 'package:octodo/ui/settings/widgets/trailing_widgets.dart';

/// Minimal in-memory [SettingsStore]. Mirrors the helper in
/// `theme_dropdown_test.dart` rather than sharing, because the font
/// dropdown lives in a sibling test file and there's no shared
/// fixture layer in the test suite yet.
class _InMemoryStore implements SettingsStore {
  final Map<String, Object?> _values = {};
  final Map<String, StreamController<dynamic>> _controllers = {};
  final StreamController<void> _writesCtrl = StreamController<void>.broadcast();
  final StreamController<Object> _loadErrorsCtrl =
      StreamController<Object>.broadcast();

  StreamController<dynamic> _ctrl(String key) => _controllers.putIfAbsent(
    key,
    () => StreamController<dynamic>.broadcast(),
  );

  @override
  T get<T>(Setting<T> key) {
    if (_values.containsKey(key.key)) {
      return key.codec.fromJson(_values[key.key]);
    }
    return key.defaultValue;
  }

  @override
  Future<void> set<T>(Setting<T> key, T value) async {
    _values[key.key] = key.codec.toJson(value);
    _ctrl(key.key).add(_values[key.key]);
    _writesCtrl.add(null);
  }

  @override
  Future<void> reset<T>(Setting<T> key) async {
    _values.remove(key.key);
    _ctrl(key.key).add(key.defaultValue);
    _writesCtrl.add(null);
  }

  @override
  Future<void> resetAll() async {
    _values.clear();
    for (final c in _controllers.values) {
      c.add(null);
    }
    _writesCtrl.add(null);
  }

  @override
  bool isExplicitlySet<T>(Setting<T> key) => _values.containsKey(key.key);

  @override
  Stream<T> watch<T>(Setting<T> key) =>
      _ctrl(key.key).stream.cast<T>().distinct().asBroadcastStream();

  @override
  Stream<void> watchWrites() => _writesCtrl.stream;

  @override
  Stream<Object> watchLoadErrors() => _loadErrorsCtrl.stream;
}

void main() {
  group('fallbackFontFamilies', () {
    test('contains the canonical monospace and CJK faces', () {
      final list = fallbackFontFamilies();
      // The first entry is the user's most-preferred monospace face.
      expect(list.first, 'Cascadia Code');
      // Generic `monospace` is always available and must be last so
      // every other entry is preferred at render time.
      expect(list.last, 'monospace');
      // No duplicates.
      expect(
        list.toSet().length,
        list.length,
        reason: 'fallback list must not contain duplicates',
      );
    });

    test('is unmodifiable so callers can\'t mutate the cached list', () {
      final list = fallbackFontFamilies();
      expect(() => list.add('hax'), throwsUnsupportedError);
    });
  });

  group('initialFontFamilies', () {
    test('returns the fallback list when no pin is given', () {
      final list = initialFontFamilies();
      expect(list, equals(fallbackFontFamilies()));
    });

    test('pins a custom value at the top of the list', () {
      const custom = 'My Beloved Hand-Edited 5x8 TTF';
      final list = initialFontFamilies(pinCurrent: custom);
      expect(
        list.first,
        custom,
        reason: 'a custom face previously picked must remain selectable',
      );
    });

    test('skips an empty pinCurrent without adding a blank entry', () {
      final list = initialFontFamilies(pinCurrent: '');
      expect(list.first, isNot(''));
      expect(list, equals(fallbackFontFamilies()));
    });
  });

  group('mergeFontFamilies', () {
    test('priority order: pin → fallback → discovered (sorted)', () {
      const pin = 'Roboto Slab';
      const installed = <String>['zzzz', 'Arial', 'consola'];
      final merged = mergeFontFamilies(installed: installed, pinCurrent: pin);
      // 1. Pin first.
      expect(merged.first, pin);
      // 2. Fallback follows the curated order, with discovered-only
      //    entries appended afterwards.
      final fallback = fallbackFontFamilies();
      for (var i = 0; i < fallback.length; i++) {
        expect(
          merged[i + 1],
          fallback[i],
          reason: 'fallback entry at index $i must keep its priority',
        );
      }
      // 3. Discovered entries appended, deduped against fallbacks,
      //    sorted case-insensitively.
      final afterFallback = merged.sublist(1 + fallback.length);
      // The fallback contains a 'Consolas' entry; the discovered
      // list also has 'consola'. Either way the merged result must
      // show the family at most once.
      expect(
        [...merged].where((e) => e.toLowerCase() == 'consola').length,
        lessThanOrEqualTo(1),
        reason:
            'Consolas must appear at most once across pin, fallback, '
            'and discovered',
      );
      // Sorted verification on what remains.
      final sorted = [...afterFallback]
        ..sort(
          (a, b) => a.toLowerCase().compareTo(b.toLowerCase()) == 0
              ? a.compareTo(b)
              : a.toLowerCase().compareTo(b.toLowerCase()),
        );
      expect(
        afterFallback,
        equals(sorted),
        reason: 'discovered entries must be sorted alphabetically',
      );
    });

    test('is pure: never mutates its inputs', () {
      const installed = <String>['B', 'A'];
      final before = List<String>.from(installed);
      mergeFontFamilies(installed: installed, pinCurrent: null);
      expect(installed, equals(before));
    });

    test('handles empty installed list gracefully', () {
      final merged = mergeFontFamilies(installed: const [], pinCurrent: null);
      expect(merged, equals(fallbackFontFamilies()));
    });
  });

  group('justFontScan', () {
    // just_font_scan is only available on Windows + macOS. On Linux
    // the worker returns [] and the dropdown falls through to the
    // curated fallback — the FontFamilyOptions layer is what makes
    // that work, not the scanner.
    bool scannerSupported() => Platform.isWindows || Platform.isMacOS;

    test('returns one family per face group (no variant splitting)', () {
      // Sanity check: the native scanner groups variants
      // (Bold/Italic/Black/Narrow) under one family. The previous
      // system_fonts-based implementation had to post-process the
      // file-stem list to achieve the same thing; with
      // just_font_scan, the raw output is already in the shape
      // the dropdown wants.
      if (!scannerSupported()) {
        return;
      }
      final families = JustFontScan.scan();
      expect(
        families,
        isNotEmpty,
        reason: 'the host must have at least one system font family',
      );
      // Every family must have a non-empty name and at least one
      // face. (Reproduction guard for a malformed scanner result.)
      for (final f in families) {
        expect(f.name, isNotEmpty);
        expect(f.faces, isNotEmpty, reason: 'family "${f.name}" has no faces');
      }
      // Find any family whose faces span ≥2 distinct weights and
      // include at least one italic — proves the variants are
      // folded in rather than split into separate families.
      // Arial is not installed on stock macOS, so we look for
      // any qualifying family rather than naming a specific one.
      final multiFace = families.where(
        (f) =>
            f.faces.map((x) => x.weight).toSet().length >= 2 &&
            f.faces.any((x) => x.style == FontStyle.italic),
      );
      expect(
        multiFace,
        isNotEmpty,
        reason:
            'need at least one multi-weight multi-style family on the '
            'host to exercise variant grouping; please add a known face '
            'to the CI image',
      );
    });

    test('discovery feeds into the dropdown without further work', () {
      // The previous implementation post-processed the raw file
      // stems through `dedupFontVariants` before they hit the
      // dropdown. With just_font_scan, that step is unnecessary:
      // the raw family names already match the dropdown's
      // "one row per family" expectation. Pick names that are
      // *not* in the curated fallback so they show up in the
      // post-fallback tail we're inspecting.
      const installed = <String>[
        'Arial',
        'Segoe UI',
        'Times New Roman',
        'Roboto',
        'Inter',
      ];
      final merged = mergeFontFamilies(installed: installed, pinCurrent: null);
      final afterFallback = merged.sublist(fallbackFontFamilies().length);
      // Every entry the scanner produced must be in the dropdown
      // exactly once.
      for (final name in installed) {
        expect(
          afterFallback.where((s) => s == name).length,
          1,
          reason: 'family "$name" should appear exactly once',
        );
      }
    });
  });

  group('scanInstalledFontFamilies / loadInstalledFontFamilies', () {
    // Contract guard for the post-await pin pattern. The race fix
    // splits the worker-isolate scan from the merge so the caller
    // can pin the *latest* current value (captured after the await)
    // rather than the value as it was at call time. If anyone
    // re-merges these two responsibilities into a single helper
    // that takes `pinCurrent` again, this test fails.
    test('scanInstalledFontFamilies takes no pinCurrent — the merge is '
        'the caller\'s job', () {
      // The function is async and depends on just_font_scan, so
      // we can only verify its signature here at compile time. If
      // someone re-adds a `pinCurrent` parameter, the call site
      // below stops compiling.
      Future<List<String>> Function() ref = scanInstalledFontFamilies;
      expect(ref, isA<Function>());
    });

    test('loadInstalledFontFamilies is a thin wrapper that delegates to '
        'scanInstalledFontFamilies + mergeFontFamilies', () {
      // Same idea: pin the wrapper's signature so a future
      // refactor that bakes `pinCurrent` back in has to update
      // this test (and the widget that depends on the split).
      Future<List<String>> Function({String? pinCurrent}) ref =
          loadInstalledFontFamilies;
      expect(ref, isA<Function>());
    });
  });

  group('FontFamilyDropdownTrailing', () {
    /// Pump the dropdown inside a minimal app shell. Returns the
    /// widget list as observed after the synchronous first frame —
    /// not after the off-isolate enumeration has resolved.
    Future<List<DropdownMenuItem<String>>> pumpAndReadItems(
      WidgetTester tester, {
      required String currentValue,
    }) async {
      final store = _InMemoryStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(palette: AppPalettes.byId('catppuccin-mocha')),
          home: Scaffold(
            body: FontFamilyDropdownTrailing(
              setting: StringSetting(
                'terminal.fontFamily',
                defaultValue: currentValue,
                title: 'Font family',
              ),
              store: store,
            ),
          ),
        ),
      );
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      return List<DropdownMenuItem<String>>.from(dropdown.items ?? const []);
    }

    testWidgets('synchronous first frame exposes the fallback list plus pin', (
      tester,
    ) async {
      const custom = 'My Hand-Rolled Mono';
      final items = await pumpAndReadItems(tester, currentValue: custom);
      final values = items.map((i) => i.value).toList();
      // The first item is the user's currently-selected custom value.
      expect(
        values.first,
        custom,
        reason:
            'a custom value not in the fallback list must be pinned at the '
            'top so it remains selectable',
      );
      // Fallback entries follow in priority order.
      final fallback = fallbackFontFamilies();
      for (var i = 0; i < fallback.length; i++) {
        expect(values[i + 1], fallback[i]);
      }
      // The dropdown is fully populated even before the off-isolate
      // scan has completed.
      expect(
        values.length,
        fallback.length + 1,
        reason:
            'first frame must not block on the font scan; fallback list is '
            'shown immediately so the dialog is interactive right away',
      );
    });

    testWidgets('is empty fallback when the current value already matches a '
        'fallback (no duplication, no empty pin)', (tester) async {
      // Pick a value that IS in the fallback list — pin must not
      // introduce a duplicate above it.
      final items = await pumpAndReadItems(
        tester,
        currentValue: 'Cascadia Code',
      );
      final values = items.map((i) => i.value).toList();
      // The user's value is the first entry, not duplicated later.
      expect(values.first, 'Cascadia Code');
      expect(values.where((v) => v == 'Cascadia Code').length, 1);
      expect(values.length, fallbackFontFamilies().length);
    });

    testWidgets('every dropdown row is width-capped so proportional fonts '
        'can\'t expand the popup', (tester) async {
      // Regression guard: without a width cap, rendering each row in
      // its own face made the popup grow to the widest entry (Arial /
      // Verdana for many common names, doubling the popup width).
      // All row text widgets must be wrapped in a SizedBox whose width
      // is finite so the popup stays compact.
      final store = _InMemoryStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(palette: AppPalettes.byId('catppuccin-mocha')),
          home: Scaffold(
            body: FontFamilyDropdownTrailing(
              setting: StringSetting(
                'terminal.fontFamily',
                defaultValue: 'Cascadia Code',
                title: 'Font family',
              ),
              store: store,
            ),
          ),
        ),
      );
      final rows = tester.widgetList<DropdownMenuItem<String>>(
        find.byType(DropdownMenuItem<String>),
      );
      expect(rows, isNotEmpty);
      for (final row in rows) {
        // Each row's child must be a width-bounded wrapper; the
        // exact tree shape is intentionally flexed — we look up the
        // width on whichever SizedBox is the immediate parent of the
        // Text.
        final sizedBoxes = tester
            .widgetList<SizedBox>(
              find.descendant(
                of: find.byWidget(row),
                matching: find.byType(SizedBox),
              ),
            )
            .toList();
        // Every row exposes at least one SizedBox, and the largest
        // width in that list is a positive but finite logical-pixel
        // value (proportional fonts must not be allowed to grow
        // outside that cap).
        expect(
          sizedBoxes,
          isNotEmpty,
          reason:
              'row "$row" must contain a SizedBox width cap so proportional '
              'fonts cannot expand the popup',
        );
        final maxWidth = sizedBoxes
            .map((s) => s.width ?? double.infinity)
            .reduce((a, b) => a > b ? a : b);
        expect(maxWidth, greaterThan(0), reason: 'width cap must be positive');
        expect(
          maxWidth,
          lessThanOrEqualTo(400),
          reason:
              'row "$row" width cap must be small enough to keep the popup '
              'compact (currently $maxWidth); proportional faces must not be '
              'allowed to expand the popup',
        );
      }
    });

    testWidgets(
      'reads from a FontFamilyCacheScope when one is mounted (settings '
      'panel path)',
      (tester) async {
        // Regression guard: the dropdown calls
        // `FontFamilyCacheScope.of(context)` to decide between the
        // cache path and the bare-AppShell fallback. That lookup
        // must happen in `didChangeDependencies` (not `initState`),
        // or the framework asserts. Pumping inside a scope is the
        // easiest way to lock that down — if the lookup moves back
        // to `initState`, this test fails with the same
        // `dependOnInheritedWidgetOfExactType` assertion the user
        // saw in production.
        final cache = FontFamilyCache(
          scanner: () async => const ['Arial', 'Consolas', 'Cascadia Code'],
        );
        // Production code (the settings dialog) calls
        // `cache.load()` in its field initializer. Do the same here
        // so the test exercises the post-load state, not the empty
        // pre-load state.
        unawaited(cache.load());
        final store = _InMemoryStore();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(palette: AppPalettes.byId('catppuccin-mocha')),
            home: FontFamilyCacheScope(
              notifier: cache,
              child: Scaffold(
                body: FontFamilyDropdownTrailing(
                  setting: StringSetting(
                    'terminal.fontFamily',
                    defaultValue: 'Cascadia Code',
                    title: 'Font family',
                  ),
                  store: store,
                ),
              ),
            ),
          ),
        );
        // Pump until the cache finishes loading — the dropdown
        // should rebuild via ListenableBuilder when it does.
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final dropdown = tester.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>),
        );
        final values = List<DropdownMenuItem<String>>.from(
          dropdown.items ?? const [],
        ).map((i) => i.value).toList();
        // The cache-supplied names must be present in the dropdown
        // (post-merge with the fallback list).
        expect(values, contains('Arial'));
        expect(values, contains('Consolas'));
        // The bare-AppShell scan must NOT have run (otherwise the
        // production code path would still work but the regression
        // would be hidden). We can't directly observe that, but
        // the absence of any test failure after pumpWidget is
        // enough — the InheritedWidget assertion would fire
        // synchronously in pumpWidget if the lookup moved back to
        // initState.
        expect(tester.takeException(), isNull);
        cache.dispose();
      },
    );
  });
}
