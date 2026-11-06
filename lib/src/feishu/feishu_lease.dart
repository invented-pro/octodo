// The connection lease (multi-instance): Feishu's long-connection
// gateway load-balances events across every live connection of the
// same app — with two octodo instances connected, each incoming
// message lands on a random one. Only one instance may therefore
// hold the connection; the rest stand by and take over when the
// holder exits or dies.
//
// The lease is a directory (exclusive mkdir is the one atomic
// primitive every platform gives us) holding a single owner file:
//
//   <userHome>/.config/Octodo/feishu/connection.lock/owner.json
//     {"pid": 1234, "heartbeat": 1762400000000}
//
//   acquire   exclusive directory create; failure means someone
//             else holds it — or it needs a stale takeover.
//   heartbeat the owner rewrites the file every few seconds while
//             leading; a fresh heartbeat from another pid = busy.
//   takeover  a readable-but-stale owner file means the holder
//             died without releasing (hard kill): delete, recreate.
//   fencing   renew writes only while the file still names us — a
//             leader that lost the lease while suspended finds a
//             foreign pid on wake and must demote, not write.
//
// File errors are swallowed: a broken lease degrades to "held by
// someone" (the safe side), never to a second connection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// This instance holds no Feishu connection because another one does.
/// [ownerPid] names the holder when it could be read (null when the
/// owner file was missing or corrupt).
class FeishuStandby {
  final int? ownerPid;

  const FeishuStandby(this.ownerPid);
}

/// The result of [FeishuConnectionLease.tryAcquire].
class FeishuLeaseAcquire {
  final bool acquired;

  /// The holder's pid when this instance lost and the owner file was
  /// readable; null when won or when the holder couldn't be read.
  final int? holderPid;

  const FeishuLeaseAcquire.won()
      : acquired = true,
        holderPid = null;

  const FeishuLeaseAcquire.lost(this.holderPid) : acquired = false;
}

/// The dart:io global `pid` — captured at top level because inside
/// the class the `pid` field shadows it.
final int _processPid = pid;

/// One acquired-or-not verdict over the connection lock directory.
class FeishuConnectionLease {
  final Directory dir;

  /// This process's pid — overridable for tests.
  final int pid;

  /// How often the holder rewrites the owner file while leading.
  final Duration heartbeatEvery;

  /// A heartbeat older than this means the holder is gone.
  final Duration staleAfter;

  Timer? _heartbeat;

  /// Called when [renew] finds the lease naming another instance —
  /// the holder must demote (stop its channel, stand by).
  void Function()? onLost;

  FeishuConnectionLease(
    this.dir, {
    int? pid,
    this.heartbeatEvery = const Duration(seconds: 3),
    this.staleAfter = const Duration(seconds: 12),
  })  : pid = pid ?? _processPid;

  factory FeishuConnectionLease.resolve({String? userHome}) {
    final home = userHome ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    return FeishuConnectionLease(
      Directory(
          p.join(home, '.config', 'Octodo', 'feishu', 'connection.lock')),
    );
  }

  File get _ownerFile => File(p.join(dir.path, 'owner.json'));

  /// Try to become the connection holder. Won → the heartbeat timer
  /// is running and the caller may connect. Lost → the result names
  /// the current holder (when known). Already ours (a second `sync`
  /// while leading) → refresh and win.
  FeishuLeaseAcquire tryAcquire() {
    final existing = _readOwner();
    if (existing != null && existing.pid == pid) {
      _writeOwner();
      startHeartbeat();
      return const FeishuLeaseAcquire.won();
    }
    if (!dir.existsSync()) return _claim();
    if (existing == null) {
      // Directory without a readable owner file: mid-write or
      // corrupt. Young → give the writer a moment; old → takeover.
      if (_dirAge() < staleAfter) {
        return const FeishuLeaseAcquire.lost(null);
      }
    } else if (_isFresh(existing)) {
      return FeishuLeaseAcquire.lost(existing.pid);
    }
    // Stale — the holder died without releasing (hard kill).
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      return FeishuLeaseAcquire.lost(existing?.pid);
    }
    return _claim();
  }

  FeishuLeaseAcquire _claim() {
    try {
      dir.parent.createSync(recursive: true);
      dir.createSync(); // exclusive — throws when someone wins the race
    } on FileSystemException {
      return FeishuLeaseAcquire.lost(_readOwner()?.pid);
    }
    _writeOwner();
    startHeartbeat();
    return const FeishuLeaseAcquire.won();
  }

  /// Refresh the heartbeat — but only while the lease still names
  /// us. Returns false (and fires [onLost]) when another instance
  /// took it over: the caller must demote.
  bool renew() {
    final existing = _readOwner();
    if (existing == null || existing.pid != pid) {
      _stopHeartbeat();
      onLost?.call();
      return false;
    }
    _writeOwner();
    return true;
  }

  /// Begin the heartbeat (holder side). [tryAcquire] starts this
  /// on a win; exposed so the integration can re-arm after syncs.
  void startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(heartbeatEvery, (_) => renew());
  }

  void stopHeartbeat() => _stopHeartbeat();

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// Give the lease up. A no-op when someone else holds it — their
  /// directory must never be touched.
  void release() {
    _stopHeartbeat();
    final existing = _readOwner();
    if (existing == null || existing.pid != pid) return;
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Ignored on purpose — the stale takeover covers it.
    }
  }

  /// The current holder's pid — a fresh foreign one, else null.
  int? inspectHolder() {
    final existing = _readOwner();
    if (existing == null || !_isFresh(existing)) return null;
    return existing.pid == pid ? null : existing.pid;
  }

  bool _isFresh(_LeaseOwner owner) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - owner.heartbeat < staleAfter.inMilliseconds;
  }

  Duration _dirAge() {
    try {
      return DateTime.now().difference(dir.statSync().modified);
    } on FileSystemException {
      return Duration.zero; // unreadable → treat as young (held)
    }
  }

  _LeaseOwner? _readOwner() {
    try {
      final decoded = jsonDecode(_ownerFile.readAsStringSync());
      if (decoded is! Map) return null;
      final ownerPid = decoded['pid'];
      final heartbeat = decoded['heartbeat'];
      if (ownerPid is! int || heartbeat is! int) return null;
      return _LeaseOwner(ownerPid, heartbeat);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void _writeOwner() {
    try {
      dir.createSync(recursive: true); // if a takeover removed it
      _ownerFile.writeAsStringSync(
        jsonEncode({
          'pid': pid,
          'heartbeat': DateTime.now().millisecondsSinceEpoch,
        }),
        flush: true,
      );
    } on FileSystemException {
      // Ignored on purpose — staleness and fencing handle the fallout.
    }
  }
}

class _LeaseOwner {
  final int pid;
  final int heartbeat;

  const _LeaseOwner(this.pid, this.heartbeat);
}
