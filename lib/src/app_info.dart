// App identity constants shared between the entry point and UI
// modules. Keeping these out of `main.dart` lets UI widgets
// reference the app name without importing the entry point
// (which would create a circular dependency).

import 'dart:io';

/// The display name of the application. Used for the window
/// title, dialog titles, and the badge in the settings header.
///
/// This is the *display* name and may diverge from the on-disk
/// configuration directory name (`Octodo`) without breaking
/// existing user installs.
const String kAppName = 'Octodo';

/// Public GitHub repository that hosts the source and the
/// release artifacts the in-app updater consumes. Surfaced in
/// the About / idle-state update dialog.
const String kAppRepository = 'https://github.com/invented-pro/octodo';

/// Releases page of [kAppRepository]. The About dialog's "Check
/// for updates" button points here so users land on a real
/// release timeline instead of triggering an in-app probe.
const String kAppRepositoryReleases =
    'https://github.com/invented-pro/octodo/releases';

/// Author / vendor link shown in the About body. Pure cosmetic.
const String kAppAuthorUrl = 'https://sudo8.com';

/// Bundled app-logo asset. Used in the About dialog header so the
/// brand glyph (not a generic icon) sits next to the app name.
const String kAppLogoAsset = 'assets/logo.png';

/// Microsoft Store listing for Octodo. The in-app updater opens
/// this in the user's browser when the running build is the
/// MSIX/Store distribution (updates are delivered by the Store,
/// not self-applied). Kept here so the update UI and any future
/// diagnostics reference one source of truth.
const String kAppStoreUrl = 'https://apps.microsoft.com/detail/9PJ4NR9XL3ZQ';

/// Mac App Store listing for Octodo. Empty until the manual MAS
/// submission goes live — the update UI falls back to
/// [kAppRepositoryReleases] (manual download) while it is blank.
/// Once the listing exists, fill this with the `apps.apple.com`
/// URL and the macOS Store build's "Update" button routes there.
const String kMacAppStoreUrl = '';

/// The URL the update UI should open for a Store-distribution
/// build on the CURRENT platform: the platform's store listing
/// when published, else the GitHub releases page as the manual
/// upgrade path.
String get kPlatformStoreUrl => Platform.isMacOS
    ? (kMacAppStoreUrl.isNotEmpty
        ? kMacAppStoreUrl
        : kAppRepositoryReleases)
    : kAppStoreUrl;

/// Windows AppUserModelID — the "package namespace" Win32 uses to
/// group taskbar icons, route toast notifications, and populate
/// jump lists. Passed to `SetCurrentProcessExplicitAppUserModelID`
/// (via `window_manager.setAppUserModelId`) at startup so every
/// Octodo window — including the first one — already carries the
/// identity. Reverse-DNS, distinct from the human-readable Company
/// in [windows/runner/Runner.rc], which keeps the vendor string
/// (`sudo8.com`).
const String kAppAppUserModelId = 'com.sudo8.octodo';