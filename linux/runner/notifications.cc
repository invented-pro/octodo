#include "notifications.h"

#include <gio/gdesktopappinfo.h>
#include <gio/gio.h>

#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "octodo/notifications";
constexpr char kNotifyName[] = "org.freedesktop.Notifications";
constexpr char kNotifyPath[] = "/org/freedesktop/Notifications";
constexpr char kNotifyInterface[] = "org.freedesktop.Notifications";
constexpr char kAppName[] = "Octodo";

// Hint for the shell to resolve display name + icon from an
// installed .desktop file. Only sent when such a file actually
// resolves — GNOME otherwise displays the raw id string as the
// notification's app name instead of falling back to the friendlier
// app_name argument. Tri-state: -1 not yet probed, 0 absent, 1
// present. EnsureDesktopEntry() (called at register time) makes it
// resolve out of the box even for unpackaged dev builds.
constexpr char kDesktopEntry[] = APPLICATION_ID;
gint g_desktop_entry_ok = -1;

FlMethodChannel* g_channel = nullptr;
GtkWindow* g_window = nullptr;
GDBusProxy* g_proxy = nullptr;
bool g_markup = false;  // server advertised "body-markup"
bool g_dbus_dead_logged = false;

// Dart notification id (owned gchar*) → native id (GUINT_TO_POINTER).
// Reverse direction kept separately so signals (native ids only) can
// be mapped back without a linear scan.
GHashTable* g_dart_to_native = nullptr;
GHashTable* g_native_to_dart = nullptr;

void LogDbusDead(const char* what) {
  if (g_dbus_dead_logged) return;
  g_dbus_dead_logged = true;
  g_warning("[octodo.notifications] %s: no session-bus notification "
            "daemon; desktop notifications disabled",
            what);
}

// ── Value helpers ─────────────────────────────────────────────────

const gchar* ArgString(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* v = fl_value_lookup_string(args, key);  // borrowed
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) {
    return "";
  }
  return fl_value_get_string(v);
}

int ArgInt(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return 0;
  }
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_INT) {
    return 0;
  }
  return static_cast<int>(fl_value_get_int(v));
}

void RespondSuccess(FlMethodCall* call) {
  gboolean ok = fl_method_call_respond_success(call, nullptr, nullptr);
  (void)ok;
}

// ── Id mapping ─────────────────────────────────────────────────────

guint32 NativeIdFor(const std::string& dart_id) {
  gpointer v = g_hash_table_lookup(g_dart_to_native, dart_id.c_str());
  return GPOINTER_TO_UINT(v);
}

const gchar* DartIdFor(guint32 native) {
  return static_cast<const gchar*>(
      g_hash_table_lookup(g_native_to_dart, GUINT_TO_POINTER(native)));
}

void RememberId(const std::string& dart_id, guint32 native) {
  // 0 means "no notification" in the spec and is never a usable id.
  if (native == 0) return;
  const guint32 old = NativeIdFor(dart_id);
  if (old != 0 && old != native) {
    g_hash_table_remove(g_native_to_dart, GUINT_TO_POINTER(old));
  }
  g_hash_table_replace(g_dart_to_native, g_strdup(dart_id.c_str()),
                       GUINT_TO_POINTER(native));
  g_hash_table_replace(g_native_to_dart, GUINT_TO_POINTER(native),
                       g_strdup(dart_id.c_str()));
}

void ForgetNativeId(guint32 native) {
  gpointer key = GUINT_TO_POINTER(native);
  const gchar* dart = DartIdFor(native);
  if (dart == nullptr) return;
  gchar* dart_copy = g_strdup(dart);
  g_hash_table_remove(g_native_to_dart, key);
  // Only drop the forward entry if it still points at this native id
  // (a later Notify for the same Dart id may already have replaced it).
  if (NativeIdFor(dart_copy) == native) {
    g_hash_table_remove(g_dart_to_native, dart_copy);
  }
  g_free(dart_copy);
}

// ── Dart callbacks ────────────────────────────────────────────────

void InvokeDart(const char* method, const gchar* dart_id) {
  if (g_channel == nullptr) return;
  FlValue* args = fl_value_new_map();
  fl_value_set_string_take(args, "id", fl_value_new_string(dart_id));
  fl_method_channel_invoke_method(g_channel, method, args, nullptr,
                                  nullptr, nullptr);
}

// ── Markup escaping ───────────────────────────────────────────────

