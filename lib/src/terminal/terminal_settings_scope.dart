// TerminalSettings propagation via [InheritedNotifier].
//
// Before this widget existed, every settings/theme change fired a
// `setState` on [TerminalWorkspace], which rebuilt the entire pane
// tree (M panes × K tabs) just to deliver a new [TerminalSettings]
// snapshot to each [TerminalView] via its `widget.settings` prop.
// The widget allocation, layout, and paint cost was paid for every
// tab in every pane on every settings toggle, even though only the
// engine configuration actually needed to change.
//
// [TerminalSettingsScope] replaces that fan-out with an
// [InheritedNotifier]: the workspace owns one
// [TerminalSettingsNotifier] (a [ValueNotifier]<[TerminalSettings]>)
// and updates its `.value` on settings/theme changes. Each
// [TerminalView] reads the current value via
// [TerminalSettingsScope.of] inside `didChangeDependencies` and calls
// `_engine.reconfigure(...)` directly — no widget rebuild, no layout
// pass, no paint cascade.

import 'package:flutter/widgets.dart';
import 'terminal_view.dart' show TerminalSettings;

/// [ValueNotifier] that holds the workspace's current
/// [TerminalSettings]. The workspace owns exactly one instance and
/// updates its `.value` whenever a setting or the active palette
/// changes. `==` on [TerminalSettings] is value equality, so
/// `ValueNotifier` correctly skips notifications when the new value
/// is structurally identical to the previous one.
class TerminalSettingsNotifier extends ValueNotifier<TerminalSettings> {
  TerminalSettingsNotifier(super.value);
}

/// Inherited widget that exposes a [TerminalSettingsNotifier] to
/// descendants. When the notifier's value changes, every dependent's
/// `didChangeDependencies` is invoked, which is where
/// [TerminalView] reconfigures its alacritty engine.
class TerminalSettingsScope extends InheritedNotifier<TerminalSettingsNotifier> {
  const TerminalSettingsScope({
    super.key,
    required TerminalSettingsNotifier notifier,
    required super.child,
  }) : super(notifier: notifier);

  /// Returns the current [TerminalSettings] and registers a
  /// dependency so the calling widget's `didChangeDependencies` is
  /// invoked the next time the notifier's value changes.
  static TerminalSettings of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<TerminalSettingsScope>();
    assert(
      scope != null,
      'TerminalSettingsScope.of() called outside a TerminalSettingsScope. '
      'Wrap the widget tree in a TerminalSettingsScope(notifier: ...).',
    );
    return scope!.notifier!.value;
  }
}