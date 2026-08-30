// The notification routing hub — the single place where raw terminal
// "attention" events are filtered, coalesced, and fanned out to the
// in-app unread indicators and the native desktop-notification layer.
//
// Data flow (see the design doc in the PR that added this file):
//
//   TerminalView ──onAttention──▶ TerminalWorkspace ──(surfaceId)──▶
//   AppShell ──(workspaceId)──▶ NotificationHub.handle()
//
// `handle` applies, in order:
//   1. master toggle  — `notifications.enabled` off drops the event
//      entirely (no banner, no unread, no badge — the whole pipeline
//      is off).
//   2. noise filter   — iTerm2 OSC 9 *state* payloads (`4;1;6`, the
//      form that made the old snackbar feature default-off) are
//      dropped on the desktop path.
//   3. bell gate      — `terminal.bellMode == none` drops BEL events
//      (defense in depth: the engine already skips emitting them).
//   4. duration gate  — commandFinished events below
//      `notifications.minTaskSeconds` are dropped; `D` without a
//      matching `C` (no measurable duration) is dropped too.
//   5. suppression    — the event is dropped when the app window is
//      focused AND the emitting surface is the visible, selected tab
//      (cmux semantics: a visible terminal doesn't need a banner).
//   6. cooldown       — a per-surface 2 s window gates only the
//      *banner*; unread counts still accumulate so the badge reflects
//      every accepted event.
//
// While unread state exists and the app is unfocused, a 30 s re-alert
// ticker re-posts the newest banner (gated by
// `notifications.realertUntilRead`) — native banners auto-dismiss
// after a few seconds, so this is what keeps them coming back until
// the user interacts. Explicit OS-dismissal of a banner suppresses
// re-alerting for that surface until its next event.
//
// Surviving events:
//   * increment the per-surface unread count (drives the drawer tile
//     dot and the tab-chip dot via [unreadCountFor*]),
//   * append a record to the activation ring buffer (what a
//     notification click navigates to),
//   * request a desktop banner via [onDesktopNotification] (AppShell
//     routes it to DesktopNotifications.show) unless the cooldown
//     suppressed it.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../app_info.dart';
import '../log.dart';
import '../settings/settings_catalog.dart';
import '../settings/settings_store.dart';

/// What kind of attention a terminal surface is reporting.
enum AttentionKind {
  /// OSC 9 / OSC 777 desktop-notification escape sequence, emitted by
  /// an agent tool or user script (`printf '\e]777;notify;…\a'`).
  oscNotify,

  /// BEL character — the classic "needs input" nudge.
  bell,

  /// OSC 133 `D` mark — a shell command finished (with exit code and
  /// measured duration from the matching `C` mark).
  commandFinished,
}

/// Raw attention event produced by a [TerminalView] and forwarded up
/// through the workspace to the hub.
@immutable
class TerminalAttention {
  final AttentionKind kind;

  /// OSC 9/777 title (OSC 777 carries `title\0body`; OSC 9 body only).
  final String? title;

  /// OSC 9/777 body text.
  final String? body;

  /// Exit status from the OSC 133 `D;\<rc\>` mark.
  final int? exitCode;

  /// Wall time between the `C` and `D` marks. null when `D` arrived
  /// without a matching `C` (partial shell integration).
  final Duration? duration;

  const TerminalAttention({
    required this.kind,
    this.title,
    this.body,
    this.exitCode,
    this.duration,
  });
}

/// A banner the hub wants posted natively. AppShell forwards it to
/// [DesktopNotifications.show]; keeping the type separate keeps the
/// hub testable without a platform channel.
@immutable
class DesktopNotificationRequest {
  final String id;
  final String title;
  final String body;

  /// Grouping key (workspace id) — macOS Notification Center threads.
  final String? thread;
  const DesktopNotificationRequest({
    required this.id,
    required this.title,
    required this.body,
    this.thread,
  });
}