// Both major shells advertise "body-markup" and interpret body text
// as (a subset of) HTML markup — terminal output like "<foo>" would
// be silently eaten. Escape the three significant characters.
// Against a server WITHOUT the capability escaped entities would
// render literally ("&lt;"), hence the capability gate.
std::string EscapeMarkup(const std::string& in) {
  std::string out;
  out.reserve(in.size());
  for (char c : in) {
    switch (c) {
      case '&':
        out += "&amp;";
        break;
      case '<':
        out += "&lt;";
        break;
      case '>':
        out += "&gt;";
        break;
      default:
        out += c;
    }
  }
  return out;
}

// ── Desktop-entry resolution ──────────────────────────────────────

// Best-effort registration of <APPLICATION_ID>.desktop in
// ~/.local/share/applications, mirroring the Windows runner's
// EnsureAumidShortcut: dev builds have no installer to register one,
// and without a resolvable desktop file GNOME cannot attribute
// notifications to Octodo (name + icon). Rewritten only when the
// running executable moves (Debug ↔ Release trees); failures are
// logged once and never block startup.
void EnsureDesktopEntry() {
  gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return;
  gchar* exe_dir = g_path_get_dirname(exe);
  // The bundle ships the app icon at a fixed offset from the binary
  // (data/flutter_assets/assets/logo.png — same layout for flutter
  // run and built bundles). Absolute-path Icon= entries are honored
  // by GNOME when no themed icon matches.
  gchar* icon =
      g_build_filename(exe_dir, "data", "flutter_assets", "assets",
                       "logo.png", nullptr);
  gchar* contents = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=Octodo\n"
      "Comment=Terminal complex — workspaces, splits, tabs\n"
      "Exec=%s\n"
      "Icon=%s\n"
      "Terminal=false\n"
      "Categories=System;TerminalEmulator;\n"
      "StartupWMClass=%s\n",
      exe, icon, kDesktopEntry);

  gchar* desktop_file = g_strdup_printf("%s.desktop", kDesktopEntry);
  gchar* path =
      g_build_filename(g_get_user_data_dir(), "applications", desktop_file,
                       nullptr);
  g_free(desktop_file);

  // Skip the write when the entry already points at this executable —
  // rewriting on every launch would churn mtimes for nothing.
  gchar* existing = nullptr;
  if (g_file_get_contents(path, &existing, nullptr, nullptr) &&
      g_strstr_len(existing, -1, exe) != nullptr) {
    g_free(existing);
    g_free(contents);
    g_free(path);
    g_free(icon);
    g_free(exe_dir);
    g_free(exe);
    return;
  }
  g_free(existing);

  GError* error = nullptr;
  if (!g_file_set_contents(path, contents, -1, &error)) {
    g_warning("[octodo.notifications] desktop entry: %s", error->message);
    g_error_free(error);
  }
  g_free(contents);
  g_free(path);
  g_free(icon);
  g_free(exe_dir);
  g_free(exe);
}

// True when a "<APPLICATION_ID>.desktop" file exists in the standard
// locations (~/.local/share/applications, $XDG_DATA_DIRS). Probed
// once; g_desktop_app_info_new() does exactly the lookup the shells
// perform for the desktop-entry hint.
bool DesktopEntryResolvable() {
  if (g_desktop_entry_ok < 0) {
    gchar* desktop_id = g_strdup_printf("%s.desktop", kDesktopEntry);
    GDesktopAppInfo* info = g_desktop_app_info_new(desktop_id);
    g_desktop_entry_ok = info != nullptr ? 1 : 0;
    if (info != nullptr) g_object_unref(info);
    g_free(desktop_id);
  }
  return g_desktop_entry_ok == 1;
}

// ── D-Bus calls ───────────────────────────────────────────────────

void NotifyFinished(GObject* source, GAsyncResult* result,
                    gpointer user_data) {
  // user_data = heap std::string (the Dart id that was shown).
  std::string* dart_id = static_cast<std::string*>(user_data);
  GError* error = nullptr;
  GVariant* reply = g_dbus_proxy_call_finish(G_DBUS_PROXY(source), result,
                                             &error);
  if (reply == nullptr) {
    LogDbusDead(error->message);
    g_error_free(error);
    delete dart_id;
    return;
  }
  guint32 native = 0;
  g_variant_get(reply, "(u)", &native);
  g_variant_unref(reply);
  RememberId(*dart_id, native);
  delete dart_id;
}

