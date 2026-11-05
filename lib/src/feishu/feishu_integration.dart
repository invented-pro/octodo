// The Feishu integration router — the app-facing brain of the
// remote-control loop (design doc §3–§5):
//
//   inbound:  event → whitelist (allowed open_ids) → dedup
//             (message_id window) → host bridge writes the command
//             into the active terminal
//   outbound: the active terminal's output, aggregated until the
//             command finishes (output gone quiet + a fresh shell
//             prompt), stripped of escape noise and the command's
//             own echo, sent back to the originating chat
//
// The host (AppShell) supplies the terminal bridge; everything else
// lives here so the routing rules are unit-testable without the UI.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../log.dart';
import 'feishu_api_client.dart';
import 'feishu_credentials.dart';
import 'feishu_event_channel.dart';
import 'feishu_ws_channel.dart';

/// What the integration needs from the app shell: where commands go
/// and where their output comes from. Implemented by `_AppShellState`.
abstract class FeishuHostBridge {
  /// Write [command] (already newline-terminated by the router)
  /// into the active workspace's focused terminal. No-op when no
  /// terminal exists.
  void runCommand(String command);

  /// Broadcast stream of the active terminal's raw PTY output, or
  /// null when there is no active terminal. The router subscribes
  /// from just before a command is written until that command's
  /// output has gone quiet.
  Stream<List<int>>? subscribeActiveOutput();
}

/// Dedup window (§4.3): remember this many message ids…
const int _kDedupCapacity = 1000;

/// …for at most this long.
const Duration _kDedupTtl = Duration(minutes: 10);

/// Output aggregation idle window (§5): after a command, this much
/// terminal silence ends the capture — but only once a fresh shell
/// prompt has appeared at the tail (see [_OutputCapture]). Every
/// output chunk restarts the wait. Injectable for tests.
const Duration _kOutputWindowDefault = Duration(milliseconds: 2500);

/// Hard ceiling on one command's capture: commands that never
/// finish (or shells whose prompt we don't recognize) still get a
/// partial reply after this long.
const Duration _kOutputMaxWindowDefault = Duration(seconds: 60);

/// …or until this many bytes arrive, whichever first.
const int _kOutputMaxBytes = 15 * 1024;

class FeishuIntegration {
  final FeishuEventChannel channel;
  final FeishuApiClient api;
  final FeishuCredentialStore credentialStore;
  final FeishuHostBridge bridge;
  final Logger _log = moduleLogger('feishu.integration');

  FeishuCredentials? _credentials;
  FeishuCredentials? get credentials => _credentials;

  bool _running = false;
  bool get isRunning => _running;

  StreamSubscription<FeishuInboundEvent>? _eventsSub;
  StreamSubscription<FeishuConnectionState>? _stateSub;

  /// Dedup cache: message id → seen-at.
  final _seen = <String, DateTime>{};

  /// Active output capture (one at a time; a new command flushes
  /// the previous capture immediately).
  _OutputCapture? _capture;

  /// Idle window that ends a command's output capture (injectable).
  final Duration outputWindow;

  /// Hard ceiling on one command's output capture (injectable).
  final Duration maxOutputWindow;

  FeishuIntegration({
    required this.bridge,
    FeishuEventChannel? channel,
    FeishuApiClient? api,
    FeishuCredentialStore? credentialStore,
    this.outputWindow = _kOutputWindowDefault,
    this.maxOutputWindow = _kOutputMaxWindowDefault,
  })  : channel = channel ?? FeishuWsChannel(),
        api = api ?? FeishuApiClient(),
        credentialStore =
            credentialStore ?? FeishuCredentialStore.resolve();

  static FeishuIntegration? _instance;

  /// Process-wide singleton (owned by AppShell in production).
  static FeishuIntegration get instance =>
      _instance ??= FeishuIntegration(bridge: _NullHostBridge());

  @visibleForTesting
  static set instanceForTesting(FeishuIntegration? value) =>
      _instance = value;

  /// Re-read credentials and (re)start or stop the channel. Called
  /// at app start, on settings/credential changes, and after a QR
  /// (un)bind. [enabled] is the `feishu.enabled` setting.
  Future<void> sync({required bool enabled}) async {
    _credentials = await credentialStore.load();
    // Decision trace: a stop/start in the field log is only
    // attributable if we can see what sync decided and why.
    _log.info('feishu: sync enabled=$enabled '
        'bound=${_credentials != null} running=$_running');
    if (!enabled || _credentials == null) {
      await _stop();
      return;
    }
    await _start();
  }

