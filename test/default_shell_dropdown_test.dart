// Tests for `Settings → Terminal → Default shell`.
//
// The row must be a dropdown of the detected profiles rather than a
// free-text field (typing a `shortName` that matches nothing silently
// falls back to the first profile at startup), and it must persist
// `shortName` — the stable identifier — not the display `label`, since
// two WSL distros share nothing else.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_store.dart';
import 'package:octodo/src/terminal/shell_profiles.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';
import 'package:octodo/ui/settings/widgets/trailing_widgets.dart';

/// Minimal in-memory [SettingsStore]. Mirrors the helper in
/// `theme_dropdown_test.dart` and `font_family_dropdown_test.dart`
/// rather than sharing, because there is no shared fixture layer in
/// the test suite yet.
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

final _setting = StringSetting(
  'terminal.defaultShell',
  defaultValue: '',
  title: 'Default shell',
);

ShellProfile _shell(String label, String shortName) => ShellProfile(
  label: label,
  program: 'C:/Program Files/PowerShell/7/pwsh.exe',
  args: const [],
  icon: Icons.terminal,
  color: Colors.grey,
  shortName: shortName,
);

/// Detection order as Windows produces it: the first entry is the
/// factory default, so the empty setting and index 0 agree.
final _shells = <ShellProfile>[
  _shell('PowerShell 7', 'pwsh'),
  _shell('Command Prompt', 'cmd'),
  _shell('Ubuntu-24.04', 'ubuntu-24.04'),
  _shell('Git Bash', 'bash'),
];

Future<_InMemoryStore> _pump(
  WidgetTester tester, {
  String? stored,
  List<ShellProfile>? shells,
}) async {
  final store = _InMemoryStore();
  if (stored != null) await store.set(_setting, stored);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(palette: AppPalettes.byId('catppuccin-mocha')),
      home: Scaffold(
        body: DefaultShellDropdownTrailing(
          setting: _setting,
          store: store,
          shells: shells ?? _shells,
        ),
      ),
    ),
  );
  return store;
}

List<DropdownMenuItem<String>> _items(WidgetTester tester) =>
    List<DropdownMenuItem<String>>.from(
      tester
              .widget<DropdownButton<String>>(
                find.byType(DropdownButton<String>),
              )
              .items ??
          const [],
    );

void main() {
  group('DefaultShellDropdownTrailing', () {
    testWidgets('offers a default entry plus every detected profile', (
      tester,
    ) async {
      await _pump(tester);
      final values = _items(tester).map((i) => i.value).toList();
      expect(values, ['', 'pwsh', 'cmd', 'ubuntu-24.04', 'bash']);
    });

    testWidgets('labels the factory default entry as Auto', (tester) async {
      await _pump(tester);
      final items = _items(tester);
      final defaultItem = items.firstWhere((i) => i.value == '');
      final text = ((defaultItem.child as SizedBox).child as Text).data;
      expect(
        text,
        'Auto',
        reason:
            'the empty value means "detection order"; naming the resolved '
            'profile went stale when detection order changed across hosts, '
            'and the resolved shell is always the first listed option',
      );
    });

    testWidgets('persists the shortName, not the label', (tester) async {
      final store = await _pump(tester);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ubuntu-24.04').last);
      await tester.pumpAndSettle();
      expect(
        store.get(_setting),
        'ubuntu-24.04',
        reason:
            'label carries a display suffix and program cannot distinguish '
            'two WSL distros; shortName is the stable identifier',
      );
    });

    testWidgets('keeps a stale value visible as "not detected"', (
      tester,
    ) async {
      await _pump(tester, stored: 'alpine');
      final items = _items(tester);
      final values = items.map((i) => i.value).toList();
      expect(values, contains('alpine'));
      final staleItem = items.firstWhere((i) => i.value == 'alpine');
      final text = ((staleItem.child as SizedBox).child as Text).data;
      expect(text, 'alpine (not detected)');
      // The dropdown still reflects the stored value rather than
      // snapping to a profile the user never picked.
      expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'alpine',
      );
    });

    testWidgets('renders the default-only row when detection is empty', (
      tester,
    ) async {
      await _pump(tester, shells: const <ShellProfile>[]);
      final values = _items(tester).map((i) => i.value).toList();
      expect(values, ['']);
    });
  });
}