void Show(const std::string& id, const std::string& title,
          const std::string& body) {
  if (id.empty() || g_proxy == nullptr) return;
  const std::string summary = g_markup ? EscapeMarkup(title) : title;
  const std::string text = g_markup ? EscapeMarkup(body) : body;

  GVariantBuilder actions;
  g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
  // The "default" action is invoked when the body is clicked; its
  // label is ignored by both GNOME and KDE.
  g_variant_builder_add(&actions, "s", "default");
  g_variant_builder_add(&actions, "s", "");

  GVariantBuilder hints;
  g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
  if (DesktopEntryResolvable()) {
    g_variant_builder_add(&hints, "{sv}", "desktop-entry",
                          g_variant_new_string(kDesktopEntry));
  }

  // replaces_id: same Dart id re-alerts replace the previous entry.
  // expire -1: server default (GNOME enforces its own policy anyway).
  g_dbus_proxy_call(
      g_proxy, "Notify",
      g_variant_new("(susssasa{sv}i)", kAppName, NativeIdFor(id), "",
                    summary.c_str(), text.c_str(), &actions, &hints, -1),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, NotifyFinished,
      new std::string(id));
}

void CloseFinished(GObject* source, GAsyncResult* result,
                   gpointer user_data) {
  // user_data = the native id, for nothing — mapping cleanup happens
  // in the NotificationClosed signal (reason 3). Just drain errors.
  (void)user_data;
  GError* error = nullptr;
  GVariant* reply =
      g_dbus_proxy_call_finish(G_DBUS_PROXY(source), result, &error);
  if (reply == nullptr) {
    LogDbusDead(error->message);
    g_error_free(error);
    return;
  }
  g_variant_unref(reply);
}

void Dismiss(const std::string& id) {
  if (id.empty() || g_proxy == nullptr) return;
  const guint32 native = NativeIdFor(id);
  if (native == 0) return;  // never delivered, or already gone
  g_dbus_proxy_call(g_proxy, "CloseNotification",
                    g_variant_new("(u)", native), G_DBUS_CALL_FLAGS_NONE,
                    -1, nullptr, CloseFinished, nullptr);
}

void CapabilitiesFinished(GObject* source, GAsyncResult* result,
                          gpointer user_data) {
  (void)user_data;
  GError* error = nullptr;
  GVariant* reply =
      g_dbus_proxy_call_finish(G_DBUS_PROXY(source), result, &error);
  if (reply == nullptr) {
    LogDbusDead(error->message);
    g_error_free(error);
    return;
  }
  GVariant* caps = g_variant_get_child_value(reply, 0);
  GVariantIter iter;
  const gchar* cap = nullptr;
  g_variant_iter_init(&iter, caps);
  // g_variant_iter_loop("s") hands out borrowed strings — only
  // compared inside the loop, never stored.
  while (g_variant_iter_loop(&iter, "s", &cap)) {
    if (g_strcmp0(cap, "body-markup") == 0) g_markup = true;
  }
  g_variant_unref(caps);
  g_variant_unref(reply);
}

// ── D-Bus signals ─────────────────────────────────────────────────

void OnSignal(GDBusProxy* proxy, const gchar* sender_name,
              const gchar* signal_name, GVariant* parameters,
              gpointer user_data) {
  (void)proxy;
  (void)sender_name;
  (void)user_data;
  if (g_strcmp0(signal_name, "ActionInvoked") == 0) {
    guint32 native = 0;
    const gchar* action = nullptr;
    g_variant_get(parameters, "(u&s)", &native, &action);
    if (g_strcmp0(action, "default") != 0) return;
    const gchar* dart = DartIdFor(native);
    if (dart == nullptr) return;
    // The user clicked — raising the window is permitted.
    if (g_window != nullptr) gtk_window_present(g_window);
    InvokeDart("onActivation", dart);
    return;
  }
  if (g_strcmp0(signal_name, "NotificationClosed") == 0) {
    guint32 native = 0, reason = 0;
    g_variant_get(parameters, "(uu)", &native, &reason);
    const gchar* dart = DartIdFor(native);
    if (dart == nullptr) return;
    // Reason 1 (expired): the banner timed out but the history entry
    // persists — keep the mapping so a later `dismiss` (markRead)
    // can still withdraw it. Reason 2: user dismissed → onDismissed
    // (copy the id before Forget frees it). Reasons 3/4: forget
    // silently (3 is our own CloseNotification — feeding it back to
    // Dart would loop markRead → dismiss → onDismissed).
    if (reason == 2) {
      gchar* dart_copy = g_strdup(dart);
      ForgetNativeId(native);
      InvokeDart("onDismissed", dart_copy);
      g_free(dart_copy);
    } else if (reason != 1) {
      ForgetNativeId(native);
    }
  }
}

