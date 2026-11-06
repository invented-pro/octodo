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
import 'opencode_client.dart';

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

  /// Whether the active terminal is currently displaying a
  /// full-screen TUI (alternate screen buffer) — vim, less, the
  /// opencode TUI, … Null when there is no active terminal. The
  /// router mirrors the rendered screen then: TUI redraws are
  /// screen layout, not line output.
  bool? activeTerminalInAltScreen();

  /// The active terminal's visible screen as text lines, top row
  /// first — what a full-screen TUI currently shows, or the
  /// shell's latest lines. Null when there is no active terminal.
  List<String>? snapshotActiveScreen();

  /// Stable identity of the focused terminal surface, so the
  /// router can keep per-terminal state across commands (e.g.
  /// which TUI app owns it). Null when there is no active
  /// terminal.
  String? activeTerminalId();

  /// The focused terminal's working directory (OSC 7 tracked,
  /// falling back to the spawn directory) — the key the opencode
  /// gateway matches server sessions by. Null when unknown.
  String? activeTerminalCwd();

  /// The focused terminal rendered to PNG (its enclosing repaint
  /// boundary rasterized) — `/history` sends this to the phone.
  /// Null when there is no active terminal (or it can't be
  /// rasterized yet).
  Future<Uint8List?> snapshotActiveTerminalPng();
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
/// partial reply after this long. Generous because agent-style
/// commands (`opencode run "…"`) legitimately think for minutes.
const Duration _kOutputMaxWindowDefault = Duration(minutes: 5);

/// …or until this many bytes arrive, whichever first.
const int _kOutputMaxBytes = 15 * 1024;

/// What the router answers when a full-screen TUI without a
/// server adapter owns the terminal: the text is relayed and the
/// rendered screen mirrored back — layout noise is unavoidable
/// for unknown apps, hence the pointer to /history.
const String _kTuiHint = 'A full-screen app owns the desktop terminal — '
    'your message was typed into it; below is its screen.\n'
    '/history — the screen. /raw <keys> — raw keys (e.g. /raw /quit).';

/// What the router answers when the TUI that just launched is
/// opencode: the router types into it and answers from the
/// opencode server.
const String _kOpencodeTuiHint = 'opencode detected — your messages are '
    'typed into it, so it shows them in its current session.\n'
    '/history — the conversation. /raw <keys> — raw keys '
    '(e.g. /raw /quit).';

