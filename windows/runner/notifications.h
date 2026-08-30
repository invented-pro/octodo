// Native backend for the `octodo/notifications` platform channel
// (Windows). Dart-side contract:
// lib/src/notifications/desktop_notifications.dart.
//
//   show         → WinRT toast (WRL COM — no C++/WinRT NuGet needed);
//                  toast Tag = the Dart notification id; the app icon
//                  comes from the AUMID Start shortcut automatically
//                  (pinned in main.cpp before the window exists)
//   dismiss      → remove from Action Center (IToastNotificationHistory)
//   setBadge     → ITaskbarList3 overlay dot (runtime-generated 16x16
//                  icon — presence only, count text is illegible at
//                  overlay size)
//   activate     → restore + SetForegroundWindow (permitted right
//                  after a toast click — a user interaction)
//   requestAuth  → no-op (Windows has no runtime grant)
//   onActivation → Dart callback with the id (in-proc
//                  IToastNotification::Activated event — valid while
//                  the process runs, which is the only time Octodo
//                  posts toasts; a click after exit is dropped, the
//                  record no longer exists anyway)
//
// Activation events arrive on a WinRT thread-pool thread; they are
// marshaled to the UI thread via a posted window message (LPARAM =
// heap std::wstring) that the runner forwards from its window
// procedure — WinRT threads must not touch the channel or the HWND.

#ifndef RUNNER_NOTIFICATIONS_H_
#define RUNNER_NOTIFICATIONS_H_

#include <windows.h>

namespace flutter {
class FlutterEngine;
}

namespace octodo {

// Registers the method channel on [engine] and remembers [hwnd] for
// taskbar overlay / activation raises. Call once after RegisterPlugins.
void RegisterNotifications(flutter::FlutterEngine* engine, HWND hwnd);

// Called from the runner's window procedure for every message.
// Returns true when [message] was the toast-activation message and
// has been fully handled (the caller should return 0). [lparam] is
// the heap-allocated id string owned by this handler.
bool HandleNotificationsWindowMessage(UINT message, LPARAM lparam);

}  // namespace octodo

#endif  // RUNNER_NOTIFICATIONS_H_
