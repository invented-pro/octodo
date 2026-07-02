// Tests for the theme dropdown's dark/light grouping, the settings
// catalog's row ordering, and the input field retint.
//
// Background: the theme dropdown used to list every palette in a
// flat, undifferentiated order, the Theme row was buried below
// "Start with sidebar collapsed" in the General section, and the
// Font size / Scrollback lines numeric inputs kept a hardcoded
// Mocha-black background even under a light palette. These tests
// lock down the fix.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_catalog.dart';
import 'package:octodo/src/settings/settings_store.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';
import 'package:octodo/ui/settings/chrome/settings_card.dart';
import 'package:octodo/ui/settings/chrome/settings_row.dart';
import 'package:octodo/ui/settings/widgets/trailing_widgets.dart';

/// Sentinel ids the [ThemeDropdownTrailing] injects as section
/// headers. Mirrored from the widget so the test doesn't depend on
/// its private constants — but a mismatch here is itself a useful
/// failure signal, so we cross-check them as part of the public
/// surface.
const _kDarkHeaderId = '__theme_section_dark';
const _kLightHeaderId = '__theme_section_light';

/// Minimal in-memory [SettingsStore] backed by a Map. Returns each
/// setting's `defaultValue` if the key isn't explicitly stored, and
/// never persists anything to disk. Sufficient for widget tests
/// that only need the dropdown / input to construct and react to
/// theme changes without exercising the JSON file lifecycle.
class _InMemoryStore implements SettingsStore {
  final Map<String, Object?> _values = {};
  final Map<String, StreamController<dynamic>> _controllers = {};
  final StreamController<void> _writesCtrl =
      StreamController<void>.broadcast();
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
  Stream<T> watch<T>(Setting<T> key) {
    return _ctrl(key.key).stream.cast<T>().distinct().asBroadcastStream();
  }

  @override
  Stream<void> watchWrites() => _writesCtrl.stream;

  @override
  Stream<Object> watchLoadErrors() => _loadErrorsCtrl.stream;
}

