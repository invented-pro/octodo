import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/shortcuts/app_shortcuts.dart';

void main() {
  group('primary() — cross-platform activator builder', () {
    test('no-shift Ctrl modifier matches Ctrl-only', () {
      final a = primary(LogicalKeyboardKey.keyB, shift: true);
      expect(a, isA<SingleActivator>());
      final s = a as SingleActivator;
      expect(
        s.control != s.meta,
        isTrue,
        reason: 'exactly one of control/meta must be set',
      );
      expect(s.shift, isTrue);
      expect(s.trigger, LogicalKeyboardKey.keyB);
    });

    test('Alt-only modifier does NOT include the platform primary', () {
      final a = altOnly(LogicalKeyboardKey.arrowUp, shift: true);
      final s = a as SingleActivator;
      expect(s.control, isFalse);
      expect(s.meta, isFalse);
      expect(s.alt, isTrue);
      expect(s.shift, isTrue);
    });

    test('plain() sets no modifiers', () {
      final a = plain(LogicalKeyboardKey.pageUp);
      final s = a as SingleActivator;
      expect(s.control, isFalse);
      expect(s.meta, isFalse);
      expect(s.alt, isFalse);
      expect(s.shift, isFalse);
      expect(s.trigger, LogicalKeyboardKey.pageUp);
    });
  });

  group('describe() — tooltip label', () {
    test('letters render as a single uppercase char', () {
      final s = describe(LogicalKeyboardKey.keyB, shift: true);
      expect(s.endsWith('B'), isTrue);
    });

    test('arrows render as Unicode arrows', () {
      expect(describe(LogicalKeyboardKey.arrowLeft).endsWith('←'), isTrue);
      expect(describe(LogicalKeyboardKey.arrowRight).endsWith('→'), isTrue);
      expect(describe(LogicalKeyboardKey.arrowUp).endsWith('↑'), isTrue);
      expect(describe(LogicalKeyboardKey.arrowDown).endsWith('↓'), isTrue);
    });

    test('F11 is rendered as "F11"', () {
      expect(describe(LogicalKeyboardKey.f11).endsWith('F11'), isTrue);
    });
  });

  group('AppShellBindings.build()', () {
    test('every binding has a non-null callback', () {
      bool called = false;
      final bindings = AppShellBindings.build(
        toggleDrawer: () => called = true,
        newWorkspace: () {},
        closeCurrentWorkspace: () {},
        nextWorkspace: () {},
        previousWorkspace: () {},
        jumpToWorkspace: (_) {},
        toggleFullscreen: () {},
        quit: () {},
        showReservedHint: (_) {},
      );
      expect(bindings, isNotEmpty);
      for (final entry in bindings.entries) {
        expect(entry.key, isA<ShortcutActivator>());
        expect(entry.value, isNotNull);
      }
      bindings.values.first();
      expect(called, isTrue);
    });

    test('fullscreen binding exists (F11 or Cmd+Ctrl+F depending on host)', () {
      final bindings = AppShellBindings.build(
        toggleDrawer: () {},
        newWorkspace: () {},
        closeCurrentWorkspace: () {},
        nextWorkspace: () {},
        previousWorkspace: () {},
        jumpToWorkspace: (_) {},
        toggleFullscreen: () {},
        quit: () {},
        showReservedHint: (_) {},
      );
      expect(
        bindings.length,
        greaterThan(10),
        reason: 'expected workspace + digit + fullscreen + reserved',
      );
    });
  });

  group('WorkspaceBindings.build()', () {
    test('every binding has a non-null callback', () {
      final bindings = WorkspaceBindings.build(
        newTab: () {},
        closeTab: () {},
        nextTab: () {},
        previousTab: () {},
        jumpToTab: (_) {},
        splitRight: () {},
        splitDown: () {},
        focusPaneInDirection: (_) {},
        toggleMaximizePane: () {},
      );
      expect(bindings, isNotEmpty);
      for (final entry in bindings.entries) {
        expect(entry.value, isNotNull);
      }
    });

    test('pane-direction bindings cover all four cardinal directions', () {
      final bindings = WorkspaceBindings.build(
        newTab: () {},
        closeTab: () {},
        nextTab: () {},
        previousTab: () {},
        jumpToTab: (_) {},
        splitRight: () {},
        splitDown: () {},
        focusPaneInDirection: (_) {},
        toggleMaximizePane: () {},
      );
      int dirHits = 0;
      for (final entry in bindings.entries) {
        final a = entry.key as SingleActivator;
        final isArrow =
            a.trigger == LogicalKeyboardKey.arrowUp ||
            a.trigger == LogicalKeyboardKey.arrowDown ||
            a.trigger == LogicalKeyboardKey.arrowLeft ||
            a.trigger == LogicalKeyboardKey.arrowRight;
        // Ctrl+Shift+arrow on Win/Linux, Cmd+Shift+arrow on macOS. No
        // Alt — the binding deliberately uses the platform primary
        // modifier (matching every other app shortcut) rather than
        // the Alt-only convention we used previously, which had no
        // discoverable mnemonic.
        final isPrimaryShift = (a.control || a.meta) && a.shift && !a.alt;
        if (isArrow && isPrimaryShift) dirHits++;
      }
      expect(
        dirHits,
        4,
        reason:
            'expected Ctrl/Cmd+Shift+{Up,Down,Left,Right} → focus pane in direction',
      );
    });
  });

  group('TerminalBindings.build()', () {
    test('every binding has a non-null callback', () {
      final bindings = TerminalBindings.build(
        copySelection: () {},
        paste: () {},
      );
      expect(bindings, isNotEmpty);
      for (final entry in bindings.entries) {
        expect(entry.value, isNotNull);
      }
    });

    test('zoom bindings are NOT in TerminalBindings — alacritty owns them', () {
      // Font zoom is owned by alacritty itself: the engine holds the
      // font-size state, and `defaultTerminalActions` in FA wires the
      // bundled `IncreaseFontSizeIntent` / `DecreaseFontSizeIntent` /
      // `ResetFontSizeIntent` to the keys in `defaultTerminalShortcuts`.
      // We do NOT duplicate the work in our binding factory — that
      // would drift from alacritty's source of truth and miss any
      // future zoom behavior alacritty adds. Instead, `TerminalView`
      // passes an extended `shortcuts:` map (alacritty's defaults +
      // shift variants) to `fa.TerminalView`.
      final bindings = TerminalBindings.build(
        copySelection: () {},
        paste: () {},
      );

      // None of the zoom activators should be present.
      bool hasZoomActivator(bool Function(SingleActivator) test) =>
          bindings.keys.any((a) => a is SingleActivator && test(a));
      expect(
        hasZoomActivator(
          (a) =>
              a.trigger == LogicalKeyboardKey.equal &&
              (a.control || a.meta) &&
              !a.shift &&
              !a.alt,
        ),
        isFalse,
        reason: 'Ctrl+= zoom should NOT be in TerminalBindings',
      );
      expect(
        hasZoomActivator(
          (a) =>
              a.trigger == LogicalKeyboardKey.minus &&
              (a.control || a.meta) &&
              !a.shift &&
              !a.alt,
        ),
        isFalse,
        reason: 'Ctrl+- zoom should NOT be in TerminalBindings',
      );
      expect(
        hasZoomActivator(
          (a) =>
              a.trigger == LogicalKeyboardKey.digit0 &&
              (a.control || a.meta) &&
              !a.shift &&
              !a.alt,
        ),
        isFalse,
        reason: 'Ctrl+0 zoom should NOT be in TerminalBindings',
      );
      expect(
        bindings.keys.any(
          (a) =>
              a is CharacterActivator &&
              (a.character == '=' ||
                  a.character == '+' ||
                  a.character == '-' ||
                  a.character == '0'),
        ),
        isFalse,
        reason:
            'CharacterActivator zoom fallbacks should NOT be in '
            'TerminalBindings',
      );
    });
  });

  group('Conflict audit', () {
    test('no bare Ctrl-letter is bound (readline / vim safety)', () {
      // The audit at the top of `app_shortcuts.dart` says: NEVER bind
      // a bare Ctrl-letter (no Shift, no Alt). Enumerate the merged
      // binding map and verify.
      //
      // Documented exception: `Ctrl/Cmd+V` is bound for paste (the
      // industry-standard binding). It conflicts with readline /
      // vim "verbatim insert", but every major terminal emulator
      // binds it anyway and three alternatives (Ctrl+Shift+V,
      // Shift+Insert, right-click) keep users unblocked. We
      // intentionally exclude `V` from the readline-key set so the
      // audit doesn't false-positive on this deliberate choice.
      final all = <Map<ShortcutActivator, VoidCallback>>[
        AppShellBindings.build(
          toggleDrawer: () {},
          newWorkspace: () {},
          closeCurrentWorkspace: () {},
          nextWorkspace: () {},
          previousWorkspace: () {},
          jumpToWorkspace: (_) {},
          toggleFullscreen: () {},
          quit: () {},
          showReservedHint: (_) {},
        ),
        WorkspaceBindings.build(
          newTab: () {},
          closeTab: () {},
          nextTab: () {},
          previousTab: () {},
          jumpToTab: (_) {},
          splitRight: () {},
          splitDown: () {},
          focusPaneInDirection: (_) {},
          toggleMaximizePane: () {},
        ),
        TerminalBindings.build(copySelection: () {}, paste: () {}),
      ];
      final readlineKeys = <LogicalKeyboardKey>{
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.keyG,
        LogicalKeyboardKey.keyH,
        LogicalKeyboardKey.keyI,
        LogicalKeyboardKey.keyJ,
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyO,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyQ,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyS,
        // keyT is intentionally NOT in this set — Ctrl+Shift+T is
        // bound for "new tab in focused pane" (replaces the previous
        // reopen-last-closed-tab binding per user request).
        LogicalKeyboardKey.keyU,
        // keyV is intentionally NOT in this set — Ctrl/Cmd+V is the
        // documented paste binding (industry-standard).
        LogicalKeyboardKey.keyW,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyY,
        LogicalKeyboardKey.keyZ,
      };
      for (final map in all) {
        for (final key in map.keys) {
          if (key is! SingleActivator) continue;
          final s = key;
          final isBarePrimary = (s.control ^ s.meta) && !s.shift && !s.alt;
          if (isBarePrimary && readlineKeys.contains(s.trigger)) {
            fail(
              'Bare Ctrl/Cmd-letter bound: '
              '${s.control ? "Ctrl" : "Cmd"}+${s.trigger.keyLabel} '
              '— would conflict with readline / vim.',
            );
          }
        }
      }
    });
  });
}
