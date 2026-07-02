// Smoke tests for the settings dialog's "chrome" widgets — the
// [SettingsCard], [SettingsCardRow], and [ConfigurationReviewChip]
// that paint the section detail pane.
//
// These widgets used to hardcode Catppuccin Mocha hex values, so
// switching the active palette to anything else (Solarized Light,
// Catppuccin Latte, Nord, …) left the settings pane visibly
// mismatched against the rest of the chrome. The fix is to thread
// [context.palette] through every paint decision; these tests guard
// the regression by rendering each widget under two contrasting
// palettes and asserting the painted colors actually differ.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';
import 'package:octodo/ui/settings/chrome/configuration_review_chip.dart';
import 'package:octodo/ui/settings/chrome/settings_card.dart';
import 'package:octodo/ui/settings/chrome/settings_row.dart';

/// Render [body] under [palette]'s [ThemeData] and return the
/// `BoxDecoration.color` of the first Container painted inside
/// the body.
///
/// Why the `Key`s: a bare `pumpWidget` in the same `testWidgets`
/// body updates the existing MaterialApp element in place, and
/// without a `Key` change further down the tree some widgets cache
/// their inherited theme and short-circuit the rebuild. The
/// `MaterialApp` key changes per palette so the framework
/// disposes + recreates the whole subtree, and the body's
/// `KeyedSubtree` keeps the descendant `find` finder stable.
Future<Color?> pumpAndReadFirstContainerColor(
  WidgetTester tester, {
  required String paletteId,
  required ValueKey<String> childKey,
  required Widget body,
}) async {
  final palette = AppPalettes.byId(paletteId);
  await tester.pumpWidget(MaterialApp(
    key: ValueKey(paletteId),
    theme: buildAppTheme(palette: palette),
    home: Scaffold(
      body: KeyedSubtree(key: childKey, child: body),
    ),
  ));
  final container = tester.widget<Container>(find.descendant(
    of: find.byKey(childKey),
    matching: find.byType(Container),
  ).first);
  return (container.decoration as BoxDecoration).color;
}

Future<Color?> pumpAndReadFirstTextColor(
  WidgetTester tester, {
  required String paletteId,
  required ValueKey<String> childKey,
  required Widget body,
}) async {
  final palette = AppPalettes.byId(paletteId);
  await tester.pumpWidget(MaterialApp(
    key: ValueKey(paletteId),
    theme: buildAppTheme(palette: palette),
    home: Scaffold(
      body: KeyedSubtree(key: childKey, child: body),
    ),
  ));
  final text = tester.widget<Text>(find.descendant(
    of: find.byKey(childKey),
    matching: find.byType(Text),
  ).first);
  return text.style?.color;
}

/// Walk every nested Container under [childKey] and return the
/// first non-null `BoxDecoration.color`. Used by tests that want
/// to assert a specific accent stripe or pill inside the chrome
/// without depending on widget structure.
Future<Color?> pumpAndReadFirstAccentColor(
  WidgetTester tester, {
  required String paletteId,
  required ValueKey<String> childKey,
  required Widget body,
}) async {
  final palette = AppPalettes.byId(paletteId);
  await tester.pumpWidget(MaterialApp(
    key: ValueKey(paletteId),
    theme: buildAppTheme(palette: palette),
    home: Scaffold(
      body: KeyedSubtree(key: childKey, child: body),
    ),
  ));
  for (final element in find
      .descendant(of: find.byKey(childKey), matching: find.byType(Container))
      .evaluate()) {
    final w = element.widget;
    if (w is Container && w.decoration is BoxDecoration) {
      final color = (w.decoration as BoxDecoration).color;
      if (color != null) return color;
    }
  }
  return null;
}

void main() {
  group('settings chrome widgets retint with the palette', () {
    testWidgets('SettingsCard background tracks the palette',
        (tester) async {
      const key = ValueKey<String>('card');
      final mocha = await pumpAndReadFirstContainerColor(tester,
          paletteId: 'catppuccin-mocha',
          childKey: key,
          body: const SettingsCard(children: []));
      final latte = await pumpAndReadFirstContainerColor(tester,
          paletteId: 'catppuccin-latte',
          childKey: key,
          body: const SettingsCard(children: []));
      expect(mocha, isNotNull);
      expect(latte, isNotNull);
      expect(mocha, isNot(equals(latte)),
          reason:
              'SettingsCard background should change with the palette — '
              'a hardcoded colour means the chrome ignores theme switches');
    });

    testWidgets('SettingsCardRow title text tracks the palette',
        (tester) async {
      const key = ValueKey<String>('row');
      final mocha = await pumpAndReadFirstTextColor(
        tester,
        paletteId: 'catppuccin-mocha',
        childKey: key,
        body: const SettingsCardRow(
          title: 'hello',
          trailing: SizedBox.shrink(),
        ),
      );
      final latte = await pumpAndReadFirstTextColor(
        tester,
        paletteId: 'catppuccin-latte',
        childKey: key,
        body: const SettingsCardRow(
          title: 'hello',
          trailing: SizedBox.shrink(),
        ),
      );
      expect(mocha, isNotNull);
      expect(latte, isNotNull);
      expect(mocha, isNot(equals(latte)),
          reason:
              'SettingsCardRow title colour should track the palette — '
              'a hardcoded colour means the chrome ignores theme switches');
    });

    testWidgets(
        'ConfigurationReviewChip background tracks the palette',
        (tester) async {
      const key = ValueKey<String>('chip');
      final mocha = await pumpAndReadFirstContainerColor(
        tester,
        paletteId: 'catppuccin-mocha',
        childKey: key,
        body: const ConfigurationReviewChip(jsonKey: 'k'),
      );
      final latte = await pumpAndReadFirstContainerColor(
        tester,
        paletteId: 'catppuccin-latte',
        childKey: key,
        body: const ConfigurationReviewChip(jsonKey: 'k'),
      );
      expect(mocha, isNotNull);
      expect(latte, isNotNull);
      expect(mocha, isNot(equals(latte)),
          reason:
              'ConfigurationReviewChip background should track the palette '
              '— a hardcoded colour means the chrome ignores theme switches');
    });

    testWidgets('SettingsSectionHeader accent bar tracks the palette',
        (tester) async {
      const key = ValueKey<String>('header');
      final mocha = await pumpAndReadFirstAccentColor(
        tester,
        paletteId: 'catppuccin-mocha',
        childKey: key,
        body: const SettingsSectionHeader('GENERAL'),
      );
      final latte = await pumpAndReadFirstAccentColor(
        tester,
        paletteId: 'catppuccin-latte',
        childKey: key,
        body: const SettingsSectionHeader('GENERAL'),
      );
      expect(mocha, isNotNull);
      expect(latte, isNotNull);
      expect(mocha, isNot(equals(latte)),
          reason:
              'SettingsSectionHeader accent bar should track the palette');
    });
  });
}