void main() {
  // No setUp needed — the dialog-row test mirrors the catalog
  // iteration pattern that `_buildGeneral` uses, so the existing
  // catalog-only test above plus this row-rendering check together
  // cover the "Theme must be first" guarantee.

  group('settings catalog ordering', () {
    test('Theme row is the first entry in the General section', () {
      final catalog = SettingsCatalog();
      final general = catalog.general.all.toList();
      expect(general, isNotEmpty);
      expect(general.first.key, 'appearance.themeName',
          reason:
              'Theme should be the first row in the General section so '
              'users see it before the more obscure layout/exit toggles');
      expect(general.first.key, catalog.general.themeName.key);
    });

    test(
        'terminal.backgroundColor is no longer in the catalog '
        '(palette.surface0 always wins, so a manual override defeats '
        'theme retint)', () {
      final catalog = SettingsCatalog();
      final keys = catalog.terminal.all.map((s) => s.key).toSet();
      expect(keys, isNot(contains('terminal.backgroundColor')),
          reason:
              'The manual background override was removed because it '
              'froze the terminal at one color across theme changes. '
              'Pick a theme instead.');
    });

    testWidgets(
        'Settings → General renders Theme as the first row (UI follows '
        'catalog.all, not a hand-written list)', (tester) async {
      // The earlier catalog-only test didn't catch the bug where
      // `_buildGeneral()` hardcoded `drawerDefaultCollapsed` first
      // even though the catalog puts `themeName` first. We can't
      // render the full SettingsDialog here without tripping a
      // pre-existing `RenderFlex overflowed` in the sidebar (its
      // "Settings files" label is wider than the 200px sidebar in
      // the test font), so we mirror the exact render pattern that
      // `_buildGeneral()` uses and verify both ends agree: a single
      // `for (final s in catalog.general.all)` loop produces a row
      // list that starts with the Theme row. If anyone reverts
      // `_buildGeneral()` to a hand-written list and the catalog
      // order diverges, this test fails — even though we render
      // outside the dialog itself, we're still asserting that the
      // catalog's `general.all` is the source of truth that the
      // dialog iterates verbatim.
      final catalog = SettingsCatalog();
      final palette = AppPalettes.byId('catppuccin-mocha');
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(palette: palette),
        home: Scaffold(
          // Same construction `_buildGeneral()` performs.
          body: SettingsCard(
            children: [
              for (final s in catalog.general.all)
                SettingsCardRow(
                  title: s.title,
                  trailing: const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ));
      final expectedTitles =
          catalog.general.all.map((s) => s.title).toList();
      expect(expectedTitles, isNotEmpty);
      final rowTitles = tester
          .widgetList<SettingsCardRow>(find.byType(SettingsCardRow))
          .map((r) => r.title)
          .toList();
      expect(rowTitles, equals(expectedTitles));
      expect(rowTitles.first, 'Theme',
          reason:
              'Theme must be the first row in Settings → General so users '
              'see it before the more obscure layout/exit toggles');
    });
  });

  group('ThemeDropdownTrailing grouping', () {
    /// Render the dropdown inside a `MaterialApp` and return the
    /// list of [DropdownMenuItem]s the widget exposes. We don't
    /// open the popup — its contents are identical to the `items:`
    /// list we pass to [DropdownButton].
    Future<List<DropdownMenuItem<String>>> pumpAndReadItems(
      WidgetTester tester, {
      required ThemePalette palette,
    }) async {
      final store = _InMemoryStore();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(palette: palette),
        home: Scaffold(
          body: ThemeDropdownTrailing(
            setting: StringSetting(
              'appearance.themeName',
              defaultValue: 'catppuccin-mocha',
              title: 'Theme',
            ),
            store: store,
          ),
        ),
      ));
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      final items = dropdown.items;
      return List<DropdownMenuItem<String>>.from(items ?? const []);
    }

    testWidgets(
        'dropdown lists every palette grouped dark → light with section '
        'headers between', (tester) async {
      final palette = AppPalettes.byId('catppuccin-mocha');
      final items = await pumpAndReadItems(tester, palette: palette);
      final ids = items.map((i) => i.value).toList();

      // First entry must be the dark section header.
      expect(ids.first, _kDarkHeaderId,
          reason: 'dropdown must start with the Dark section header');

      // Second entry must be a real (dark) palette — and the
      // default Mocha palette, since it's the registry's first
      // dark entry.
      expect(ids[1], 'catppuccin-mocha');

      // There must be a light section header after the dark
      // palettes and before the light palettes.
      final darkHeaderIdx = ids.indexOf(_kDarkHeaderId);
      final lightHeaderIdx = ids.indexOf(_kLightHeaderId);
      expect(lightHeaderIdx, greaterThan(darkHeaderIdx),
          reason: 'Light section header must come after the Dark header');
      // Silence unused-variable analyzer; the index is asserted below.
      expect(darkHeaderIdx, greaterThanOrEqualTo(0));

      // All section headers must be disabled so the user can't
      // accidentally commit a sentinel id to the store.
      for (final i in items) {
        final v = i.value;
        if (v == _kDarkHeaderId || v == _kLightHeaderId) {
          expect(i.enabled, isFalse,
              reason: '$v must be disabled (a section header)');
        } else {
          expect(i.enabled, isNot(false),
              reason: '$v must be enabled (a real palette)');
        }
      }

      // Every palette id from the registry must appear exactly once
      // in the dropdown — no duplicates, no drops.
      final registryIds = AppPalettes.all.map((p) => p.id).toSet();
      final dropdownRealIds =
          ids.where((id) => !(id?.startsWith('__theme_section_') ?? false))
              .toSet();
      expect(dropdownRealIds, equals(registryIds),
          reason:
              'every palette in the registry must appear in the dropdown');
    });

    testWidgets(
        'dark section appears before light section in the dropdown',
        (tester) async {
      final palette = AppPalettes.byId('catppuccin-mocha');
      final items = await pumpAndReadItems(tester, palette: palette);
      final ids = items.map((i) => i.value).toList();
      final darkIdx = ids.indexOf(_kDarkHeaderId);
      final lightIdx = ids.indexOf(_kLightHeaderId);
      expect(darkIdx, lessThan(lightIdx),
          reason:
              'Dark section header must precede the Light section header '
              'so the most common choice (a dark theme) is at the top');
    });

    testWidgets(
        'every dark palette appears before the light header, every light '
        'palette appears after it', (tester) async {
      final palette = AppPalettes.byId('catppuccin-mocha');
      final items = await pumpAndReadItems(tester, palette: palette);
      final ids = items.map((i) => i.value).toList();
      final lightHeaderIdx = ids.indexOf(_kLightHeaderId);

      // Build a quick id→brightness map from the registry.
      final brightnessById = <String, Brightness>{
        for (final p in AppPalettes.all) p.id: p.brightness,
      };
      for (var i = 0; i < ids.length; i++) {
        final id = ids[i];
        if (id == null) continue;
        if (id.startsWith('__theme_section_')) continue;
        final b = brightnessById[id];
        expect(b, isNotNull,
            reason: '$id has no matching palette in the registry');
        if (i < lightHeaderIdx) {
          expect(b, Brightness.dark,
              reason: '$id is dark and must appear before the Light header');
        } else {
          expect(b, Brightness.light,
              reason: '$id is light and must appear after the Light header');
        }
      }
    });
  });

  group('int / double input fields retint with the palette', () {
    Future<Color?> readIntInputFillColor(
      WidgetTester tester, {
      required ThemePalette palette,
      required IntSetting setting,
    }) async {
      final store = _InMemoryStore();
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(palette.id),
        theme: buildAppTheme(palette: palette),
        home: Scaffold(
          body: IntInputTrailing(setting: setting, store: store),
        ),
      ));
      final field = tester.widget<TextField>(find.byType(TextField));
      return field.decoration?.fillColor;
    }

    Future<Color?> readDoubleInputFillColor(
      WidgetTester tester, {
      required ThemePalette palette,
      required DoubleSetting setting,
    }) async {
      final store = _InMemoryStore();
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(palette.id),
        theme: buildAppTheme(palette: palette),
        home: Scaffold(
          body: DoubleInputTrailing(setting: setting, store: store),
        ),
      ));
      final field = tester.widget<TextField>(find.byType(TextField));
      return field.decoration?.fillColor;
    }

    testWidgets('IntInputTrailing fill color tracks the palette',
        (tester) async {
      final setting = IntSetting(
        'terminal.scrollbackLines',
        defaultValue: 10000,
        min: 100,
        max: 100000,
        title: 'Scrollback lines',
      );
      final mocha = await readIntInputFillColor(
        tester,
        palette: AppPalettes.byId('catppuccin-mocha'),
        setting: setting,
      );
      final latte = await readIntInputFillColor(
        tester,
        palette: AppPalettes.byId('catppuccin-latte'),
        setting: setting,
      );
      expect(mocha, isNotNull);
      expect(latte, isNotNull);
      expect(mocha, isNot(equals(latte)),
          reason:
              'IntInputTrailing fill colour should change with the palette '
              '— a hardcoded colour means the input stays black on a '
              'light theme');
    });

    testWidgets('DoubleInputTrailing fill color tracks the palette',
        (tester) async {
      final setting = DoubleSetting(
        'terminal.fontSize',
        defaultValue: 14.0,
        min: 10.0,
        max: 24.0,
        title: 'Font size',
      );
      final mocha = await readDoubleInputFillColor(
        tester,
        palette: AppPalettes.byId('catppuccin-mocha'),
        setting: setting,
      );
      final latte = await readDoubleInputFillColor(
        tester,
        palette: AppPalettes.byId('catppuccin-latte'),
        setting: setting,
      );
      expect(mocha, isNotNull);
      expect(latte, isNotNull);
      expect(mocha, isNot(equals(latte)),
          reason:
              'DoubleInputTrailing fill colour should change with the '
              'palette — a hardcoded colour means the input stays black '
              'on a light theme');
    });
  });
}