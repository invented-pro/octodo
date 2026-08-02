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

/// Enable native acrylic (frosted-glass) blur behind the window [title].
///
/// [tint] is the acrylic overlay color (normally the active palette's
/// `surface0`) and [alpha] (0.0–1.0) its strength: 0 = pure blur of the
/// desktop with no tint, 1 = fully opaque tint. The blur radius itself
/// is fixed by the OS (the Win32 acrylic API exposes no sigma), so the
/// frost slider maps to tint alpha.
///
/// No-op on non-Windows or if the symbols can't be resolved.
void enableAcrylic({required String title, required Color tint, required double alpha}) {
  _resolve();
  final set = _setWindowCompositionAttribute;
  if (set == null) return;
  final hwnd = _findMainWindow(title);
  if (hwnd == 0) {
    _log.warning('enableAcrylic: window "$title" not found');
    return;
  }
  final a = (alpha.clamp(0.0, 1.0) * 255).round() & 0xFF;
  final r = (tint.r * 255).round() & 0xFF;
  final g = (tint.g * 255).round() & 0xFF;
  final b = (tint.b * 255).round() & 0xFF;
  // Win32 composition colors are ABGR, not ARGB.
  final abgr = (a << 24) | (b << 16) | (g << 8) | r;

  final accent = malloc<_AccentPolicy>();
  final data = malloc<_WinCompAttrData>();
  try {
    accent.ref
      ..accentState = _accentEnableAcrylicBlurBehind
      ..flags = 2
      ..gradientColor = abgr
      ..animationId = 0;
    data.ref
      ..attribute = _wcaAccentPolicy
      ..data = accent
      ..dataSize = sizeOf<_AccentPolicy>();
    set(hwnd, data);
  } catch (e, st) {
    _log.warning('enableAcrylic failed: $e', e, st);
  } finally {
    malloc.free(accent);
    malloc.free(data);
  }
}
