// Native window backdrop effects. A thin Dart FFI wrapper around the
// (undocumented but stable) Win32 `SetWindowCompositionAttribute` API
// to enable acrylic / blur-behind — the same call `window_manager`
// uses internally for its background color, exposed here with the
// `ACCENT_ENABLE_ACRYLICBLURBEHIND` accent state that `window_manager`
// doesn't surface.
//
// Windows-only. On every other platform the call is a no-op.
//
// Why FFI instead of a method channel in the runner? It keeps the
// feature self-contained in Dart (no C++ runner edits). The HWND is
// resolved via `FindWindowW` by the app title (set in `main()` via
// `windowManager.setTitle`), which is stable for this single-window app.

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

import '../log.dart';

final Logger _log = moduleLogger('window.effects');

/// Whether the frosted-background setting must degrade to the plain
/// background opacity on this platform (Linux only). There, no native
/// blur exists behind the window for the frost tint to ride on, so
/// dropping the in-app background to the frost level (default 0.05)
/// leaves the desktop showing almost unobstructed. macOS and Windows
/// keep their established frosted behavior (tinted translucency and
/// native acrylic respectively).
bool get frostDegradesToOpacity => Platform.isLinux;

/// In-app background alpha for the live appearance settings: the
/// frost level applies while frosted, except on platforms where the
/// frosted backdrop is unavailable and the toggle degrades to the
/// plain background opacity (see [frostDegradesToOpacity]).
double effectiveBackgroundAlpha({
  required bool frosted,
  required double frostLevel,
  required double opacity,
}) =>
    effectiveBackgroundAlphaCore(
      frosted: frosted,
      frostLevel: frostLevel,
      opacity: opacity,
      degradeFrostToOpacity: frostDegradesToOpacity,
    );

/// Pure core of [effectiveBackgroundAlpha], parameterized on the
/// degradation flag so tests can pin both branches on any host
/// (the production getter reads `Platform.isLinux` directly).
@visibleForTesting
double effectiveBackgroundAlphaCore({
  required bool frosted,
  required double frostLevel,
  required double opacity,
  required bool degradeFrostToOpacity,
}) =>
    frosted ? (degradeFrostToOpacity ? opacity : frostLevel) : opacity;

// Win32 accent state: acrylic / blur-behind (winuser.h, undocumented).
const int _accentEnableAcrylicBlurBehind = 4;

/// WindowCompositionAttribute id for the accent policy.
const int _wcaAccentPolicy = 19;

// ── FFI shapes ──────────────────────────────────────────────────────

final class _AccentPolicy extends Struct {
  @Int32()
  external int accentState;
  @Int32()
  external int flags;
  @Uint32()
  external int gradientColor; // ABGR packed
  @Int32()
  external int animationId;
}

// Matches the C `WINCOMPATTRDATA { int nAttribute; PVOID pData; ULONG
// ulDataSize; }` — default struct alignment inserts 4 bytes of padding
// after `nAttribute` so the 8-byte `pData` lands at offset 8, exactly
// like the native layout `window_manager` builds.
final class _WinCompAttrData extends Struct {
  @Int32()
  external int attribute;
  external Pointer<_AccentPolicy> data;
  @Uint32()
  external int dataSize;
}

typedef _SetWindowCompositionAttributeNative
    = Int8 Function(IntPtr hwnd, Pointer<_WinCompAttrData> data);
typedef _SetWindowCompositionAttributeDart
    = int Function(int hwnd, Pointer<_WinCompAttrData> data);

typedef _FindWindowWNative
    = IntPtr Function(Pointer<Utf16> className, Pointer<Utf16> windowName);
typedef _FindWindowWDart
    = int Function(Pointer<Utf16> className, Pointer<Utf16> windowName);

bool _resolved = false;
_SetWindowCompositionAttributeDart? _setWindowCompositionAttribute;
_FindWindowWDart? _findWindowW;

void _resolve() {
  if (_resolved) return;
  _resolved = true;
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    _setWindowCompositionAttribute = user32.lookupFunction<
        _SetWindowCompositionAttributeNative,
        _SetWindowCompositionAttributeDart>('SetWindowCompositionAttribute');
    _findWindowW =
        user32.lookupFunction<_FindWindowWNative, _FindWindowWDart>('FindWindowW');
  } catch (e, st) {
    _log.warning('Could not resolve user32 acrylic symbols: $e', e, st);
  }
}

int _findMainWindow(String title) {
  final find = _findWindowW;
  if (find == null) return 0;
  final ptr = title.toNativeUtf16();
  try {
    return find(nullptr, ptr);
  } finally {
    malloc.free(ptr);
  }
}

