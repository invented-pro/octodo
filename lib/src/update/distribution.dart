// Detects whether the running app is the MSIX / Microsoft Store
// build or the portable (unzipped) build. The in-app updater uses
// this to decide between the self-applied GitHub-zip flow
// (portable) and the "open the Store" flow (store).
//
// Why we need this: MSIX/Store installs land under
// `C:\Program Files\WindowsApps\…`, which is ACL-locked. The
// portable updater's `octodo_helper.exe` can't overwrite files
// there, so the download + staged-apply path is a no-op for
// Store users. Instead we route them to the Store, which owns
// the install and the update lifecycle.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The app's published MSIX identity name (from pubspec.yaml's
/// `msix_config.identity_name`). Used to confirm the package we're
/// running under is *this* app's, not some unrelated MSIX that
/// happens to be on the machine.
const String kMsixIdentityName = '43D421A8.Octodo';

/// `APPMODEL_ERROR_NO_PACKAGE` (15700) is the return code when the
/// process has no package identity (a portable exe). We treat any
/// non-zero return the same way — see [nativePackageFullName].

enum InstallDistribution {
  /// Self-contained build the user unzipped into an arbitrary
  /// directory. Updates are downloaded + applied in-place via
  /// `octodo_helper.exe`.
  portable,

  /// MSIX build installed via the Microsoft Store. Updates must
  /// flow through the Store; the in-app updater only detects +
  /// routes the user there.
  store,
}

/// Functional type for the Win32 package-identity probe.
/// Returns the package full name on success, or `null` when the
/// process has no package identity (or the platform isn't
/// Windows). Production wires [nativePackageFullName]; tests
/// inject a stub to pin the outcome.
typedef PackageFullNameProbe = String? Function();

/// Resolve the running app's distribution. Decides in priority
/// order:
///   1. [override] — tests pin the answer without hitting Win32.
///   2. [probe] (default [nativePackageFullName], Windows only) —
///      the authoritative signal: `GetCurrentPackageFullName`
///      returns a non-empty name only for processes with MSIX
///      package identity. Cross-checked against
///      [kMsixIdentityName] so a sideloaded test package from a
///      different publisher doesn't mis-route.
///   3. Path heuristic — [resolvedExecutable] lives under
///      `Program Files\WindowsApps\` (the ACL-locked MSIX install
///      root) → store. Belt-and-braces in case the Win32 call is
///      unavailable.
///   4. Default: portable.
InstallDistribution resolveInstallDistribution({
  InstallDistribution? override,
  String? resolvedExecutable,
  PackageFullNameProbe? probe,
}) {
  if (override != null) return override;
  if (!Platform.isWindows) return InstallDistribution.portable;
  final effectiveProbe = probe ?? nativePackageFullName;
  final fullName = effectiveProbe();
  if (fullName != null && fullName.isNotEmpty &&
      fullName.startsWith(kMsixIdentityName)) {
    return InstallDistribution.store;
  }
  final exe = (resolvedExecutable ?? Platform.resolvedExecutable)
      .toLowerCase();
  if (exe.contains(r'\windowsapps\')) {
    return InstallDistribution.store;
  }
  return InstallDistribution.portable;
}

/// Win32 `GetCurrentPackageFullName` binding. Returns the package
/// full name (e.g. `43D421A8.Octodo_1.0.13.0_x64__mr0as8erd2vmy`)
/// when the process has MSIX identity, otherwise `null`.
///
/// Only invoked on Windows (guarded by the resolver). Looking up
/// `kernel32.dll` on a non-Windows host throws, so this function
/// must never be called there.
String? nativePackageFullName() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getCurrentPackageFullName = kernel32.lookupFunction<
      Int32 Function(
          Pointer<Uint32> packageFullNameLength,
          Pointer<Utf16> packageFullName),
      int Function(
          Pointer<Uint32> packageFullNameLength,
          Pointer<Utf16> packageFullName)>('GetCurrentPackageFullName');
  final lengthPtr = calloc<Uint32>();
  // 1024 wide chars is well beyond any realistic package full
  // name (they top out ~130 chars). Acts as both the in/out
  // capacity hint. Allocated as Uint16 (the native wchar_t width
  // on Windows) and cast to Utf16 so the package's
  // `Pointer<Utf16>` extension methods apply.
  final namePtr = calloc<Uint16>(1024).cast<Utf16>();
  try {
    lengthPtr.value = 1024;
    final rc = getCurrentPackageFullName(lengthPtr, namePtr);
    if (rc == 0) {
      return namePtr.toDartString();
    }
    // rc == _appModelErrorNoPackage → portable exe; treat any
    // other non-zero (insufficient buffer, etc.) the same — the
    // path heuristic in the resolver is the backstop.
    return null;
  } finally {
    calloc.free(lengthPtr);
    calloc.free(namePtr);
  }
}
