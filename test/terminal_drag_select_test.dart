// Regression guard for the kModeMouseAny bitmask we duplicate from
// flutter_alacritty's `input/term_mode.dart` (which is kept
// package-internal and not exported from the public API).
//
// The octodo `_TerminalDragSelector` overlay uses this mask to detect
// when the child shell has enabled any flavor of VT mouse reporting
// (DECSET 1000 / 1002 / 1003) and intercept plain left-drag to start a
// local selection (matching Windows Terminal's policy rather than
// alacritty's default of "let the app have the mouse"). If the
// upstream alacritty terminal engine changes its `TermMode` bit
// assignments, the corresponding mask MUST change in lockstep here;
// this test exists to fail loudly if a future alacritty refactor
// renumbers the bits and we forget to mirror it.
//
// Bit assignment reference (kept in sync with
// rust_lib_flutter_alacritty's TermModeFlags):
//   kModeMouseClick   = 1 << 3  = 0x0008   (DECSET 1000)
//   kModeMouseMotion  = 1 << 6  = 0x0040   (DECSET 1002)
//   kModeMouseDrag    = 1 << 13 = 0x2000   (DECSET 1003)
//
// We pin the *literal value* (rather than re-deriving via bit shifts)
// because the bug class is "what if a future contributor shifts the
// bits to add a new mode?" — a comment-only assertion would let a
// silent drift pass. Any change here requires reading the package
// source first.

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/terminal/terminal_view.dart';

void main() {
  group('terminalAnyMouseModeFlag', () {
    test(
      'is 0x2048 (kModeMouseClick | kModeMouseMotion | kModeMouseDrag)',
      () {
        expect(
          TerminalViewState.terminalAnyMouseModeFlag,
          equals(0x2048),
          reason:
              'Bitmask must mirror flutter_alacritty\'s '
              'input/term_mode.dart::kModeMouseAny (= '
              'kModeMouseClick 1<<3 | kModeMouseMotion 1<<6 | '
              'kModeMouseDrag 1<<13 = 0x2048 = 8264). If alacritty\'s '
              'TermMode bits shift, update both sides.',
        );
      },
    );

    test(
      'masks each mode individually (proves individual bits are preserved)',
      () {
        const mask = TerminalViewState.terminalAnyMouseModeFlag;
        // DECSET 1000 = kModeMouseClick = bit 3 = 0x0008
        expect(mask & 0x0008, equals(0x0008));
        // DECSET 1002 = kModeMouseMotion = bit 6 = 0x0040
        expect(mask & 0x0040, equals(0x0040));
        // DECSET 1003 = kModeMouseDrag = bit 13 = 0x2000
        expect(mask & 0x2000, equals(0x2000));
      },
    );
  });

  group('terminalDragSelectThresholdPx', () {
    test('is 4.0 (small enough to not fight clicks, big enough not to drag)',
        () {
      expect(
        TerminalViewState.terminalDragSelectThresholdPx,
        equals(4.0),
        reason:
            'Drag must travel this many pixels from the press point '
            'before the overlay treats it as a drag — below this '
            'the inner fa.TerminalView handles the click normally.',
      );
    });
  });

  group('terminalAltScreenModeFlag', () {
    test('is 1 << 12 (kModeAltScreen)', () {
      expect(
        TerminalViewState.terminalAltScreenModeFlag,
        equals(1 << 12),
        reason:
            'Bitmask must mirror flutter_alacritty\'s '
            'input/term_mode.dart::kModeAltScreen (= 1 << 12 = 0x1000). '
            'The drag-select auto-scroll gates itself off in alt-screen '
            'apps (vim/less); if alacritty\'s TermMode bits shift, that '
            'gate breaks silently.',
      );
    });
  });

  group('terminalAutoscroll constants', () {
    test('edge zone and max speed are sane positive values', () {
      expect(TerminalViewState.terminalAutoscrollEdgeZoneCells,
          greaterThan(0));
      expect(TerminalViewState.terminalAutoscrollMaxSpeedCellsPerSec,
          greaterThan(0));
      // Pin the shipped defaults so behavior changes are deliberate.
      expect(TerminalViewState.terminalAutoscrollEdgeZoneCells, equals(2.5));
      expect(TerminalViewState.terminalAutoscrollMaxSpeedCellsPerSec,
          equals(20.0));
    });
  });

  group('terminalAutoscrollSpeedCellsPerSec', () {
    // Viewport 400px tall, edge zone 50px (top zone [0,50], bottom [350,400]).
    const h = 400.0;
    const zone = 50.0;
    final max = TerminalViewState.terminalAutoscrollMaxSpeedCellsPerSec;

    test('zero in the middle of the viewport', () {
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(200, h, zone),
          equals(0.0));
    });

    test('zero at the exact zone boundaries', () {
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(50, h, zone),
          equals(0.0));
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(350, h, zone),
          equals(0.0));
    });

    test('positive (up into history) inside the top zone, ramping', () {
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(0, h, zone),
          closeTo(max, 1e-9));
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(25, h, zone),
          closeTo(max / 2, 1e-9));
    });

    test('negative (toward live edge) inside the bottom zone, ramping', () {
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(400, h, zone),
          closeTo(-max, 1e-9));
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(375, h, zone),
          closeTo(-max / 2, 1e-9));
    });

    test('past-edge positions clamp to full speed', () {
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(-100, h, zone),
          closeTo(max, 1e-9));
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(500, h, zone),
          closeTo(-max, 1e-9));
    });

    test('dominant side wins when zones overlap (tiny viewport)', () {
      // Viewport 60px, zone 50px: zones overlap; the deeper penetration
      // wins. dy=20 → top ratio 0.6 vs bottom 0.2 → up.
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(20, 60, zone),
          closeTo(0.6 * max, 1e-9));
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(40, 60, zone),
          closeTo(-0.6 * max, 1e-9));
    });

    test('degenerate zone is inert', () {
      expect(
          TerminalViewState.terminalAutoscrollSpeedCellsPerSec(0, h, 0),
          equals(0.0));
    });
  });

  group('constants are exposed @visibleForTesting', () {
    test('terminalAnyMouseModeFlag is a non-zero int', () {
      expect(TerminalViewState.terminalAnyMouseModeFlag, isA<int>());
      expect(TerminalViewState.terminalAnyMouseModeFlag, isNot(equals(0)));
    });

    test('terminalDragSelectThresholdPx is a positive double', () {
      expect(TerminalViewState.terminalDragSelectThresholdPx, isA<double>());
      expect(TerminalViewState.terminalDragSelectThresholdPx, greaterThan(0));
    });
  });
}
