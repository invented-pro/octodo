// Tests for the targeted-emission behavior in `JsonSettingsStore`.
//
// Before this change, every `set` / `reset` / `resetAll` fired every
// per-key `StreamController` (8+ for a typical catalog), and each
// `watch<T>(key)` listener re-read + re-codec'd the value. The
// targeted emit path passes the typed value straight to the changed
// key's controller and skips every other one.
//
// We use a real `JsonSettingsStore` (with a temp file) rather than
// the in-memory mock — the whole point is the file write → emit
// glue.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:octodo/src/settings/json_settings_store.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/setting_codec.dart';

class _BoolSetting extends Setting<bool> {
  @override
  final String key;
  @override
  final bool defaultValue;
  @override
  final String title;
  @override
  String? get subtitle => null;
  @override
  get icon => null;
  @override
  SettingCodec<bool> get codec => const _BoolCodec();

  _BoolSetting(this.key, {required this.defaultValue})
      : title = key;
}

class _BoolCodec extends SettingCodec<bool> {
  const _BoolCodec();
  @override
  bool fromJson(Object? json) => json == true;
  @override
  Object? toJson(bool value) => value;
}

void main() {
  late Directory tempDir;
  late JsonSettingsStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('octodo_settings_emit_');
    store = JsonSettingsStore(File(p.join(tempDir.path, 'settings.json')));
  });

  tearDown(() async {
    store.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('targeted emit on set', () {
    test('set() fires only the changed key\'s watcher', () async {
      final fontFamily = _BoolSetting('fontFamily', defaultValue: false);
      final fontSize = _BoolSetting('fontSize', defaultValue: false);

      final fontFamilyEvents = <bool>[];
      final fontSizeEvents = <bool>[];

      final fontFamilySub = store.watch<bool>(fontFamily).listen(fontFamilyEvents.add);
      final fontSizeSub = store.watch<bool>(fontSize).listen(fontSizeEvents.add);

      await store.set(fontFamily, true);

      // Yield so the broadcast stream delivers.
      await Future<void>.delayed(Duration.zero);

      expect(fontFamilyEvents, [true],
          reason: 'the changed key\'s watcher must fire');
      expect(fontSizeEvents, isEmpty,
          reason: 'unrelated keys\' watchers must NOT fire');

      await fontFamilySub.cancel();
      await fontSizeSub.cancel();
    });

    test('watcher receives the typed value directly (no re-codec)', () async {
      final key = _BoolSetting('onlyKey', defaultValue: false);
      final received = <bool>[];

      final sub = store.watch<bool>(key).listen(received.add);

      await store.set(key, true);
      await Future<void>.delayed(Duration.zero);

      expect(received, [true]);

      await sub.cancel();
    });
  });

  group('targeted emit on reset', () {
    test('reset() fires only the reset key\'s watcher with default value', () async {
      final key = _BoolSetting('onlyKey', defaultValue: false);
      await store.set(key, true);

      final events = <bool>[];
      final sub = store.watch<bool>(key).listen(events.add);

      await store.reset(key);
      await Future<void>.delayed(Duration.zero);

      expect(events, [false],
          reason: 'reset should emit the default value back to the watcher');

      await sub.cancel();
    });
  });

  group('resetAll still fans out', () {
    test('resetAll() fires every per-key watcher', () async {
      final fontFamily = _BoolSetting('fontFamily', defaultValue: false);
      final fontSize = _BoolSetting('fontSize', defaultValue: false);

      await store.set(fontFamily, true);
      await store.set(fontSize, true);

      final ffEvents = <bool>[];
      final fsEvents = <bool>[];

      final ffSub = store.watch<bool>(fontFamily).listen(ffEvents.add);
      final fsSub = store.watch<bool>(fontSize).listen(fsEvents.add);

      await store.resetAll();
      await Future<void>.delayed(Duration.zero);

      expect(ffEvents, [false]);
      expect(fsEvents, [false]);

      await ffSub.cancel();
      await fsSub.cancel();
    });
  });

  group('distinct still filters no-op writes', () {
    test('setting the same value does not re-emit', () async {
      final key = _BoolSetting('onlyKey', defaultValue: false);

      final events = <bool>[];
      final sub = store.watch<bool>(key).listen(events.add);

      await store.set(key, true);
      await Future<void>.delayed(Duration.zero);

      await store.set(key, true);
      await Future<void>.delayed(Duration.zero);

      expect(events, [true],
          reason: 'distinct should drop the duplicate write');

      await sub.cancel();
    });
  });
}