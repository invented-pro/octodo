// Reproduction test for the "Cannot hit test a render box with no
// size" storm that fired while the Feishu QR dialog was open:
// clicking "Connect Feishu…" opens the QR modal from the binding
// flow's phase listener, and every subsequent mouse move threw
// during the mouse tracker's device update.
//
// Root cause (fixed): AlertDialog wraps its content column in an
// IntrinsicWidth; the speculative intrinsic walk reached
// QrImageView's internal LayoutBuilder and threw, leaving the
// dialog's render box sizeless — every later hit test over it
// failed. The fix (a tight SizedBox around QrImageView) is
// regression-guarded here.
//
// The test replays the whole chain headlessly — panel, tap, phase
// transition, auto-opened dialog — then wiggles a mouse pointer
// across the screen. `takeException()` at the end surfaces the full
// first exception (with the offending render object) if it ever
// regresses.

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_binding_flow.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';
import 'package:octodo/src/feishu/feishu_device_flow_client.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_catalog.dart';
import 'package:octodo/src/settings/settings_runtime.dart';
import 'package:octodo/src/settings/settings_store.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';
import 'package:octodo/ui/feishu/feishu_panel.dart';
class _StubClient implements FeishuDeviceFlowClient {
  @override
  final Duration requestTimeout = const Duration(seconds: 5);

  @override
  String get feishuDomain => 'https://accounts.feishu.cn';

  @override
  String get larkDomain => 'https://accounts.larksuite.com';

  @override
  void close() {}

  @override
  Future<FeishuDeviceFlowBegin> begin({String? domain}) async =>
      FeishuDeviceFlowBegin(
        deviceCode: 'dc_repro',
        verificationUriComplete: Uri.parse(
          'https://open.feishu.cn/connect/qr?user_code=repro',
        ),
        interval: const Duration(minutes: 10),
        expiresIn: const Duration(minutes: 10),
      );

  @override
  Future<FeishuPollResult> poll(String deviceCode, {String? domain}) async =>
      const FeishuPollResult(error: 'authorization_pending');
}

/// Minimal in-memory store — enough for the settings toggle row.
class _MemStore implements SettingsStore {
  final _values = <String, Object?>{};

  @override
  T get<T>(Setting<T> key) =>
      (_values[key.key] as T?) ?? key.defaultValue;

  @override
  Future<void> set<T>(Setting<T> key, T value) async {
    _values[key.key] = value;
  }

  @override
  Future<void> reset<T>(Setting<T> key) async {
    _values.remove(key.key);
  }

  @override
  Future<void> resetAll() async => _values.clear();

  @override
  bool isExplicitlySet<T>(Setting<T> key) => _values.containsKey(key.key);

  @override
  Stream<T> watch<T>(Setting<T> key) => const Stream.empty();

  @override
  Stream<void> watchWrites() => const Stream.empty();

  @override
  Stream<Object> watchLoadErrors() => const Stream.empty();
}

void main() {
  testWidgets('mouse over the auto-opened QR dialog hit-tests cleanly',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('feishu_repro');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final flow = FeishuBindingFlow(
      client: _StubClient(),
      credentialStore: FeishuCredentialStore(
          File('${tmp.path}${Platform.pathSeparator}c.json')),
      // Park the polling loop forever: the QR dialog stays open for
      // the whole test without timers or an infinite microtask loop.
      sleepOverride: (d) => Completer<void>().future,
      nowOverride: () => DateTime.utc(2026, 1, 1),
    );
    FeishuBindingFlow.sharedForTesting = flow;
    addTearDown(() => FeishuBindingFlow.sharedForTesting = null);

    SettingsRuntime.instance = SettingsRuntime.create(
      store: _MemStore(),
      catalog: SettingsCatalog(),
      hostActions: SettingsHostActions(
        revealInFileManager: (_) {},
        openInExternalEditor: (_) {},
        restartApp: () {},
      ),
    );
    addTearDown(() => SettingsRuntime.instance = null);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(palette: AppPalettes.byId('catppuccin-mocha')),
      home: const Scaffold(body: Center(child: MobileAppsPanel())),
    ));

    // Click "Connect Feishu…".
    await tester.tap(find.text('Connect Feishu…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The QR dialog must be on screen.
    expect(find.text('Scan with Feishu'), findsOneWidget);

    // Wiggle the mouse across the whole surface — every move runs a
    // mouse-tracker device update with a full hit test.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(200, 200));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await mouse.moveTo(Offset(120.0 + i * 35, 260 + (i % 3) * 60));
      await tester.pump();
    }
    await mouse.removePointer();
    await tester.pump();

    final exception = tester.takeException();
    expect(exception, isNull,
        reason: 'mouse hit-testing over the QR dialog must not throw');
  });
}