/// Ring-buffer record for click-through navigation.
@immutable
class NotificationRecord {
  final String id;
  final String workspaceId;
  final String surfaceId;
  final String display;
  final DateTime ts;
  const NotificationRecord({
    required this.id,
    required this.workspaceId,
    required this.surfaceId,
    required this.display,
    required this.ts,
  });
}

/// A persistent in-app banner. macOS and Windows both auto-dismiss
/// native banners after a few seconds (only the user-level "alerts"
/// style persists), so the hub additionally maintains one of these
/// per surface — rendered as a top-right overlay card inside the
/// Octodo window until clicked or dismissed. Coalesced: repeated
/// events for the same surface bump [count] and refresh [display]
/// instead of stacking.
@immutable
class InAppBanner {
  final String workspaceId;
  final String surfaceId;
  final String display;

  /// How many events this banner coalesces (drives the ×N chip).
  final int count;
  final DateTime ts;
  const InAppBanner({
    required this.workspaceId,
    required this.surfaceId,
    required this.display,
    required this.count,
    required this.ts,
  });
}

class _SurfaceUnread {
  int count = 0;
  String lastDisplay = '';

  /// Native notification ids delivered for this surface that are still
  /// in the OS notification center; dismissed on markRead.
  final List<String> deliveredIds = [];

  /// The most recent banner request for this surface — what the
  /// re-alert loop re-posts (same id, so the OS replaces the entry
  /// instead of stacking).
  DesktopNotificationRequest? lastRequest;

  /// Wall time of the most recent accepted event; picks which surface
  /// the re-alert loop re-posts (the newest one wins).
  DateTime lastEventAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Set when the user swiped the banner away in the OS notification
  /// UI — an explicit "stop nagging me about this" that suppresses
  /// re-alerting until the next new event arrives for the surface.
  bool realertSuppressed = false;
}

/// iTerm2 OSC 9 *state* form: `4;\<state\>[;\<progress\>]` — machine
/// state, not user-facing text. This flood is why the legacy snackbar
/// setting shipped default-off; the desktop path just drops it.
final RegExp _osc9StateForm = RegExp(r'^4;\d+(;\d+)?$');

const Duration _bannerCooldown = Duration(seconds: 2);

class NotificationHub extends ChangeNotifier {
  final SettingsStore store;
  final SettingsCatalog catalog;

  /// True when the Octodo window has focus. Refreshed by the app shell
  /// from WindowListener + lifecycle events (the underlying queries are
  /// async; the hub needs a synchronous answer).
  final bool Function() isAppFocused;

  /// True when [surfaceId] is the selected tab of the focused
  /// container of the currently displayed workspace [workspaceId].
  final bool Function(String workspaceId, String surfaceId) isSurfaceVisible;

  /// Human-readable context for a surface, e.g.
  /// `"Workspace 2 · opencode ~/octodo"`. Composed at emit time so
  /// workspace renames never go stale.
  final String Function(String workspaceId, String surfaceId)? composeDisplay;

  /// Banner requests (AppShell → `DesktopNotifications.show`).
  final void Function(DesktopNotificationRequest request)?
  onDesktopNotification;

  /// Banner withdrawals (AppShell → `DesktopNotifications.dismiss`).
  final void Function(String id)? onDismissNotification;

  final Logger _log = moduleLogger('notifications.hub');

  final Map<String, _SurfaceUnread> _unread = {};
  final Queue<NotificationRecord> _records = Queue();
  static const int _maxRecords = 20;
  int _idSeq = 0;
  final Map<String, DateTime> _lastBannerAt = {};

  /// Persistent in-app banners, keyed `'$workspaceId/$surfaceId'`.
  /// Insertion-ordered: oldest first. Updated (not stacked) when the
  /// same surface notifies again.
  final Map<String, InAppBanner> _banners = {};

  /// Re-alert cadence. 30 s keeps the banner reappearing without
  /// turning into a wall of popups; each re-post replaces the previous
  /// Notification Center entry (same identifier).
  static const Duration realertInterval = Duration(seconds: 30);

