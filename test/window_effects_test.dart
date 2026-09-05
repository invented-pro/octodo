// Tests for `window_effects.dart` — the HWND lookup retry and the
// accent-application path. Both native touchpoints (`FindWindowW`,
// `SetWindowCompositionAttribute`) are injected, so the suite is
// deterministic and platform-agnostic (no real `user32.dll` calls).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:octodo/src/window/window_effects.dart';

void main() {
  setUp(() {
    findWindowOverride = null;
    applyAccentOverride = null;
  });

  group('enableAcrylic retry', () {
    test('applies immediately when the window is found on first attempt', () async {
      var lookups = 0;
      findWindowOverride = (title) {
        lookups++;
        expect(title, 'Octodo');
        return 1234;
      };
      final applied = <List<int>>[];
      applyAccentOverride = (hwnd, state, flags, color) =>
          applied.add([hwnd, state, flags, color]);

      await enableAcrylic(
        title: 'Octodo',
        tint: const Color(0xFF1E1E2E),
        alpha: 0.05,
      );

      expect(lookups, 1);
      expect(applied, hasLength(1));
      expect(applied.single[0], 1234);
    });

    test('retries until the window appears (startup race)', () async {
      var lookups = 0;
      findWindowOverride = (title) {
        lookups++;
        // Miss twice — as if `setTitle` hadn't run yet — then hit.
        return lookups < 3 ? 0 : 4321;
      };
      final applied = <List<int>>[];
      applyAccentOverride = (hwnd, state, flags, color) =>
          applied.add([hwnd, state, flags, color]);

      await enableAcrylic(
        title: 'Octodo',
        tint: const Color(0xFF1E1E2E),
        alpha: 0.05,
        maxAttempts: 5,
        retryDelay: const Duration(milliseconds: 1),
      );

      expect(lookups, 3);
      expect(applied, hasLength(1));
      expect(applied.single[0], 4321);
    });

    test('gives up after maxAttempts and never applies the accent', () async {
      var lookups = 0;
      findWindowOverride = (_) {
        lookups++;
        return 0;
      };
      final applied = <List<int>>[];
      applyAccentOverride = (hwnd, state, flags, color) =>
          applied.add([hwnd, state, flags, color]);

      await enableAcrylic(
        title: 'Octodo',
        tint: const Color(0xFF1E1E2E),
        alpha: 0.05,
        maxAttempts: 3,
        retryDelay: const Duration(milliseconds: 1),
      );

      expect(lookups, 3);
      expect(applied, isEmpty);
    });
  });

  group('enableAcrylic accent payload', () {
    test('packs tint + alpha as ABGR with the acrylic accent state', () async {
      findWindowOverride = (_) => 7;
      final applied = <List<int>>[];
      applyAccentOverride = (hwnd, state, flags, color) =>
          applied.add([hwnd, state, flags, color]);

      await enableAcrylic(
        title: 'Octodo',
        tint: const Color(0xFF1E1E2E), // r=0x1E g=0x1E b=0x2E
        alpha: 1.0,
      );

      expect(applied, hasLength(1));
      final [hwnd, state, flags, color] = applied.single;
      expect(hwnd, 7);
      expect(state, 4); // ACCENT_ENABLE_ACRYLICBLURBEHIND
      expect(flags, 2);
      // ABGR: a=0xFF, b=0x2E, g=0x1E, r=0x1E.
      expect(color, 0xFF2E1E1E);
    });

    test('clamps alpha into 0.0–1.0', () async {
      findWindowOverride = (_) => 7;
      final colors = <int>[];
      applyAccentOverride = (hwnd, state, flags, color) => colors.add(color);

      await enableAcrylic(
        title: 'Octodo',
        tint: const Color(0xFF000000),
        alpha: 5.0,
      );
      await enableAcrylic(
        title: 'Octodo',
        tint: const Color(0xFF000000),
        alpha: -1.0,
      );

      expect(colors, hasLength(2));
      expect(colors[0] >> 24 & 0xFF, 0xFF); // clamped high
      expect(colors[1] >> 24 & 0xFF, 0x00); // clamped low
    });
  });

  group('defaults', () {
    test('retry budget is bounded and short', () {
      expect(acrylicMaxAttempts, greaterThanOrEqualTo(2));
      expect(acrylicMaxAttempts, lessThanOrEqualTo(10));
      expect(acrylicRetryDelay, lessThanOrEqualTo(const Duration(seconds: 1)));
    });
  });

  group('effectiveBackgroundAlpha', () {
    test('frosted applies the frost level where the backdrop exists', () {
      expect(
        effectiveBackgroundAlphaCore(
          frosted: true,
          frostLevel: 0.05,
          opacity: 0.9,
          degradeFrostToOpacity: false,
        ),
        0.05,
      );
    });

    test('frosted degrades to the plain opacity where it does not', () {
      expect(
        effectiveBackgroundAlphaCore(
          frosted: true,
          frostLevel: 0.05,
          opacity: 0.9,
          degradeFrostToOpacity: true,
        ),
        0.9,
      );
    });

    test('unfrosted always uses the plain opacity', () {
      expect(
        effectiveBackgroundAlphaCore(
          frosted: false,
          frostLevel: 0.05,
          opacity: 0.4,
          degradeFrostToOpacity: false,
        ),
        0.4,
      );
      expect(
        effectiveBackgroundAlphaCore(
          frosted: false,
          frostLevel: 0.05,
          opacity: 0.4,
          degradeFrostToOpacity: true,
        ),
        0.4,
      );
    });

    test('degradation gate is Linux-only', () {
      expect(frostDegradesToOpacity, Platform.isLinux);
    });
  });

  test('unawaited enableAcrylic completes without a finder (non-Windows)', () async {
    // Simulates a platform where the FFI symbols can't be resolved and
    // no overrides are installed: must complete without throwing and
    // never apply an accent.
    final applied = <List<int>>[];
    applyAccentOverride = (hwnd, state, flags, color) =>
        applied.add([hwnd, state, flags, color]);
    // No findWindowOverride: on non-Windows the real lookup is a no-op
    // returning 0, so the accent is never applied.
    unawaited(
      enableAcrylic(
        title: 'Octodo',
        tint: const Color(0xFF1E1E2E),
        alpha: 0.05,
        maxAttempts: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(applied, isEmpty);
  });
}
