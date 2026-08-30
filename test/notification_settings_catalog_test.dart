// Pins the notification settings declarations: presence in the
// General section, defaults, range, and the dependsOn relationship
// that drives the sub-item UI (Settings → General hides the threshold
// row while the master toggle is off — see `_visibleRows` in
// settings_dialog.dart).

import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/settings/settings_catalog.dart';

void main() {
  final catalog = SettingsCatalog();

  group('notifications.enabled (master toggle)', () {
    final setting = catalog.general.desktopNotifications;

    test('key + default', () {
      expect(setting.key, 'notifications.enabled');
      expect(setting.defaultValue, true);
    });

    test('is declared in the General section', () {
      expect(catalog.general.all, contains(setting));
    });
  });

  group('notifications.minTaskSeconds (sub-item)', () {
    final setting = catalog.general.notificationMinTaskSeconds;

    test('key + default (10s)', () {
      expect(setting.key, 'notifications.minTaskSeconds');
      expect(setting.defaultValue, 10);
    });

    test('declared in General directly after its master toggle', () {
      final all = catalog.general.all.toList();
      final masterIdx = all.indexOf(catalog.general.desktopNotifications);
      final subIdx = all.indexOf(setting);
      expect(masterIdx, greaterThanOrEqualTo(0));
      expect(subIdx, masterIdx + 1);
    });

    test('depends on the master toggle', () {
      expect(setting.dependsOn, same(catalog.general.desktopNotifications));
    });

    test('is clamped to 0..3600', () {
      expect(setting.min, 0);
      expect(setting.max, 3600);
    });
  });

  test('legacy snackbar toggle still exists (both paths kept)', () {
    expect(catalog.terminal.notifyOnOsc9.key, 'terminal.notifyOnOsc9');
    expect(catalog.terminal.notifyOnOsc9.defaultValue, false);
  });

  test('every setting in the catalog has a unique dotted key', () {
    final keys = catalog.all.map((s) => s.key).toList();
    expect(keys.toSet().length, keys.length);
  });
}