  /// Pending re-alert ticker, non-null only while there is at least
  /// one eligible unread surface and the app is unfocused.
  Timer? _realertTimer;

  NotificationHub({
    required this.store,
    required this.catalog,
    this.isAppFocused = _neverFocused,
    this.isSurfaceVisible = _neverVisible,
    this.composeDisplay,
    this.onDesktopNotification,
    this.onDismissNotification,
  });

  static bool _neverFocused() => false;
  static bool _neverVisible(String workspaceId, String surfaceId) => false;

  // ── Intake ─────────────────────────────────────────────────────

  void handle(
    String workspaceId,
    String surfaceId,
    TerminalAttention attention,
  ) {
    if (!store.get<bool>(catalog.general.desktopNotifications)) return;

    switch (attention.kind) {
      case AttentionKind.oscNotify:
        final body = attention.body ?? '';
        if (body.isEmpty) return;
        if (_osc9StateForm.hasMatch(body)) {
          _log.fine('dropping OSC 9 state-form payload "$body"');
          return;
        }
        break;
      case AttentionKind.bell:
        if (store.get<BellMode>(catalog.terminal.bellMode) == BellMode.none) {
          return;
        }
        break;
      case AttentionKind.commandFinished:
        final d = attention.duration;
        if (d == null) return;
        final minSeconds = store.get<int>(
          catalog.general.notificationMinTaskSeconds,
        );
        if (d.inSeconds < minSeconds) return;
        break;
    }

    // Suppression: the user is looking at exactly this terminal.
    if (isAppFocused() && isSurfaceVisible(workspaceId, surfaceId)) {
      _log.fine('suppressed (visible + focused): ${attention.kind}');
      return;
    }

    final display = _composeBody(workspaceId, surfaceId, attention);
    final id = 'n-${_idSeq++}';
    final now = DateTime.now();

    final entry = _unread.putIfAbsent(
      '$workspaceId/$surfaceId',
      _SurfaceUnread.new,
    );
    entry.count += 1;
    entry.lastDisplay = display;
    entry.lastEventAt = now;
    entry.realertSuppressed = false;

    _records.addLast(
      NotificationRecord(
        id: id,
        workspaceId: workspaceId,
        surfaceId: surfaceId,
        display: display,
        ts: now,
      ),
    );
    while (_records.length > _maxRecords) {
      _records.removeFirst();
    }

    // Banner — cooldown gates only the OS popup, never the unread count.
    final lastAt = _lastBannerAt[surfaceId];
    final cooledDown =
        lastAt == null || now.difference(lastAt) >= _bannerCooldown;
    if (cooledDown) {
      _lastBannerAt[surfaceId] = now;
      final request = DesktopNotificationRequest(
        id: id,
        title: kAppName,
        body: display,
        thread: workspaceId,
      );
      entry.deliveredIds.add(id);
      entry.lastRequest = request;
      onDesktopNotification?.call(request);
      // Coalesced persistent banner (native banners auto-dismiss;
      // this one stays until the user interacts with it).
      final key = '$workspaceId/$surfaceId';
      final existing = _banners.remove(key);
      _banners[key] = InAppBanner(
        workspaceId: workspaceId,
        surfaceId: surfaceId,
        display: display,
        count: (existing?.count ?? 0) + 1,
        ts: now,
      );
    }

    syncRealert();
    notifyListeners();
  }

  String _composeBody(
    String workspaceId,
    String surfaceId,
    TerminalAttention attention,
  ) {
    final context =
        composeDisplay?.call(workspaceId, surfaceId) ??
        '$workspaceId/$surfaceId';
    final result = switch (attention.kind) {
      AttentionKind.oscNotify => _resultForOsc(attention),
      AttentionKind.bell => 'bell (may need input)',
      AttentionKind.commandFinished => _resultForCommand(attention),
    };
    final text = '$context — $result';
    if (text.length <= 120) return text;
    // Cap at ~120 display chars. Back off one code unit when the cut
    // lands inside a surrogate pair so an astral-plane character
    // (emoji in an OSC 9/777 body) isn't split into a lone surrogate.
    return '${text.substring(0, _safeCut(text, 119))}…';
  }