/// The TUI had the keyboard but did not submit the message — a
/// modal (session picker, help overlay) swallowed it, or the app
/// runs against a different opencode server than this gateway.
const String _kTuiNotSubmitted = 'The message was typed into the app, '
    'but nothing came back — a menu or dialog may have the keyboard '
    '(close it and send again), or the app talks to another opencode '
    'server.';

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

  /// The Enter keystroke still waiting to follow a TUI text write
  /// (see [_writeTuiLine]) — at most one, cancelled by the next
  /// write so rapid messages can't stack Enters.
  Timer? _pendingTuiEnter;

  /// Tail of the one-at-a-time TUI chat chain: two Feishu messages
  /// must not interleave in the TUI's composer (they would merge
  /// into one submission).
  Future<void> _tuiChatQueue = Future<void>.value();

  /// Idle window that ends a command's output capture (injectable).
  final Duration outputWindow;

  /// Hard ceiling on one command's output capture (injectable).
  final Duration maxOutputWindow;

  /// The opencode client-server gateway (path 1): `/ai` and
  /// opencode-TUI terminals chat through it with pure text
  /// replies. Injectable for tests.
  final OpencodeGateway opencode;

  /// Per-terminal TUI identity, learned by sniffing the echoed
  /// launch command right before a TUI takes the screen —
  /// terminal id → app name ('opencode', …).
  final _tuiApps = <String, String>{};

  FeishuIntegration({
    required this.bridge,
    FeishuEventChannel? channel,
    FeishuApiClient? api,
    FeishuCredentialStore? credentialStore,
    this.outputWindow = _kOutputWindowDefault,
    this.maxOutputWindow = _kOutputMaxWindowDefault,
    OpencodeGateway? opencode,
  })  : opencode = opencode ?? OpencodeLocalGateway(),
        channel = channel ?? FeishuWsChannel(),
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

    // 5. `/history` replies with what the conversation/screen
    //    currently shows — the server conversation tail when a
    //    server-backed TUI owns the terminal, else a rendered PNG
    //    snapshot, else the filtered screen text.
    if (event.text == '/history') {
      _capture?.flush();
      unawaited(_sendHistory(event.chatId));
      return;
    }

    // 5b. `/raw <text>` — relay raw text into whatever owns the
    //     terminal (a full-screen TUI included), bypassing the
    //     server routing: the escape hatch for TUI control (q,
    //     /, dd, …).
    if (event.text == '/raw' || event.text.startsWith('/raw ')) {
      final keys = event.text.substring(4).trim();
      if (keys.isEmpty) {
        unawaited(api
            .sendText(event.chatId, 'Usage: /raw <text>')
            .catchError((_) {}));
        return;
      }
      if (bridge.activeTerminalInAltScreen() == true) {
        _mirrorIntoTui(event, text: keys);
      } else {
        _writeAndCapture(event.chatId, keys);
      }
      _log.info('feishu: /raw ${event.messageId} relayed');
      return;
    }

    // 7. A full-screen TUI owns the terminal. TUIs with a
    //    registered server adapter (see [_gatewayFor]) are routed
    //    through their server — same session the desktop TUI
    //    shows, pure text replies. Any other TUI gets the text
    //    relayed and its screen mirrored back.
    if (bridge.activeTerminalInAltScreen() == true) {
      final termId = bridge.activeTerminalId();
      final app =
          _tuiApps[termId] ?? _sniffScreenApp(bridge.snapshotActiveScreen());
      final gateway = _gatewayFor(app);
      if (gateway != null) {
        // Serialized: the messages go into the TUI's composer one
        // after the other.
        final task = _tuiChatQueue
            .then((_) => _tuiServerChat(event, gateway))
            .catchError((_) {});
        _tuiChatQueue = task.then<void>((_) {}, onError: (_) {});
        return;
      }
      _mirrorIntoTui(event);
      return;
    }

    // 8. Execute: write into the active terminal and watch its
    //    output for the aggregation window.
    _writeAndCapture(event.chatId, event.text);
    _log.info('feishu: command ${event.messageId} '
        'from ${event.senderOpenId} executed');
  }

  /// Write [commandLine] into the active terminal and capture its
  /// output for the reply (the plain-command path — line output,
  /// not a screen mirror). Shared by direct commands and `/ai`.
  void _writeAndCapture(String chatId, String commandLine) {
    // A new command flushes any pending output capture first.
    _capture?.flush();
    final output = bridge.subscribeActiveOutput();
    if (output == null) {
      unawaited(api
          .sendText(chatId, 'No active terminal in Octodo.')
          .catchError((_) {}));
      return;
    }
    _capture = _OutputCapture(
      stream: output,
      chatId: chatId,
      api: api,
      command: commandLine,
      idleWindow: outputWindow,
      maxWindow: maxOutputWindow,
      onDone: () => _capture = null,
      terminalId: bridge.activeTerminalId(),
      onTuiApp: _rememberTuiApp,
    );
    bridge.runCommand('$commandLine\n');
  }

  /// Record which server-backed TUI owns a terminal (sniffed at
  /// launch), so later messages into that terminal auto-route
  /// through its server instead of the screen mirror.
  void _rememberTuiApp(String terminalId, String app) {
    _tuiApps[terminalId] = app;
    _log.info('feishu: $app TUI detected in terminal $terminalId');
  }

  /// Recognize a server-backed TUI from its rendered screen — the
  /// fallback for TUIs started locally at the desktop (no router
  /// capture saw the launch). The opencode TUI carries its brand
  /// in the header lines.
  static String? _sniffScreenApp(List<String>? screen) {
    if (screen == null) return null;
    for (final line in screen.take(6)) {
      if (line.toLowerCase().contains('opencode')) return 'opencode';
    }
    return null;
  }

  /// Server-backed TUI adapters, keyed by the app names the
  /// sniffers produce. This is the registry point for other
  /// headless-capable TUIs (claude-code, gemini, …) — the routing
  /// itself is app-agnostic.
  OpencodeGateway? _gatewayFor(String? app) =>
      app == 'opencode' ? opencode : null;

  /// `/history` — what the conversation/screen shows, best source
  /// first:
  ///
  ///  1. A server-backed TUI's conversation tail (pure clean text
  ///     — better than any picture of it),
  ///  2. the rendered PNG (needs the bot's image-upload scope;
  ///     skipped silently when the platform denies it),
  ///  3. the screen grid as text, decoration lines dropped.
  Future<void> _sendHistory(String chatId) async {
    final termId = bridge.activeTerminalId();
    final app =
        _tuiApps[termId] ?? _sniffScreenApp(bridge.snapshotActiveScreen());
    final gateway = _gatewayFor(app);
    if (gateway != null) {
      final cwd = bridge.activeTerminalCwd();
      if (cwd != null) {
        try {
          final tail = await gateway.conversationTail(cwd);
          if (tail != null && tail.isNotEmpty) {
            await api.sendText(chatId, tail);
            return;
          }
        } catch (_) {}
      }
    }
    try {
      final png = await bridge.snapshotActiveTerminalPng();
      if (png != null && png.isNotEmpty) {
        await api.sendImage(chatId, png);
        return;
      }
    } catch (e) {
      _log.warning('feishu: screen image failed ($e)');
    }
    final screen = _trimBlank(bridge.snapshotActiveScreen() ?? const [])
        .where((l) => !_decorationLine.hasMatch(l))
        .toList();
    final text =
        screen.isEmpty ? '(blank screen)' : _formatReplyLines(screen);
    await api.sendText(chatId, text).catchError((_) {});
  }

  /// Pure-decoration rows of a TUI frame — borders, rules,
  /// spinner padding — that carry no content. (`-` last so it
  /// can't open a range.)
  static final RegExp _decorationLine =
      RegExp(r'^[\s─━═│┃║╔╗╚╝╠╣╦╩╬┌┐└┘├┤┬┴┼╌╎┄┅·•◦=+-]*$');

  /// A message typed into a terminal owned by a TUI with a server
  /// adapter.
  ///
  /// The text is typed INTO the TUI, so the TUI submits it to
  /// whatever session it is displaying — including a brand-new one
  /// the server hasn't heard of yet (a TUI creates its session
  /// lazily, on the first local message). The reply comes from the
  /// server's event stream as pure text, keyed by the session the
  /// TUI just used.
  Future<void> _tuiServerChat(
      FeishuInboundEvent event, OpencodeGateway gateway) async {
    final cwd = bridge.activeTerminalCwd();
    if (cwd == null || !await gateway.ensure()) {
      _log.info('feishu: tui-chat ${event.messageId} fell back to mirror');
      _mirrorIntoTui(event);
      return;
    }
    _capture?.flush();
    final result = await gateway.tuiTurn(
      cwd,
      _oneLine(event.text),
      (line) => _writeTuiLine(line),
    );
    final sessionId = result.sessionId;
    final reply = result.reply;
    if (sessionId == null) {
      // The text was typed, but the TUI never submitted it — a
      // modal (session picker, help) had the keyboard.
      _log.info('feishu: tui-chat ${event.messageId} was not submitted');
      await api
          .sendText(event.chatId, _kTuiNotSubmitted)
          .catchError((_) {});
      return;
    }
    if (reply != null && reply.isNotEmpty) {
      _log.info('feishu: tui-chat ${event.messageId} via the TUI '
          '(session $sessionId)');
      await api.sendText(event.chatId, reply).catchError((_) {});
      return;
    }
    _log.info('feishu: tui-chat ${event.messageId} gave no reply text');
    await api
        .sendText(event.chatId,
            'The app accepted the message, but produced no text reply.')
        .catchError((_) {});
  }

  /// One line of text: the TUI composer submits on Enter, so a
  /// multi-line message must not carry its own line breaks.
  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'\s*\n+\s*'), ' ').trim();

  /// Relay the text into the TUI and mirror its rendered screen
  /// back once quiet (the generic TUI path). [text] overrides
  /// [FeishuInboundEvent.text] for `/raw`.
  void _mirrorIntoTui(FeishuInboundEvent event, {String? text}) {
    final line = text ?? event.text;
    _capture?.flush();
    final output = bridge.subscribeActiveOutput();
    if (output == null) {
      _writeTuiLine(line);
      unawaited(api
          .sendText(event.chatId, _kTuiHint)
          .catchError((_) {}));
      return;
    }
    _capture = _OutputCapture(
      stream: output,
      chatId: event.chatId,
      api: api,
      command: line,
      idleWindow: outputWindow,
      maxWindow: maxOutputWindow,
      onDone: () => _capture = null,
      screenOf: bridge.snapshotActiveScreen,
    );
    _writeTuiLine(line);
  }

  /// Write a line into a TUI as two separate PTY writes: the text
  /// first, Enter ~150ms later. TUIs consume input keystroke by
  /// keystroke, and a text+CR in one write can race the app's
  /// input parser — the command then sits on screen, suspended,
  /// its Enter swallowed (observed: opencode's `/quit`). The
  /// plain-shell path (`_writeAndCapture`) is unaffected: a
  /// shell's line discipline handles text+CR in one write fine.
  void _writeTuiLine(String line) {
    _pendingTuiEnter?.cancel();
    bridge.runCommand(line);
    _pendingTuiEnter =
        Timer(const Duration(milliseconds: 150), () => bridge.runCommand('\n'));
  }

  void _onEvent(FeishuInboundEvent event) => handleEvent(event);

  Future<void> dispose() async {
    _pendingTuiEnter?.cancel();
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

  /// Screen-mirror mode (terminal owned by a full-screen TUI):
  /// when set, the reply is a snapshot of the rendered screen
  /// taken at flush time instead of the cleaned byte stream.
  /// Returns null when the terminal vanished meanwhile.
  final List<String>? Function()? screenOf;

  /// Identity of the terminal this capture runs in, and the
  /// callback fired when a known TUI app (see [_sniffTuiApp]) is
  /// detected taking the screen — the router records it so later
  /// messages into this terminal route through that app's server.
  final String? terminalId;
  final void Function(String terminalId, String app)? onTuiApp;

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
    this.screenOf,
    this.terminalId,
    this.onTuiApp,
  }) {
    _sub = stream.listen(_onBytes, onError: (_) {}, onDone: flush);
    _idleTimer = Timer(idleWindow, _onIdle);
    _capTimer = Timer(maxWindow, flush);
  }

  void _onBytes(List<int> data) {
    if (_finished) return;
    _buffer.addAll(data);
    // A TUI taking over the screen (DECSET 1049/1047/47) makes the
    // rest of the stream layout painting — end with the hint
    // instead of relaying its cleaning leftovers as garbage. (Not
    // in mirror mode: we are already IN a TUI and mirroring it.)
    if (screenOf == null &&
        _altScreenEnter
            .hasMatch(utf8.decode(data, allowMalformed: true))) {
      final app = _sniffTuiApp(_cleanLines(_buffer));
      final tid = terminalId;
      if (app != null && tid != null) onTuiApp?.call(tid, app);
      _finish();
      unawaited(api
          .sendText(
              chatId, app == 'opencode' ? _kOpencodeTuiHint : _kTuiHint)
          .catchError((_) {}));
      return;
    }
    if (_buffer.length >= _kOutputMaxBytes) {
      flush();
      return;
    }
    // Output is still flowing — the command is alive. Restart the
    // quiet-period clock.
    _idleTimer?.cancel();
    _idleTimer = Timer(idleWindow, _onIdle);
  }

  /// `ESC [ ? 1049/1047/47 h` — enter the alternate screen buffer.
  static final RegExp _altScreenEnter =
      RegExp('\x1b\\[\\?(?:1049|1047|47)h');

  /// Guess which server-backed TUI just launched from the echoed
  /// command line right before the alt-screen switch (the shell
  /// echoes what the user typed). The app must be the command's
  /// first word — `vim opencode.md` is vim, not opencode. Null
  /// when unrecognized: the generic mirror path handles it.
  static String? _sniffTuiApp(List<String> lines) {
    for (final line in lines.reversed.take(4)) {
      if (RegExp('(?:^|>\\s*)opencode\\b').hasMatch(line)) {
        return 'opencode';
      }
    }
    return null;
  }

  void _onIdle() {
    if (_finished) return;
    // Mirror mode: quiet is the only "done" signal a TUI gives.
    if (screenOf != null) {
      flush();
      return;
    }
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
    _finish();
    if (screenOf != null) {
      // Mirror mode: reply with the rendered screen, not bytes.
      final screen = _trimBlank(screenOf!() ?? const []);
      if (screen.isEmpty) return; // blank screen, nothing to say
      unawaited(api
          .sendText(chatId, _formatReplyLines(screen))
          .catchError((_) {}));
      return;
    }
    final bytes = _buffer.toList();
    _buffer.clear();
    var lines = _cleanLines(bytes);
    // The shell's echo of the command itself is noise on the phone.
    if (lines.length > 1 && lines.first == command) lines.removeAt(0);
    // So is the fresh prompt that told us the command finished
    // (kept when it is all there is — it is the reply to `cd ..`).
    if (lines.length > 1 && promptLike.hasMatch(lines.last)) {
      lines.removeLast();
    }
    if (lines.isEmpty) return; // command produced no visible output
    unawaited(
        api.sendText(chatId, _formatReplyLines(lines)).catchError((_) {}));
  }

  /// Tear the capture down (timers, subscription, router state).
  void _finish() {
    if (_finished) return;
    _finished = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _capTimer?.cancel();
    _capTimer = null;
    _sub?.cancel();
    onDone();
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
}

