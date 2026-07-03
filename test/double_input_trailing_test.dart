// Tests for the +/− step buttons on `DoubleInputTrailing`, which back
// `Settings → Terminal → Font size`. The buttons are the only way to
// nudge the font size without typing into the field, so the contract is:
//   * +1 / −1 in 1-point increments;
//   * clamped to the setting's [min, max] window — repeated taps past
//     the bound must not push past it;
//   * the on-screen field text mirrors the bumped value, so the user
//     sees the new size without having to read the store.
//
// We don't share the `_InMemoryStore` helper from `theme_dropdown_test.dart`
// or `font_family_dropdown_test.dart` because the test suite has no
// shared fixture layer; copy-paste is the established convention.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_store.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';
import 'package:octodo/ui/settings/widgets/trailing_widgets.dart';

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
  group('DoubleInputTrailing step buttons', () {
    /// Pump a `DoubleInputTrailing` bound to a fresh in-memory store
    /// seeded with [seed] and return the store so each test can read
    /// back what the buttons wrote.
    Future<_InMemoryStore> pumpTrailing(
      WidgetTester tester, {
      required double seed,
    }) async {
      final store = _InMemoryStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(palette: AppPalettes.byId('catppuccin-mocha')),
          home: Scaffold(
            body: DoubleInputTrailing(
              setting: DoubleSetting(
                'terminal.fontSize',
                defaultValue: seed,
                min: 10.0,
                max: 24.0,
                title: 'Font size',
              ),
              store: store,
            ),
          ),
        ),
      );
      return store;
    }

    /// Read the value the trailing has currently stored. We pull
    /// directly from the store instead of from the field's controller
    /// so the test exercises the same `set()` path the UI uses.
    double storedFontSize(_InMemoryStore store) => store.get<double>(
      DoubleSetting('terminal.fontSize', defaultValue: 0.0, title: 'Font size'),
    );

    testWidgets('increment button raises the value by 1.0', (tester) async {
      final store = await pumpTrailing(tester, seed: 14.0);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(
        storedFontSize(store),
        15.0,
        reason: '+ button should add exactly 1.0 to the current value',
      );
    });

    testWidgets('decrement button lowers the value by 1.0', (tester) async {
      final store = await pumpTrailing(tester, seed: 14.0);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();
      expect(
        storedFontSize(store),
        13.0,
        reason:
            '- button should subtract exactly 1.0 from the current '
            'value',
      );
    });

    testWidgets('increment clamps to the setting max', (tester) async {
      final store = await pumpTrailing(tester, seed: 24.0);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(
        storedFontSize(store),
        24.0,
        reason: 'At max, + should be a no-op (clamp), not push past 24.0',
      );
    });

    testWidgets('decrement clamps to the setting min', (tester) async {
      final store = await pumpTrailing(tester, seed: 10.0);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();
      expect(
        storedFontSize(store),
        10.0,
        reason: 'At min, - should be a no-op (clamp), not push past 10.0',
      );
    });

    testWidgets('repeated increments step across the whole range', (
      tester,
    ) async {
      final store = await pumpTrailing(tester, seed: 13.0);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
      }
      expect(
        storedFontSize(store),
        18.0,
        reason:
            '5 × +1.0 from 13.0 must land on 18.0 exactly, proving '
            'the step is a flat 1.0 (not a % of the current value) and '
            'that double arithmetic stays exact across the run',
      );
    });

    testWidgets('field text mirrors the bumped value', (tester) async {
      await pumpTrailing(tester, seed: 14.0);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller!.text,
        '15',
        reason:
            'bumping should rewrite the field text so the user sees '
            'the new value, not a stale "14"',
      );
    });
  });
}