  Future<void> _start() async {
    if (_running && _credentials != null) {
      // Already running — but credentials may have changed (rebind).
      // Restart the transport if the app id differs from the running one.
      if (_boundAppId == _credentials!.appId) return;
      await _stop();
    }
    final creds = _credentials!;
    _running = true;
    _boundAppId = creds.appId;
    api.bind(creds);
    _eventsSub ??= channel.events.listen(_onEvent, onError: (_) {});
    _stateSub ??= channel.stateChanges.listen((s) {
      _log.info('feishu: ${s.name}');
    });
    await channel.start(creds);
    _log.info('feishu: integration started for ${creds.appIdPreview}');
  }

  String? _boundAppId;

  Future<void> _stop() async {
    if (!_running) return;
    _running = false;
    _boundAppId = null;
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    _capture?.flush(); // stop listening, drop pending output
    await channel.stop();
    _log.info('feishu: integration stopped');
  }

  // ── Inbound ────────────────────────────────────────────────────

  @visibleForTesting
  void handleEvent(FeishuInboundEvent event) {
    // 1. Replay gate: Feishu redelivers every event it never saw
    //    acked — on the first connection after an outage that
    //    includes the whole backlog (observed: yesterday's messages
    //    re-executed on today's connect). A command older than the
    //    dedup window is a replay whose moment has passed; the
    //    in-memory dedup below can't catch it across restarts.
    if (event.createTime > 0) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - event.createTime;
      if (ageMs > _kDedupTtl.inMilliseconds) {
        _log.info('feishu: dropped stale replay ${event.messageId} '
            '(age ${(ageMs / 1000).round()}s)');
        return;
      }
    }

    // 2. Dedup (§4.3): re-delivery after a 3 s ack miss, or the same
    //    event landing twice after a reconnect.
    final now = DateTime.now();
    _seen.removeWhere((_, at) => now.difference(at) > _kDedupTtl);
    if (_seen.containsKey(event.messageId)) return;
    _seen[event.messageId] = now;
    while (_seen.length > _kDedupCapacity) {
      _seen.remove(_seen.keys.first);
    }

    // 3. Whitelist (§4.2): the creator + ids added later; anything
    //    else is dropped silently (no reply — don't leak the bot).
    final allowed = _credentials?.allowedOpenIds;
    if (allowed == null ||
        allowed.isEmpty ||
        event.senderOpenId.isEmpty ||
        !allowed.contains(event.senderOpenId)) {
      _log.info('feishu: dropped message from unlisted sender');
      return;
    }

    // 4. Text only; empty text (stickers etc.) is ignored.
    if (event.text.isEmpty) return;

    // 5. A new command flushes any pending output capture first.
    _capture?.flush();

    // 6. Execute: write into the active terminal and watch its
    //    output for the aggregation window.
    final output = bridge.subscribeActiveOutput();
    if (output == null) {
      unawaited(api
          .sendText(event.chatId, 'No active terminal in Octodo.'));
      return;
    }
    _capture = _OutputCapture(
      stream: output,
      chatId: event.chatId,
      api: api,
      command: event.text,
      idleWindow: outputWindow,
      maxWindow: maxOutputWindow,
      onDone: () => _capture = null,
    );
    bridge.runCommand('${event.text}\n');
    _log.info('feishu: command ${event.messageId} '
        'from ${event.senderOpenId} executed');
  }

  void _onEvent(FeishuInboundEvent event) => handleEvent(event);

  Future<void> dispose() async {
    await _stop();
    if (channel is FeishuWsChannel) {
      (channel as FeishuWsChannel).dispose();
    }
    api.dispose();
  }
}

/// Collects one command's PTY output and turns it into a single
/// cleaned-up reply. The capture ends at the first of:
///
///  - [idleWindow] of silence with a fresh shell prompt at the
///    tail — the normal "command finished" signal. Silence alone is
///    NOT enough: cold toolchains (first `flutter --version`, pub
///    resolution, …) stay silent for far longer than the idle
///    window before printing anything, and a fixed window used to
///    flush the command's echo and miss the real output entirely.
///  - [_kOutputMaxBytes] bytes (very verbose commands),
///  - [maxWindow] since the command was written — commands that
///    never finish, or shells whose prompt we don't recognize,
///  - the output stream closing, or the next command arriving
///    (the router flushes the previous capture).
class _OutputCapture {
  final Stream<List<int>> stream;
  final String chatId;
  final FeishuApiClient api;
  final VoidCallback onDone;