/// Join captured/screen lines into one reply — very verbose
/// output keeps head and tail with an ellipsis.
String _formatReplyLines(List<String> lines) {
  const maxLines = 40;
  if (lines.length <= maxLines) return lines.join('\n');
  const keep = 15;
  final head = lines.take(keep).join('\n');
  final tail = lines.sublist(lines.length - keep).join('\n');
  return '$head\n… (${lines.length - keep * 2} lines)…\n$tail';
}

/// Drop the blank padding lines at the top/bottom of a screen
/// snapshot (TUI chrome is rarely edge-to-edge text).
List<String> _trimBlank(List<String> lines) {
  var start = 0;
  var end = lines.length;
  while (start < end && lines[start].isEmpty) {
    start++;
  }
  while (end > start && lines[end - 1].isEmpty) {
    end--;
  }
  return lines.sublist(start, end);
}

class _NullHostBridge implements FeishuHostBridge {
  @override
  void runCommand(String command) {}

  @override
  Stream<List<int>>? subscribeActiveOutput() => null;

  @override
  bool? activeTerminalInAltScreen() => null;

  @override
  List<String>? snapshotActiveScreen() => null;

  @override
  String? activeTerminalId() => null;

  @override
  String? activeTerminalCwd() => null;

  @override
  Future<Uint8List?> snapshotActiveTerminalPng() async => null;
}
