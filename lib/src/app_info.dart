// App identity constants shared between the entry point and UI
// modules. Keeping these out of `main.dart` lets UI widgets
// reference the app name without importing the entry point
// (which would create a circular dependency).

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

/// Windows AppUserModelID — the "package namespace" Win32 uses to
/// group taskbar icons, route toast notifications, and populate
/// jump lists. Passed to `SetCurrentProcessExplicitAppUserModelID`
/// (via `window_manager.setAppUserModelId`) at startup so every
/// Octodo window — including the first one — already carries the
/// identity. Reverse-DNS, distinct from the human-readable Company
/// in [windows/runner/Runner.rc], which keeps the vendor string
/// (`sudo8.com`).
const String kAppAppUserModelId = 'com.sudo8.octodo';