  /// Largest cut index ≤ [cut] that doesn't split a UTF-16 surrogate
  /// pair.
  static int _safeCut(String text, int cut) {
    // A trail surrogate (0xDC00-0xDFFF) at [cut] means the char at
    // cut-1 is its lead — cutting there would orphan it.
    final unit = text.codeUnitAt(cut);
    if (unit >= 0xDC00 && unit <= 0xDFFF) return cut - 1;
    return cut;
  }

  static String _resultForOsc(TerminalAttention a) {
    final title = (a.title ?? '').trim();
    final body = (a.body ?? '').trim();
    return title.isEmpty ? body : '$title: $body';
  }

  static String _resultForCommand(TerminalAttention a) {
    final rc = a.exitCode ?? 0;
    final verb = rc == 0 ? 'task finished' : 'task failed';
    return '$verb (exit $rc, ${_formatDuration(a.duration!)})';
  }

  static String _formatDuration(Duration d) {
    if (d.inMinutes == 0) return '${d.inSeconds}s';
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return secs == 0 ? '${mins}m' : '${mins}m ${secs}s';
  }

  // ── Re-alert loop ──────────────────────────────────────────────

  /// The window focus mirror changed (app shell calls this from its
  /// WindowListener/lifecycle hooks). Regaining focus is a stop
  /// condition for re-alerting; losing it may start the loop.
  void onAppFocusChanged() => syncRealert();

  /// The user swiped the banner away in the OS notification UI.
  /// Keeps the unread state (the in-app banner and badge remain) but
  /// suppresses re-alerting for that surface until its next event.
  void onNotificationDismissed(String id) {
    for (final entry in _unread.values) {
      if (entry.deliveredIds.contains(id) || entry.lastRequest?.id == id) {
        entry.deliveredIds.remove(id);
        entry.realertSuppressed = true;
        syncRealert();
        notifyListeners();
        return;
      }
    }
  }

  /// Start or stop the periodic re-post ticker based on the current
  /// eligibility: setting on, at least one unread surface with a
  /// deliverable request that was not explicitly dismissed, and the
  /// app unfocused (a focused user sees the in-app overlay instead).
  void syncRealert() {
    final eligible =
        _realertEnabled() && _eligibleSurfaces().isNotEmpty && !isAppFocused();
    if (eligible && _realertTimer == null) {
      _realertTimer = Timer.periodic(realertInterval, (_) => _realert());
    } else if (!eligible) {
      _realertTimer?.cancel();
      _realertTimer = null;
    }
  }

  bool _realertEnabled() =>
      store.get<bool>(catalog.general.desktopNotifications) &&
      store.get<bool>(catalog.general.notificationRealertUntilRead);

  List<_SurfaceUnread> _eligibleSurfaces() => [
    for (final entry in _unread.values)
      if (!entry.realertSuppressed && entry.lastRequest != null) entry,
  ];

  /// Re-post the newest eligible surface's banner (same request id —
  /// the OS replaces the Notification Center entry and re-shows the
  /// banner). Runs on the ticker only.
  void _realert() {
    if (!_realertEnabled() || isAppFocused()) {
      syncRealert();
      return;
    }
    _SurfaceUnread? newest;
    for (final entry in _eligibleSurfaces()) {
      if (newest == null || entry.lastEventAt.isAfter(newest.lastEventAt)) {
        newest = entry;
      }
    }
    final request = newest?.lastRequest;
    if (request == null) {
      syncRealert();
      return;
    }
    onDesktopNotification?.call(request);
  }

  // ── Queries ────────────────────────────────────────────────────

