// The settings runtime — a single bundle passed to the settings
// UI containing the catalog, the store, and host callbacks.

import 'settings_catalog.dart';
import 'json_settings_store.dart';
import 'settings_store.dart';

/// Host-side callbacks. The settings UI calls these for things
/// that need to reach outside the settings window (reveal a file
/// in Explorer, restart the app, etc.).
class SettingsHostActions {
  /// Reveal [filePath] in the OS file manager (Explorer on Windows).
  final void Function(String filePath) revealInFileManager;

  /// Open [filePath] in the default text editor.
  final void Function(String filePath) openInExternalEditor;

  /// Restart the app (e.g. after a destructive reset).
  final void Function() restartApp;

  const SettingsHostActions({
    required this.revealInFileManager,
    required this.openInExternalEditor,
    required this.restartApp,
  });
}

class SettingsRuntime {
  final SettingsCatalog catalog;

  /// Typed as [SettingsStore] so callers can substitute fakes in
  /// tests without the isolate-backed [JsonSettingsStore]. The
  /// settings UI casts back to [JsonSettingsStore] only where it
  /// needs the file path (`runtime.store.path`).
  final SettingsStore store;
  final SettingsHostActions hostActions;

  SettingsRuntime._({
    required this.catalog,
    required this.store,
    required this.hostActions,
  });

  /// Build the runtime from a single [SettingsStore] plus host
  /// callbacks. Production callers pass a [JsonSettingsStore];
  /// tests can pass a lightweight in-memory implementation.
  factory SettingsRuntime.create({
    required SettingsStore store,
    required SettingsHostActions hostActions,
    SettingsCatalog? catalog,
  }) {
    return SettingsRuntime._(
      catalog: catalog ?? SettingsCatalog(),
      store: store,
      hostActions: hostActions,
    );
  }

  /// Process-wide singleton. Set this once at app start; the
  /// rest of the app reads it via [SettingsRuntime.instance].
  static SettingsRuntime? _instance;
  static SettingsRuntime get instance {
    assert(_instance != null,
        'SettingsRuntime.instance accessed before initialization');
    return _instance!;
  }
  static set instance(SettingsRuntime? value) => _instance = value;
}