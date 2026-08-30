// Native backend for the `octodo/notifications` platform channel
// (macOS). Dart-side contract: lib/src/notifications/desktop_notifications.dart.
//
//   requestAuth  → UNUserNotificationCenter authorization (alert/badge/sound)
//   show         → UNUserNotificationCenter banner; identifier = the Dart
//                  notification id; threadIdentifier = workspace id so
//                  Notification Center groups per workspace. Also
//                  requests dock attention (bouncing until the user
//                  activates Octodo) whenever a banner is posted while
//                  the app is not frontmost.
//   dismiss      → removeDeliveredNotifications (read-clears-OS)
//   setBadge     → NSDockTile.badgeLabel ("99+"-capped count, nil at 0)
//   activate     → NSApp.activate + makeKeyAndOrderFront (legal focus
//                  steal: only invoked from a user click)
//   onActivation → Dart callback with the notification id (delegate
//                  didReceive response — user clicked)
//   onDismissed  → Dart callback with the notification id (delegate
//                  didReceive UNNotificationDismissActionIdentifier —
//                  user swiped the banner away; enabled by the
//                  customDismissAction category registered in attach)
//
// Banners are shown even while the app is frontmost (willPresent
// returns .banner/.list/.sound): the Dart-side suppression already
// dropped notifications for the surface the user is looking at, so
// anything that reaches the native layer is worth showing — e.g. an
// event from a background tab while the user works in another one.
//
// UNUserNotificationCenter requires a bundled app; a bare executable
// (some test harnesses) makes every call a logged no-op. Delegate
// callbacks and channel invocations are dispatched to the main thread.

import Cocoa
import FlutterMacOS
import UserNotifications