  /// The command exactly as sent, used to strip the shell's echo
  /// of it from the head of the reply.
  final String command;

  /// Quiet period that may end the capture once a prompt shows.
  final Duration idleWindow;

  /// Absolute ceiling on the whole capture.
  final Duration maxWindow;

  final List<int> _buffer = [];
  StreamSubscription<List<int>>? _sub;
  Timer? _idleTimer;
  Timer? _capTimer;
  bool _finished = false;

  _OutputCapture({
    required this.stream,
    required this.chatId,
    required this.api,
    required this.command,
    required this.idleWindow,
    required this.maxWindow,
    required this.onDone,
  }) {
    _sub = stream.listen(_onBytes, onError: (_) {}, onDone: flush);
    _idleTimer = Timer(idleWindow, _onIdle);
    _capTimer = Timer(maxWindow, flush);
  }

  void _onBytes(List<int> data) {
    if (_finished) return;
    _buffer.addAll(data);
    if (_buffer.length >= _kOutputMaxBytes) {
      flush();
      return;
    }
    // Output is still flowing — the command is alive. Restart the
    // quiet-period clock.
    _idleTimer?.cancel();
    _idleTimer = Timer(idleWindow, _onIdle);
  }

  void _onIdle() {
    if (_finished) return;
    // Quiet for one idle window. Only reply when the shell shows a
    // fresh prompt (it finished and is waiting for input); without
    // one the command may still be running silently, so keep
    // waiting up to the hard cap.
    final lines = _cleanLines(_buffer);
    final tail = lines.isEmpty ? '' : lines.last;
    if (promptLike.hasMatch(tail)) {
      flush();
      return;
    }
    _idleTimer = Timer(idleWindow, _onIdle);
  }

  /// Stop capturing and send what we have (if anything readable).
  void flush() {
    if (_finished) return;
    _finished = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _capTimer?.cancel();
    _capTimer = null;
    _sub?.cancel();
    final bytes = _buffer.toList();
    _buffer.clear();
    onDone();
    var lines = _cleanLines(bytes);
    // The shell's echo of the command itself is noise on the phone.
    if (lines.length > 1 && lines.first == command) lines.removeAt(0);
    // So is the fresh prompt that told us the command finished
    // (kept when it is all there is — it is the reply to `cd ..`).
    if (lines.length > 1 && promptLike.hasMatch(lines.last)) {
      lines.removeLast();
    }
    if (lines.isEmpty) return; // command produced no visible output
    unawaited(api.sendText(chatId, _formatLines(lines)).catchError((_) {}));
  }

  /// What the common shells print while waiting for input:
  /// PowerShell (`PS C:\Users\Sun>`), cmd (`C:\>`), and the usual
  /// unix sigils ($, >, %, ❯, ➜) at the end of a short line.
  /// Deliberately loose: a false positive costs one early reply,
  /// a false negative delays the reply to the hard cap.
  static final RegExp promptLike = RegExp(
      r'^(?:PS .+>|[A-Za-z]:[\\/].+>|\\\\.+>|\S.{0,98}[>$❯➜]|[>$❯➜])$');

  /// UTF-8 (malformed tolerated) minus ANSI CSI/OSC sequences and
  /// carriage noise — what a reader on the phone cares about.
  static List<String> _cleanLines(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    // OSC (title, hyperlinks, …): ESC ] … BEL / ESC \
    final osc = RegExp('\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)');
    // CSI (colors, cursor moves, …): ESC [ params final
    final csi = RegExp('\x1b\\[[0-9;?]*[ -/]*[@-~]');
    text = text.replaceAll(osc, '').replaceAll(csi, '');
    // Remaining lone ESCs.
    text = text.replaceAll('\x1b', '');
    // Drop BEL, vertical tab; normalize newlines.
    text = text.replaceAll('\x07', '').replaceAll('\r', '');
    return text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Very verbose output: keep head and tail with an ellipsis.
  static String _formatLines(List<String> lines) {
    const maxLines = 40;
    if (lines.length <= maxLines) return lines.join('\n');
    const keep = 15;
    final head = lines.take(keep).join('\n');
    final tail = lines.sublist(lines.length - keep).join('\n');
    return '$head\n… (${lines.length - keep * 2} lines)…\n$tail';
  }
}

class _NullHostBridge implements FeishuHostBridge {
  @override
  void runCommand(String command) {}

  @override
  Stream<List<int>>? subscribeActiveOutput() => null;
}
