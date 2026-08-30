// Regression tests for the persistent in-app banner overlay.
//
// The card uses a `Row(crossAxisAlignment: stretch)` for its
// full-height accent bar; inside the overlay's min-size Column that
// receives unbounded height, stretch creates
// `BoxConstraints.tightFor(height: ∞)` ("BoxConstraints forces an
// infinite height") and the aborted layout cascades into a
// RenderBox-was-not-laid-out storm on every subsequent frame. The
// `IntrinsicHeight` in `_BannerCard` is the fix — these tests pin
// both the layout validity and the appear/dismiss lifecycle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/notifications/in_app_banner_overlay.dart';
import 'package:octodo/src/notifications/notification_hub.dart';
import 'package:octodo/src/settings/setting.dart';
import 'package:octodo/src/settings/settings_catalog.dart';
import 'package:octodo/src/settings/settings_store.dart';
import 'package:octodo/src/theme/app_theme.dart';
import 'package:octodo/src/theme/palettes.dart';

class _FakeStore implements SettingsStore {
  @override
  T get<T>(Setting<T> key) => key.defaultValue;
  @override
  Future<void> set<T>(Setting<T> key, T value) async {}
  @override
  Future<void> reset<T>(Setting<T> key) async {}
  @override
  Future<void> resetAll() async {}
  @override
  bool isExplicitlySet<T>(Setting<T> key) => false;
  @override
  Stream<T> watch<T>(Setting<T> key) => const Stream.empty();
  @override
  Stream<void> watchWrites() => const Stream.empty();
  @override
  Stream<Object> watchLoadErrors() => const Stream<Object>.empty();
}

void main() {
  late NotificationHub hub;

  setUp(() {
    // `isAppFocused: true` keeps the 30 s re-alert ticker disarmed —
    // testWidgets fails on timers that outlive the test body, and
    // these tests exercise the overlay, not the re-alert loop.
    hub = NotificationHub(
      store: _FakeStore(),
      catalog: SettingsCatalog(),
      isAppFocused: () => true,
    );
  });

  tearDown(() {
    hub.dispose();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(palette: AppPalettes.defaultPalette),
        home: Scaffold(
          body: Stack(
            children: [
              const ColoredBox(color: Color(0xFF000000)),
              InAppBannerOverlay(
                hub: hub,
                onActivate: (_, _) {},
                onDismiss: (_, _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('cards lay out cleanly inside a min-size overlay column', (
    tester,
  ) async {
    hub.handle(
      'ws-0',
      's-1',
      const TerminalAttention(kind: AttentionKind.bell),
    );
    hub.handle(
      'ws-0',
      's-2',
      const TerminalAttention(kind: AttentionKind.bell),
    );
    hub.handle(
      'ws-1',
      's-3',
      const TerminalAttention(kind: AttentionKind.bell),
    );
    await pumpApp(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Octodo'), findsNWidgets(3));
    // Cards hug the top-right corner, not the full width.
    final cardRect = tester.getTopRight(find.text('Octodo').first);
    final windowRect = tester.getTopRight(find.byType(Scaffold));
    expect(cardRect.dx, lessThan(windowRect.dx));
    expect(cardRect.dy, lessThan(80));
  });

  testWidgets('overlay appears mid-session and disappears on markRead', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('Octodo'), findsNothing);
    hub.handle(
      'ws-0',
      's-1',
      const TerminalAttention(kind: AttentionKind.bell),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Octodo'), findsOneWidget);
    hub.markRead('ws-0', 's-1');
    await tester.pumpAndSettle();
    expect(find.text('Octodo'), findsNothing);
  });

  testWidgets('coalesced bursts render one card with the count chip', (
    tester,
  ) async {
    hub.handle(
      'ws-0',
      's-1',
      const TerminalAttention(kind: AttentionKind.bell),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('×1'),
      findsNothing,
      reason: 'count chip only renders above 1',
    );
  });
}