/// Signature of the HWND lookup used by [enableAcrylic].
@visibleForTesting
typedef WindowFinder = int Function(String title);

/// When set, replaces the real `FindWindowW` lookup. Test-only hook that
/// lets the retry behaviour be exercised without a Win32 window.
@visibleForTesting
WindowFinder? findWindowOverride;

// Startup timing: `enableAcrylic` can be invoked from a post-frame
// callback while the window is still being shown / retitled (the
// `waitUntilReadyToShow` callback races the first Flutter frame). A
// single `FindWindowW` miss used to disable the acrylic backdrop for
// the whole session — leaving a fully transparent window — so the
// lookup now retries briefly before giving up.
@visibleForTesting
const int acrylicMaxAttempts = 5;

@visibleForTesting
const Duration acrylicRetryDelay = Duration(milliseconds: 100);

/// Resolves the HWND for [title], retrying up to [maxAttempts] times
/// with [retryDelay] between attempts (the window title may not be set
/// yet during the startup race). Returns 0 if every attempt misses.
Future<int> _resolveMainWindow(
  String title,
  int maxAttempts,
  Duration retryDelay,
) async {
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    final finder = findWindowOverride ?? _findMainWindow;
    final hwnd = finder(title);
    if (hwnd != 0) return hwnd;
    if (attempt < maxAttempts) {
      await Future<void>.delayed(retryDelay);
    }
  }
  return 0;
}

/// Enable native acrylic (frosted-glass) blur behind the window [title].
///
/// Returns a [Future] that completes once the accent has been applied, or
/// when all retries have been exhausted (in which case a warning is logged
/// and the call is a no-op). Callers may safely fire-and-forget the
/// returned future.
///
/// [tint] is the acrylic overlay color (normally the active palette's
/// `surface0`) and [alpha] (0.0–1.0) its strength: 0 = pure blur of the
/// desktop with no tint, 1 = fully opaque tint. The blur radius itself
/// is fixed by the OS (the Win32 acrylic API exposes no sigma), so the
/// frost slider maps to tint alpha.
///
/// On non-Windows, or when the Win32 symbols cannot be resolved, or when
/// the target window is not found after [maxAttempts] retries, the call
/// is a no-op.
Future<void> enableAcrylic({
  required String title,
  required Color tint,
  required double alpha,
  @visibleForTesting int maxAttempts = acrylicMaxAttempts,
  @visibleForTesting Duration retryDelay = acrylicRetryDelay,
}) async {
  final applyAccent = applyAccentOverride;
  if (applyAccent == null) {
    _resolve();
    if (_setWindowCompositionAttribute == null) return;
  }
  final hwnd = await _resolveMainWindow(title, maxAttempts, retryDelay);
  if (hwnd == 0) {
    _log.warning(
      'enableAcrylic: window "$title" not found '
      'after $maxAttempts attempts',
    );
    return;
  }
  final a = (alpha.clamp(0.0, 1.0) * 255).round() & 0xFF;
  final r = (tint.r * 255).round() & 0xFF;
  final g = (tint.g * 255).round() & 0xFF;
  final b = (tint.b * 255).round() & 0xFF;
  // Win32 composition colors are ABGR, not ARGB.
  final abgr = (a << 24) | (b << 16) | (g << 8) | r;

  if (applyAccent != null) {
    applyAccent(hwnd, _accentEnableAcrylicBlurBehind, _accentFlags, abgr);
    return;
  }

  await _applyAccentViaWin32(hwnd, _accentEnableAcrylicBlurBehind, _accentFlags, abgr);
}

// Accent policy flags: 2 = draw all four borders of the blur region.
const int _accentFlags = 2;

/// Test-only replacement for the native `SetWindowCompositionAttribute`
/// call, receiving `(hwnd, accentState, flags, gradientColor)`. When
/// set, acrylic can be exercised end-to-end on any platform.
@visibleForTesting
void Function(int hwnd, int accentState, int flags, int gradientColor)?
applyAccentOverride;

Future<void> _applyAccentViaWin32(
  int hwnd,
  int accentState,
  int flags,
  int gradientColor,
) async {
  final accent = malloc<_AccentPolicy>();
  final data = malloc<_WinCompAttrData>();
  try {
    accent.ref
      ..accentState = accentState
      ..flags = flags
      ..gradientColor = gradientColor
      ..animationId = 0;
    data.ref
      ..attribute = _wcaAccentPolicy
      ..data = accent
      ..dataSize = sizeOf<_AccentPolicy>();
    _setWindowCompositionAttribute!(hwnd, data);
  } catch (e, st) {
    _log.warning('enableAcrylic failed: $e', e, st);
  } finally {
    malloc.free(accent);
    malloc.free(data);
  }
}
