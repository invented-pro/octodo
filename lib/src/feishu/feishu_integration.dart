// The Feishu integration router — the app-facing brain of the
// remote-control loop (design doc §3–§5):
//
//   inbound:  event → whitelist (allowed open_ids) → dedup
//             (message_id window) → host bridge writes the command
//             into the active terminal
//   outbound: the active terminal's output, aggregated over a short
//             window after each command, stripped of escape
//             sequences, sent back to the originating chat
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
  /// for a short window after each command.
  Stream<List<int>>? subscribeActiveOutput();
}

/// Dedup window (§4.3): remember this many message ids…
const int _kDedupCapacity = 1000;

/// …for at most this long.
const Duration _kDedupTtl = Duration(minutes: 10);

/// Output aggregation window (§5): collect PTY output for this long
/// after a command, then reply. Injectable for tests.
const Duration _kOutputWindowDefault = Duration(milliseconds: 2500);

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

  /// Output aggregation window after each command (injectable).
  final Duration outputWindow;

  FeishuIntegration({
    required this.bridge,
    FeishuEventChannel? channel,
    FeishuApiClient? api,
    FeishuCredentialStore? credentialStore,
    this.outputWindow = _kOutputWindowDefault,
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
      window: outputWindow,
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

/// Collects one command's PTY output: a short [window] of bytes
/// (capped), then one cleaned-up reply message.
class _OutputCapture {
  final Stream<List<int>> stream;
  final String chatId;
  final FeishuApiClient api;
  final VoidCallback onDone;

  final List<int> _buffer = [];
  StreamSubscription<List<int>>? _sub;
  Timer? _timer;
  bool _finished = false;

  _OutputCapture({
    required this.stream,
    required this.chatId,
    required this.api,
    required Duration window,
    required this.onDone,
  }) {
    _sub = stream.listen(_onBytes, onError: (_) {});
    _timer = Timer(window, flush);
  }

  void _onBytes(List<int> data) {
    if (_finished) return;
    _buffer.addAll(data);
    if (_buffer.length >= _kOutputMaxBytes) flush();
  }

  /// Stop capturing and send what we have (if anything readable).
  void flush() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _sub?.cancel();
    final bytes = _buffer.toList();
    _buffer.clear();
    onDone();
    final text = _toReadableText(bytes);
    if (text.isEmpty) return; // command produced no visible output
    unawaited(api.sendText(chatId, text).catchError((_) {}));
  }

  /// UTF-8 (malformed tolerated) minus ANSI CSI/OSC sequences and
  /// carriage noise — what a reader on the phone cares about.
  static String _toReadableText(List<int> bytes) {
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
    final lines = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    // Very verbose output: keep head and tail with an ellipsis.
    const maxLines = 40;
    if (lines.length > maxLines) {
      const keep = 15;
      final head = lines.take(keep).join('\n');
      final tail = lines.sublist(lines.length - keep).join('\n');
      return '$head\n… (${lines.length - keep * 2} lines)…\n$tail';
    }
    return lines.join('\n');
  }
}

class _NullHostBridge implements FeishuHostBridge {
  @override
  void runCommand(String command) {}

  @override
  Stream<List<int>>? subscribeActiveOutput() => null;
}