final class OctodoNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = OctodoNotifications()

  /// Category id used for every banner Octodo posts. Registered in
  /// `attach` with `customDismissAction` so swiping a banner away is
  /// reported to the delegate (→ Dart `onDismissed`), letting the
  /// re-alert loop stop for that notification.
  static let categoryIdentifier = "octodo.notification"

  private var channel: FlutterMethodChannel?

  /// Activation ids received before Dart signaled liveness (a click on
  /// a Notification Center leftover during cold start). Flushed on the
  /// first method call from Dart.
  private var pendingActivations: [String] = []

  /// Same cold-start buffer, but for explicit user dismissals.
  private var pendingDismissals: [String] = []
  private var dartSeen = false

  /// Active `NSApp.requestUserAttention` token, nil while none is
  /// pending. Cancelled as soon as the app becomes active — the dock
  /// bounce is "come look at me", not a permanent state.
  private var attentionRequest: Int?

  private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

  func attach(to controller: FlutterViewController) {
    channel = FlutterMethodChannel(
      name: "octodo/notifications",
      binaryMessenger: controller.engine.binaryMessenger,
    )
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      self.handle(call: call, result: result)
    }
    if isBundled {
      // Set the delegate early so a launch-by-notification-click is
      // delivered to us instead of being lost before Dart is up (the
      // id lands in pendingActivations and replays once Dart lives).
      UNUserNotificationCenter.current().delegate = self
      // Report banner swipe-aways to the delegate (see
      // categoryIdentifier). Replaces silently-vanishing banners.
      UNUserNotificationCenter.current().setNotificationCategories([
        UNNotificationCategory(
          identifier: Self.categoryIdentifier,
          actions: [],
          intentIdentifiers: [],
          options: [.customDismissAction]
        )
      ])
      // Dock bounce ends the moment the user switches to Octodo.
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidBecomeActive),
        name: NSApplication.didBecomeActiveNotification,
        object: nil
      )
    }
  }

  @objc private func appDidBecomeActive() {
    if let request = attentionRequest {
      NSApp.cancelUserAttentionRequest(request)
      attentionRequest = nil
    }
  }

  // MARK: - Channel handling

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    // Any call proves the Dart side is mounted — replay early clicks.
    flushPendingActivations()
    switch call.method {
    case "requestAuth":
      requestAuthorization { result(nil) }
    case "show":
      show(
        id: args["id"] as? String ?? "",
        title: args["title"] as? String ?? "",
        body: args["body"] as? String ?? "",
        thread: args["thread"] as? String
      )
      result(nil)
    case "dismiss":
      dismiss(id: args["id"] as? String ?? "")
      result(nil)
    case "setBadge":
      setBadge(count: args["count"] as? Int ?? 0)
      result(nil)
    case "activate":
      activateApp()
      result(nil)
    case "openSettings":
      openNotificationSettings()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Implementation

  private func requestAuthorization(_ done: @escaping () -> Void) {
    guard isBundled else {
      done()
      return
    }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
      granted, error in
      if let error {
        NSLog("[octodo.notifications] authorization: \(error.localizedDescription)")
      } else if !granted {
        NSLog("[octodo.notifications] authorization denied; in-app indicators only")
      }
      done()
    }
  }

  private func show(id: String, title: String, body: String, thread: String?) {
    guard isBundled, !id.isEmpty else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = Self.categoryIdentifier
    if let thread, !thread.isEmpty {
      content.threadIdentifier = thread
    }
    let request = UNNotificationRequest(
      identifier: id,
      content: content,
      trigger: nil  // deliver immediately
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        NSLog("[octodo.notifications] add failed: \(error.localizedDescription)")
      }
    }
    // While Octodo is backgrounded, also bounce the dock icon until
    // the user switches over — the standard macOS "needs attention"
    // affordance, and the only fully app-controllable one (banner
    // persistence itself is a user-level "Alerts" style choice).
    DispatchQueue.main.async { [weak self] in
      guard let self, !NSApp.isActive, self.attentionRequest == nil else {
        return
      }
      self.attentionRequest = NSApp.requestUserAttention(.criticalRequest)
    }
  }

  private func dismiss(id: String) {
    guard isBundled, !id.isEmpty else { return }
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
  }

  private func setBadge(count: Int) {
    // Dock tile is main-thread only.
    DispatchQueue.main.async {
      if count <= 0 {
        NSApplication.shared.dockTile.badgeLabel = nil
      } else {
        NSApplication.shared.dockTile.badgeLabel = count > 99 ? "99+" : String(count)
      }
    }
  }

  private func activateApp() {
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      // Prefer the live key window; fall back to the first window
      // (single-window app — that IS the Octodo window).
      let window = NSApp.keyWindow ?? NSApp.windows.first
      window?.makeKeyAndOrderFront(nil)
    }
  }

  /// Open System Settings → Notifications so the user can switch
  /// Octodo to "Alerts" (banners that persist until dismissed —
  /// the OS has no API to force that programmatically). The
  /// per-app pane isn't directly addressable; the nearest stable
  /// destinations are tried in order.
  private func openNotificationSettings() {
    DispatchQueue.main.async {
      let candidates = [
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.notifications",
      ]
      for spec in candidates {
        if let url = URL(string: spec), NSWorkspace.shared.open(url) {
          return
        }
      }
      NSLog("[octodo.notifications] failed to open notification settings")
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  // Show banners even when Octodo is the frontmost app — see the file
  // header for why anything reaching this layer deserves display.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.identifier
    let dismissed = response.actionIdentifier ==
      UNNotificationDismissActionIdentifier
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if dismissed {
        // Swipe-away: no focus steal, no navigation — just tell Dart
        // so the re-alert loop stands down for this notification.
        if self.dartSeen, let channel {
          channel.invokeMethod("onDismissed", arguments: ["id": id])
        } else {
          self.pendingDismissals.append(id)
        }
        return
      }
      // The user clicked — raising the app is permitted.
      self.activateApp()
      if self.dartSeen, let channel {
        channel.invokeMethod("onActivation", arguments: ["id": id])
      } else {
        self.pendingActivations.append(id)
      }
    }
    completionHandler()
  }

  private func flushPendingActivations() {
    dartSeen = true
    guard let channel else { return }
    for id in pendingActivations {
      channel.invokeMethod("onActivation", arguments: ["id": id])
    }
    pendingActivations.removeAll()
    for id in pendingDismissals {
      channel.invokeMethod("onDismissed", arguments: ["id": id])
    }
    pendingDismissals.removeAll()
  }
}