  /// Persistent in-app banners (oldest first), for the top-right
  /// overlay. These exist because both macOS and Windows
  /// auto-dismiss native banners after a few seconds; the overlay
  /// is what stays on screen until the user interacts with it.
  List<InAppBanner> get banners => List.unmodifiable(_banners.values);

  int get totalUnread => _unread.values.fold(0, (sum, e) => sum + e.count);

  int unreadCountForWorkspace(String workspaceId) => _unread.entries
      .where((e) => e.key.startsWith('$workspaceId/'))
      .fold(0, (sum, e) => sum + e.value.count);

  int unreadCountForSurface(String workspaceId, String surfaceId) =>
      _unread['$workspaceId/$surfaceId']?.count ?? 0;

  /// Per-surface unread snapshot (surfaceId → count), pushed into the
  /// `Surface` models so tab chips repaint. Surface ids contain no
  /// `/`, so splitting the composite key on the first one is exact.
  Map<String, int> unreadBySurface() => {
    for (final e in _unread.entries)
      e.key.substring(e.key.indexOf('/') + 1): e.value.count,
  };

  /// Resolve a click-through record. The record is removed from the
  /// ring either way (one activation per notification).
  NotificationRecord? consumeActivation(String id) {
    for (final r in _records) {
      if (r.id == id) {
        _records.remove(r);
        return r;
      }
    }
    return null;
  }

  // ── State mutations ────────────────────────────────────────────

  /// Clear the unread state for one surface and withdraw its delivered
  /// banners from the OS notification center. Called when the surface
  /// becomes the visible focused tab, and after an activation click.
  void markRead(String workspaceId, String surfaceId) {
    final key = '$workspaceId/$surfaceId';
    _banners.remove(key);
    final entry = _unread.remove(key);
    if (entry == null) return;
    for (final id in entry.deliveredIds) {
      onDismissNotification?.call(id);
    }
    _lastBannerAt.remove(surfaceId);
    syncRealert();
    notifyListeners();
  }

  /// Drop all unread state (master toggle flipped off, or tests).
  /// Withdraws every delivered banner.
  void clearAll() {
    if (_unread.isEmpty && _banners.isEmpty) return;
    for (final entry in _unread.values) {
      for (final id in entry.deliveredIds) {
        onDismissNotification?.call(id);
      }
    }
    _unread.clear();
    _banners.clear();
    _lastBannerAt.clear();
    syncRealert();
    notifyListeners();
  }

  /// Purge state for a closed tab. Prevents badge leaks when a
  /// surface with unread notifications is closed.
  void purgeSurface(String surfaceId) {
    _SurfaceUnread? removed;
    _unread.removeWhere((key, value) {
      if (key.endsWith('/$surfaceId')) {
        removed = value;
        return true;
      }
      return false;
    });
    _lastBannerAt.remove(surfaceId);
    _records.removeWhere((r) => r.surfaceId == surfaceId);
    _banners.removeWhere((k, _) => k.endsWith('/$surfaceId'));
    if (removed != null) {
      for (final id in removed!.deliveredIds) {
        onDismissNotification?.call(id);
      }
      syncRealert();
      notifyListeners();
    }
  }

  /// Purge state for a closed workspace.
  void purgeWorkspace(String workspaceId) {
    final keys = _unread.keys
        .where((k) => k.startsWith('$workspaceId/'))
        .toList();
    if (keys.isEmpty) return;
    for (final k in keys) {
      final entry = _unread.remove(k);
      if (entry == null) continue;
      for (final id in entry.deliveredIds) {
        onDismissNotification?.call(id);
      }
    }
    _records.removeWhere((r) => r.workspaceId == workspaceId);
    _banners.removeWhere((k, _) => k.startsWith('$workspaceId/'));
    syncRealert();
    notifyListeners();
  }

  @override
  void dispose() {
    _realertTimer?.cancel();
    _realertTimer = null;
    super.dispose();
  }

  @override
  String toString() =>
      'NotificationHub(unread=${_unread.length}, total=$totalUnread)';
}