// ── Non-D-Bus methods ─────────────────────────────────────────────

void SetBadge(int count) {
  if (g_window == nullptr) return;
  gtk_window_set_urgency_hint(g_window, count > 0);
}

void ActivateApp() {
  if (g_window != nullptr) gtk_window_present(g_window);
}

void OpenSettings() {
  // DE-sniffed candidate order; the other DE's launcher is appended
  // as a fallback so e.g. a GNOME app running under Plasma still
  // lands somewhere useful. Best-effort: first spawn that succeeds
  // wins, failures are logged once.
  const gchar* desktop = g_getenv("XDG_CURRENT_DESKTOP");
  const std::string d = desktop != nullptr ? desktop : "";
  const bool kde = d.find("KDE") != std::string::npos;
  const bool gnome = d.find("GNOME") != std::string::npos;

  std::vector<std::vector<std::string>> candidates;
  if (gnome || !kde) {
    candidates.push_back({"gnome-control-center", "notifications"});
  }
  if (kde || !gnome) {
    // Plasma 6 renamed systemsettings5 → systemsettings.
    candidates.push_back({"systemsettings", "kcm_notifications"});
    candidates.push_back({"systemsettings5", "kcm_notifications"});
  }

  for (const auto& candidate : candidates) {
    std::vector<char*> argv;
    for (const std::string& arg : candidate) {
      argv.push_back(const_cast<char*>(arg.c_str()));
    }
    argv.push_back(nullptr);
    GError* error = nullptr;
    if (g_spawn_async(nullptr, argv.data(), nullptr, G_SPAWN_SEARCH_PATH,
                      nullptr, nullptr, nullptr, &error)) {
      return;
    }
    g_error_free(error);
  }
  g_warning("[octodo.notifications] failed to open notification settings");
}

// ── Method channel ────────────────────────────────────────────────

void MethodCallCb(FlMethodChannel* channel, FlMethodCall* call,
                  gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);  // borrowed

  if (g_strcmp0(method, "requestAuth") == 0) {
    // No runtime grant on Linux — per-app toggles live in the shell
    // settings (see OpenSettings).
    RespondSuccess(call);
  } else if (g_strcmp0(method, "show") == 0) {
    Show(ArgString(args, "id"), ArgString(args, "title"),
         ArgString(args, "body"));
    RespondSuccess(call);
  } else if (g_strcmp0(method, "dismiss") == 0) {
    Dismiss(ArgString(args, "id"));
    RespondSuccess(call);
  } else if (g_strcmp0(method, "setBadge") == 0) {
    SetBadge(ArgInt(args, "count"));
    RespondSuccess(call);
  } else if (g_strcmp0(method, "activate") == 0) {
    ActivateApp();
    RespondSuccess(call);
  } else if (g_strcmp0(method, "openSettings") == 0) {
    OpenSettings();
    RespondSuccess(call);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

void ProxyReady(GObject* source, GAsyncResult* result, gpointer user_data) {
  (void)source;
  (void)user_data;
  GError* error = nullptr;
  g_proxy = g_dbus_proxy_new_for_bus_finish(result, &error);
  if (g_proxy == nullptr) {
    LogDbusDead(error->message);
    g_error_free(error);
    return;
  }
  g_signal_connect(g_proxy, "g-signal", G_CALLBACK(OnSignal), nullptr);
  g_dbus_proxy_call(g_proxy, "GetCapabilities", nullptr,
                    G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
                    CapabilitiesFinished, nullptr);
}

}  // namespace

void octodo_notifications_register(FlEngine* engine, GtkWindow* window) {
  g_window = window;
  // Register the .desktop identity before anything can need it (the
  // desktop-entry hint probe caches its result on first Show).
  EnsureDesktopEntry();
  g_dart_to_native =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, nullptr);
  g_native_to_dart =
      g_hash_table_new_full(g_direct_hash, g_direct_equal, nullptr, g_free);

  g_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine), kChannelName,
      FL_METHOD_CODEC(fl_standard_method_codec_new()));
  fl_method_channel_set_method_call_handler(g_channel, MethodCallCb, nullptr,
                                            nullptr);

  // Async: without a session bus (headless) the finish callback gets
  // an error and every later call becomes a logged no-op.
  g_dbus_proxy_new_for_bus(G_BUS_TYPE_SESSION, G_DBUS_PROXY_FLAGS_NONE,
                           nullptr, kNotifyName, kNotifyPath, kNotifyInterface,
                           nullptr, ProxyReady, nullptr);
}
