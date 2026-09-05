// Dart side of the `octodo/notifications` platform channel.
//
// Method surface (Dart → native):
//   * requestAuth — macOS UNUserNotificationCenter authorization
//     (no-op elsewhere; Windows and Linux need no runtime grant).
//   * show { id, title, body, thread } — post a native desktop
//     notification. `thread` groups notifications in Notification
//     Center (macOS threadIdentifier = workspace id); Windows and
//     Linux stack (freedesktop has no cross-DE grouping standard).
//   * dismiss { id } — remove a delivered notification from
//     Notification Center / Action Center / the shell's history.
//   * setBadge { count } — macOS dock badge label (capped "99+");
//     Windows taskbar overlay dot; Linux best-effort X11 urgency
//     hint (no cross-DE badge-count API exists).
//   * activate — bring the app window to the foreground (used right
//     after a notification click before Dart-side navigation).
//
// Native → Dart:
//   * onActivation { id } — the user clicked a native notification.
//   * onDismissed { id } — the user swiped a native banner away
//     (macOS via a `customDismissAction` notification category;
//     Linux via the freedesktop NotificationClosed reason-2 signal;
//     Windows toasts don't report plain dismissals).
//
// Every Dart→native call is best-effort: in `flutter test` the
// channel has no handler and [MissingPluginException] is swallowed
// — in-app unread indicators keep working everywhere regardless.

import 'dart:async';

import 'package:flutter/services.dart';

import '../log.dart';

class DesktopNotifications {
  static const MethodChannel _channel = MethodChannel('octodo/notifications');

  /// Channel backplane for the activation callback. The platform
  /// channel is app-global, so the handler slot is too — a second
  /// instance (e.g. the settings dialog) must never clobber the
  /// app shell's `onActivation`.
  static void Function(String id)? _activationHandler;
  static void Function(String id)? _dismissedHandler;
  static bool _handlerInstalled = false;

  /// Invoked with the notification id when the user clicks a native
  /// notification. Set by the app shell before any notification can
  /// fire; the native side dispatches to the main thread before
  /// invoking, so this always runs on the UI isolate's turn.
  ///
  /// Backed by a static because the platform channel allows exactly
  /// one method-call handler — a second instance (the settings
  /// dialog calls [openSystemSettings]) must never shadow the app
  /// shell's callback.
  void Function(String id)? get onActivation => _activationHandler;

  set onActivation(void Function(String id)? handler) {
    if (_activationHandler != null && handler != null) {
      _log.fine('onActivation handler replaced');
    }
    _activationHandler = handler;
  }

  /// Invoked with the notification id when the user dismisses (swipes
  /// away) a native banner without clicking it. Static backplane for
  /// the same reason as [onActivation].
  void Function(String id)? get onDismissed => _dismissedHandler;

  set onDismissed(void Function(String id)? handler) {
    if (_dismissedHandler != null && handler != null) {
      _log.fine('onDismissed handler replaced');
    }
    _dismissedHandler = handler;
  }

  bool _initialized = false;

  final Logger _log = moduleLogger('notifications.desktop');

  /// Install the method-call handler. Idempotent (and cheap enough
  /// that every entry point calls it defensively).
  void initialize() {
    if (_initialized) return;
    _initialized = true;
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onActivation':
          final id = (call.arguments as Map?)?['id'] as String?;
          if (id != null) _activationHandler?.call(id);
          return null;
        case 'onDismissed':
          final id = (call.arguments as Map?)?['id'] as String?;
          if (id != null) _dismissedHandler?.call(id);
          return null;
      }
      return null;
    });
  }

  /// macOS only: request notification authorization. Safe to call on
  /// every platform / repeatedly (native side no-ops when already
  /// granted). Denied → the native side logs and in-app indicators
  /// remain the only channel; no permission-status UI is surfaced.
  Future<void> requestAuthorization() => _invoke('requestAuth');

  /// Post a desktop notification. [thread] groups per workspace on
  /// macOS (Notification Center threads); ignored on Windows/Linux.
  Future<void> show({
    required String id,
    required String title,
    required String body,
    String? thread,
  }) => _invoke('show', {
    'id': id,
    'title': title,
    'body': body,
    'thread': thread,
  });

  /// Remove a delivered notification from the OS notification center.
  Future<void> dismiss(String id) => _invoke('dismiss', {'id': id});

  /// Set the native badge: macOS dock label (count, capped at "99+"),
  /// Windows taskbar overlay dot (presence only), Linux best-effort
  /// X11 urgency hint (KDE taskbar flashes; GNOME ignores it; no
  /// cross-DE badge-count API exists).
  Future<void> setBadge(int count) => _invoke('setBadge', {'count': count});

  /// Bring the app to the foreground (macOS: activate + makeKey;
  /// Windows: restore + SetForegroundWindow). The native activation
  /// handler already does this on click; the method stays in the
  /// surface for completeness / future callers.
  Future<void> activateApp() => _invoke('activate');

  /// Open the OS notification-settings pane for this machine (macOS:
  /// System Settings → Notifications; Windows: modern Settings →
  /// notifications). Used by the settings UI so users can switch
  /// Octodo to persistent "Alerts"-style banners — the only way
  /// native banners stay until dismissed.
  Future<void> openSystemSettings() => _invoke('openSettings');

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    initialize();
    try {
      await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      // Linux (no runner) / unit tests — expected, stay silent.
    } catch (e) {
      _log.warning('$method failed: $e');
    }
  }
}
