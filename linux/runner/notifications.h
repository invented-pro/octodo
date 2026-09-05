// Native backend for the `octodo/notifications` platform channel
// (Linux). Dart-side contract:
// lib/src/notifications/desktop_notifications.dart.
//
//   show         → org.freedesktop.Notifications.Notify() over the
//                  session bus (GDBus) — the one standard both GNOME
//                  Shell and KDE Plasma implement. replaces_id = the
//                  native id previously returned for the same Dart
//                  id, so re-alerts replace the history entry instead
//                  of stacking. "default" action → body click.
//   dismiss      → CloseNotification() (withdraws from the GNOME
//                  calendar tray / KDE history)
//   setBadge     → best-effort gtk_window_set_urgency_hint: the only
//                  freedesktop-adjacent "needs attention" affordance
//                  reachable from GTK3. KDE's taskbar flashes the
//                  window; GNOME Shell ignores the hint; Wayland is
//                  a silent no-op. No cross-DE badge-count API
//                  exists (the Unity launcher counter died with
//                  Unity), so the count itself is dropped.
//   activate     → gtk_window_present() (X11: raises; Wayland:
//                  compositors refuse self-focus without an
//                  xdg-activation token, so GNOME Wayland may leave
//                  the window down — Dart-side navigation still runs)
//   requestAuth  → no-op (Linux shells don't gate notifications
//                  behind a runtime grant; per-app toggles live in
//                  the shell settings — openSettings)
//   openSettings → DE-sniffed via XDG_CURRENT_DESKTOP:
//                  gnome-control-center notifications /
//                  systemsettings kcm_notifications (+ systemsettings5
//                  fallback), other DE's list tried as a fallback
//   onActivation → ActionInvoked signal, action_key "default"
//   onDismissed  → NotificationClosed reason 2 (user dismissed).
//                  Reason 1 (expired) keeps the id mapping — the
//                  history entry lives on and a later `dismiss` must
//                  still be able to withdraw it; reasons 3/4 (our
//                  own close / unspecified) forget the mapping
//                  silently.
//
// GNOME/KDE differences are capability-gated, never sniffed: body
// text is XML-escaped only when GetCapabilities advertises
// "body-markup" (both major shells do — unescaped terminal output
// like "<foo>" would otherwise be eaten as markup), and expire
// timeouts are left at the server default (-1) because GNOME
// enforces its own ~5 s policy anyway while KDE honors the value.
//
// All D-Bus calls are async (g_dbus_proxy_call) — a hung
// notification daemon never blocks the GTK platform thread. Proxy
// and signal callbacks arrive on the main loop, which is also the
// platform thread, so they may touch the channel and the window
// directly. Without a session bus (headless) or a notification
// daemon, every call becomes a one-time-logged no-op — the in-app
// unread indicators keep working regardless.

#ifndef RUNNER_NOTIFICATIONS_H_
#define RUNNER_NOTIFICATIONS_H_

#include <gtk/gtk.h>

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// Registers the `octodo/notifications` method channel on [engine]
// and remembers [window] for activation raises / urgency badges.
// Call once after fl_register_plugins().
void octodo_notifications_register(FlEngine* engine, GtkWindow* window);

G_END_DECLS

#endif  // RUNNER_NOTIFICATIONS_H_
