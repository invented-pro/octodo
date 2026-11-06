// Router tests for the Feishu integration: whitelist gating,
// message dedup, command execution, and the output-aggregation
// reply — all against fakes (channel, api, bridge, store).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_api_client.dart';
import 'package:octodo/src/feishu/feishu_approval.dart';
import 'package:octodo/src/feishu/feishu_binding.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';
import 'package:octodo/src/feishu/feishu_event_channel.dart';
import 'package:octodo/src/feishu/feishu_integration.dart';
import 'package:octodo/src/feishu/opencode_client.dart';

class _FakeChannel implements FeishuEventChannel {
  final eventsController = StreamController<FeishuInboundEvent>.broadcast();
  final cardController = StreamController<FeishuCardActionEvent>.broadcast();
  FeishuCredentials? startedWith;
  int startCalls = 0;
  int stopCalls = 0;

  /// The router's card-action handler — the tests call it directly.
  Future<Map<String, dynamic>?> Function(FeishuCardActionEvent)? handler;

  @override
  Stream<FeishuInboundEvent> get events => eventsController.stream;

  @override
  Stream<FeishuCardActionEvent> get cardActions => cardController.stream;

  @override
  Future<Map<String, dynamic>?> Function(FeishuCardActionEvent)?
      get cardActionHandler => handler;

  @override
  set cardActionHandler(
      Future<Map<String, dynamic>?> Function(FeishuCardActionEvent)? value) {
    handler = value;
  }

  @override
  Stream<FeishuConnectionState> get stateChanges => const Stream.empty();

  @override
  FeishuConnectionState get currentState => FeishuConnectionState.disconnected;

  @override
  Future<void> start(FeishuCredentials credentials) async {
    startCalls++;
    startedWith = credentials;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _RecordingBridge implements FeishuHostBridge {
  final commands = <String>[];

  /// The workspace each command went to (null = the active one).
  final targets = <String?>[];

  final outputController = StreamController<List<int>>.broadcast();
  bool hasTerminal = true;
  bool altScreen = false;
  List<String>? screenLines;
  String termId = 'term_1';
  String? cwd;
  Uint8List? png;

  /// The workspaces the fake reports to the `/attach` picker.
  List<FeishuWorkspace> workspaces = const [];

  /// The pane layout the fake reports to `/status`.
  List<FeishuPaneStatus> panes = const [];

  /// The panes the fake was asked to focus.
  final List<String> focusedPanes = [];

  @override
  List<FeishuWorkspace> listWorkspaces() => workspaces;

  @override
  FeishuLayoutStatus layoutOf(String? workspaceId) =>
      FeishuLayoutStatus(panes);

  @override
  bool focusPane(String? workspaceId, String paneId) {
    focusedPanes.add(paneId);
    return true;
  }

  @override
  void runCommand(String? workspaceId, String command) {
    targets.add(workspaceId);
    commands.add(command);
  }

  @override
  Stream<List<int>>? subscribeOutput(String? workspaceId) =>
      hasTerminal ? outputController.stream : null;

  @override
  bool? inAltScreen(String? workspaceId) => hasTerminal ? altScreen : null;

  @override
  List<String>? snapshotScreen(String? workspaceId) =>
      hasTerminal ? screenLines : null;

  @override
  String? terminalId(String? workspaceId) => hasTerminal ? termId : null;

  @override
  String? terminalCwd(String? workspaceId) => hasTerminal ? cwd : null;

  @override
  Future<Uint8List?> snapshotPng(String? workspaceId) async =>
      hasTerminal ? png : null;
}

/// Server-side of the opencode path, faked: [ready] gates both
/// ensure() and chat(); [tail] is what conversationTail returns.
/// [submits] models a TUI that accepts what is typed into it — a
/// modal that swallows the text is the same as submits=false.
class _FakeGateway implements OpencodeGateway {
  bool ready = false;
  String? reply;
  String? tail;
  String? lastDir;
  String? lastMsg;
  bool submits = true;

  @override
  Future<bool> ensure() async => ready;

  @override
  Future<String?> chat(String directory, String message) async {
    lastDir = directory;
    lastMsg = message;
    return ready ? reply : null;
  }

  @override
  Future<String?> conversationTail(String directory, {int limit = 6}) async {
    lastDir = directory;
    return ready ? tail : null;
  }

  @override
  Future<({String? sessionId, String? reply})> tuiTurn(
      String directory, String message, void Function(String) type) async {
    lastDir = directory;
    lastMsg = message;
    if (!ready) return (sessionId: null, reply: null);
    type(message);
    if (!submits) return (sessionId: null, reply: null);
    return (sessionId: 'ses_typed', reply: reply);
  }
}

FeishuCredentials _ownerCreds({List<String> allowed = const ['ou_owner']}) =>
    FeishuCredentials(
      appId: 'cli_x',
      appSecret: 's',
      ownerOpenId: 'ou_owner',
      tenantBrand: 'feishu',
      boundAt: DateTime.utc(2026),
      allowedOpenIds: allowed,
    );

void main() {
  test('sync starts the channel only when enabled and bound', () async {
    final dir = Directory.systemTemp.createTempSync('feishu_int');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FeishuCredentialStore(
        File('${dir.path}${Platform.pathSeparator}c.json'));

    final channel = _FakeChannel();
    final integration = FeishuIntegration(
      bridge: _RecordingBridge(),
      channel: channel,
      credentialStore: store,
    );

    await integration.sync(enabled: false);
    expect(channel.startCalls, 0);

    await store.save(_ownerCreds());
    await integration.sync(enabled: true);
    expect(channel.startCalls, 1);
    expect(channel.startedWith!.appId, 'cli_x');

    await integration.sync(enabled: false);
    expect(channel.stopCalls, 1);
  });

  test('unlisted senders are dropped silently', () async {
    final integration = await _routerFor(
        creds: _ownerCreds(), bridge: _RecordingBridge());
    integration.handleEvent(const FeishuInboundEvent(
      senderOpenId: 'ou_stranger',
      chatId: 'oc_c',
      messageId: 'om_1',
      text: 'rm -rf /',
    ));
    // No terminal write, no reply — the router is silent to
    // strangers. (Command list and sends asserted via the bridge /
    // api fakes in the happy-path test.)
    expect((integration.bridge as _RecordingBridge).commands, isEmpty);
  });

  test('whitelisted command executes in the active terminal and the '
      'aggregated output is sent back', () async {
    final bridge = _RecordingBridge();
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 30),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_1',
      text: 'echo hi',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));

    expect(bridge.commands, ['echo hi\n']);

    // PTY output arrives within the window (echo + prompt noise).
    bridge.outputController.add(
      utf8.encode('hi\r\n\x1b[32m\$\x1b[0m '),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(sent.length, 1);
    expect(sent.single.$1, 'oc_chat');
    // Escape sequences stripped, blank lines dropped, and the
    // trailing prompt ($) recognized as end-of-command and removed.
    expect(sent.single.$2, 'hi');
  });

  test('long-running commands: the reply waits for the real output',
      () async {
    final bridge = _RecordingBridge();
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 40),
      maxOutputWindow: const Duration(seconds: 5),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_slow',
      text: 'flutter --version',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(bridge.commands, ['flutter --version\n']);

    // The shell echoes the command instantly, then the toolchain
    // warms up silently for far longer than the idle window. No
    // prompt has shown, so nothing may be sent yet (this is the
    // field bug: the reply used to be just the echo).
    bridge.outputController.add(utf8.encode('flutter --version\r\n'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(sent, isEmpty, reason: 'no prompt yet — command may still run');

    // Seconds later the real output arrives, then the fresh prompt.
    bridge.outputController
        .add(utf8.encode('Flutter 3.47.9 • channel stable\r\n'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    bridge.outputController.add(utf8.encode('PS C:\\Users\\Sun> '));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(sent.length, 1);
    // Echo stripped, prompt stripped: just the output.
    expect(sent.single.$2, 'Flutter 3.47.9 • channel stable');
  });

  test('commands that never show a prompt get a partial reply at the cap',
      () async {
    final bridge = _RecordingBridge();
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 30),
      maxOutputWindow: const Duration(milliseconds: 250),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_spin',
      text: 'spin',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    bridge.outputController.add(utf8.encode('spinning\r\n'));

    // The tail never looks like a prompt, so the idle window keeps
    // extending — but the hard cap still produces exactly one
    // partial reply rather than waiting forever.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(sent.length, 1);
    expect(sent.single.$2, 'spinning');
  });

  test('duplicate message ids are executed once (re-delivery)', () async {
    final bridge = _RecordingBridge();
    final integration = await _routerFor(
        creds: _ownerCreds(),
        bridge: bridge,
        outputWindow: const Duration(milliseconds: 5000));

    for (var i = 0; i < 3; i++) {
      integration.handleEvent(FeishuInboundEvent(
        senderOpenId: 'ou_owner',
        chatId: 'oc_chat',
        messageId: 'om_same',
        text: 'echo dup',
        createTime: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    expect(bridge.commands, ['echo dup\n']);
  });

  test('stale replays (backlog redelivery after restart) are dropped',
      () async {
    final bridge = _RecordingBridge();
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
    );

    // Feishu redelivers un-acked events on the next connect — even
    // from a previous day. Anything older than the dedup TTL must
    // not re-execute.
    final stale = DateTime.now().subtract(const Duration(minutes: 30));
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_yesterday',
      text: 'ls',
      createTime: stale.millisecondsSinceEpoch,
    ));

    expect(bridge.commands, isEmpty);
    expect(sent, isEmpty);
  });

  test('messages typed into a full-screen TUI are relayed and the '
      'rendered screen is mirrored back', () async {
    final bridge = _RecordingBridge()
      ..altScreen = true
      ..screenLines = [
        '',
        ' opencode',
        '',
        ' assistant: Hello! How can I help?',
        '',
        ' > hi',
        '',
      ];
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 40),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_tui',
      text: 'hi',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    // The text IS relayed — the user may be driving the TUI on
    // purpose (chat input, 'q', '/' …). Text first; Enter lands
    // as its own write ~150ms later (see _writeTuiLine). The write
    // goes through the TUI chat queue, so give it a tick.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bridge.commands, ['hi']);

    // The TUI redraws as the message lands and the assistant
    // streams; every chunk keeps the mirror waiting for quiet.
    bridge.outputController.add(utf8.encode('\x1b[H\x1b[2Jredraw'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    bridge.outputController.add(utf8.encode('\x1b[3;1Hstream'));
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // The reply is the rendered screen (blank padding trimmed) —
    // never the redraw bytes.
    expect(sent.length, 1);
    expect(sent.single.$2,
        ' opencode\n\n assistant: Hello! How can I help?\n\n > hi');
    // …and Enter landed as its own delayed write.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(bridge.commands, ['hi', '\n']);
  });

  test('two quick messages into a TUI are two submissions, not one',
      () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..altScreen = true
      ..screenLines =[' some tui ', ' > '];
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 30),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_one',
      text: 'one',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_two',
      text: 'two',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // The second message arrives before the first one's Enter. The
    // pending Enter is flushed, not dropped: the first message is
    // submitted on its own, and the second one starts in a fresh
    // composer. Dropping it merged both into a single submission
    // and the first message was never sent.
    expect(bridge.commands, ['one', '\n', 'two', '\n']);
  });

  test('/history of an opencode TUI returns the conversation tail '
      'as clean text', () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..altScreen = true
      ..screenLines = [' opencode  ⟨build⟩', '…', ' > '];
    final gateway = _FakeGateway()
      ..ready = true
      ..tail = '🧑 status?\n\n🤖 all green';
    final sent = <(String, String)>[];
    final images = <(String, int)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      onImage: (chat, bytes) => images.add((chat, bytes)),
      gateway: gateway,
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_scr',
      text: '/history',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sent.single.$2, '🧑 status?\n\n🤖 all green');
    expect(images, isEmpty, reason: 'conversation beats a picture');
  });

  test('/history sends a rendered PNG when available, the text '
      'reconstruction otherwise', () async {
    final bridge = _RecordingBridge()
      ..screenLines = ['', ' opencode ', ' > ']
      ..png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]); // PNG magic
    final sent = <(String, String)>[];
    final images = <(String, int)>[];
    var integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      onImage: (chat, bytes) => images.add((chat, bytes)),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_img',
      text: '/history',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(bridge.commands, isEmpty);
    expect(images, [('oc_chat', 4)]);
    expect(sent, isEmpty, reason: 'image path, no text fallback');

    // Rasterization unavailable → the text reconstruction.
    bridge.png = null;
    integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
    );
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_txt',
      text: '/history',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.last.$2, ' opencode \n > ');
  });

  test('a TUI launched mid-capture ends it with the hint, not '
      'redraw garbage', () async {
    final bridge = _RecordingBridge();
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 30),
      maxOutputWindow: const Duration(seconds: 5),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_oc',
      text: 'opencode',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(bridge.commands, ['opencode\n']);

    // A banner line, then the app switches to the alternate
    // screen (DECSET 1049) and starts painting its layout.
    bridge.outputController.add(utf8.encode('opencode v1.6.0\r\n'));
    bridge.outputController
        .add(utf8.encode('\x1b[?1049h\x1b[H\x1b[2J┌─ hi ─┐\r\n'));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sent.length, 1);
    // The launch is sniffed (echoed `opencode` right before the
    // screen switch) — the opencode-specific announcement, not
    // the generic hint, and never the box-drawing junk.
    expect(sent.single.$2, contains('opencode detected'));
    expect(sent.single.$2, isNot(contains('┌')));
  });

  test('messages into a running opencode TUI are typed into it, so '
      'they land in the session it displays', () async {
    final bridge = _RecordingBridge()..cwd = 'E:\\proj';
    final gateway = _FakeGateway()
      ..ready = true
      ..reply = 'the answer';
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 30),
      gateway: gateway,
    );

    // Launch: the shell echoes `opencode`, then the app switches
    // the screen. The router sniffs the echo and announces the
    // server routing instead of the generic TUI hint.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_launch',
      text: 'opencode',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    bridge.outputController
        .add(utf8.encode('PS E:\\proj> opencode\r\n'));
    bridge.outputController.add(utf8.encode('\x1b[?1049h\x1b[H'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(sent.single.$2, contains('opencode detected'));

    // Follow-up chat while the TUI owns the terminal: the text is
    // TYPED INTO the TUI (it then submits to the session it shows
    // — including a brand-new one the server doesn't know yet), and
    // the reply comes back as pure text.
    sent.clear();
    bridge.altScreen = true;
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_chat',
      text: 'status?',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(bridge.commands, ['opencode\n', 'status?', '\n'],
        reason: 'typed into the TUI; Enter follows as its own write');
    expect(gateway.lastMsg, 'status?');
    expect(sent.single.$2, 'the answer');
  });

  test('a locally-launched opencode TUI is recognized from its '
      'screen and driven through the server', () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..altScreen = true
      // No launch capture ever saw it start (local desktop launch)
      // — but the rendered screen carries the brand header.
      ..screenLines = [
        ' opencode  ⟨build⟩  glm-5.3',
        '────────────────────────────',
        ' user: hello?',
        '',
        ' > ',
      ];
    final gateway = _FakeGateway()
      ..ready = true
      ..reply = 'the answer';
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      gateway: gateway,
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_local',
      text: 'status?',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(bridge.commands, ['status?', '\n'],
        reason: 'the TUI decides which session it lands in');
    expect(gateway.lastMsg, 'status?');
    expect(sent.single.$2, 'the answer');
  });

  test('a message the TUI never submits gets a hint, not silence',
      () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..altScreen = true
      ..screenLines = [' opencode  ⟨build⟩', ' > '];
    final gateway = _FakeGateway()
      ..ready = true
      ..submits = false;
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      gateway: gateway,
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_nosub',
      text: 'hello?',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(sent.single.$2, contains('nothing came back'));
  });

  test('/raw relays raw text into a TUI even when it is opencode',
      () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..altScreen = true
      ..screenLines = [' opencode  ⟨build⟩', ' > '];
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
      outputWindow: const Duration(milliseconds: 30),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_type',
      text: '/raw q',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));

    // Raw keys go into the TUI (quit it), the server is bypassed
    // (the default fake gateway is not ready and never consulted).
    // The text lands immediately…
    expect(bridge.commands, ['q']);
    // …and Enter follows as its OWN write ~150ms later: TUIs parse
    // input per keypress, and text+CR in a single write gets the
    // CR swallowed (opencode's /quit hung on screen until split).
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(bridge.commands, ['q', '\n']);
    // The reply is the mirrored screen (verbatim spacing).
    expect(sent.single.$2, ' opencode  ⟨build⟩\n > ');
  });

  test('no active terminal replies a hint instead of executing', () async {
    final bridge = _RecordingBridge()..hasTerminal = false;
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
    );

    integration.handleEvent(const FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_1',
      text: 'ls',
    ));

    expect(bridge.commands, isEmpty);
    expect(sent.single.$2, 'No active terminal in Octodo.');
  });

  test('non-text events are ignored', () async {
    final bridge = _RecordingBridge();
    final integration = await _routerFor(
        creds: _ownerCreds(), bridge: bridge);
    integration.handleEvent(const FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_img',
      text: '',
    ));
    expect(bridge.commands, isEmpty);
  });

  // ── Phase 2: cards, bindings, confirmations ────────────────────

  test('a long output is one pager card, pages replace it in place',
      () async {
    final bridge = _RecordingBridge();
    final sent = <(String, String)>[];
    final cards = <Map<String, dynamic>>[];
    final channel = _FakeChannel();
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
      onSend: (chat, text) => sent.add((chat, text)),
      onCard: (_, card) => cards.add(card),
      outputWindow: const Duration(milliseconds: 30),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_long',
      text: 'cat bigfile',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));

    // 4000 characters of output — more than one page.
    bridge.outputController
        .add(utf8.encode(List.filled(400, 'x' * 10).join('\n')));
    bridge.outputController.add(utf8.encode('PS C:\\Users\\Sun> '));
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(sent, isEmpty,
        reason: 'the output lives in the card, not in chat messages');
    expect(cards.length, 1, reason: 'one pager card carries page 1');
    final body = cards.single['body'] as Map;
    final pageDiv = (body['elements'] as List)
        .firstWhere((e) => (e as Map)['tag'] == 'div') as Map;
    expect((pageDiv['text'] as Map)['tag'], 'plain_text',
        reason: 'terminal output is plain text (§2.1)');
    final pageOne = (pageDiv['text'] as Map)['content'] as String;
    expect(cards.single['config']['update_multi'], isTrue,
        reason: 'the card must be re-updatable in place');

    final action = (body['elements'] as List)
        .firstWhere((e) => (e as Map)['tag'] == 'action') as Map;
    final buttons = (action)['actions'] as List;
    final nextValue = ((buttons.first as Map)['value']) as Map<String, dynamic>;
    expect(nextValue['a'], 'page');
    expect(nextValue['p'], '1');

    // The user taps "Next": the card is replaced in place (mode A) —
    // the chat gains no new message.
    final answer = await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: nextValue,
    ));
    expect(sent, isEmpty);
    final card = answer!['card'] as Map;
    expect(card['type'], 'raw');
    final updated = card['data'] as Map;
    expect(updated['header']['subtitle']['content'], 'page 2 / 2');
    final updatedDiv = ((updated['body'] as Map)['elements'] as List)
        .firstWhere((e) => (e as Map)['tag'] == 'div') as Map;
    final pageTwo = (updatedDiv['text'] as Map)['content'] as String;
    expect(pageTwo, isNot(pageOne),
        reason: 'the card now shows a different chunk of the output');
  });

  test('/status reports the workspace, its panes and the focused tab',
      () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [FeishuWorkspace('ws_1', 'octodo')]
      ..panes = const [
        FeishuPaneStatus(
          id: 'pane_1',
          number: 1,
          focused: true,
          tabs: [
            FeishuTabStatus(
              id: 'tab_1',
              title: 'pwsh',
              cwd: r'E:\src\octodo',
              focused: false,
            ),
            FeishuTabStatus(
              id: 'tab_2',
              title: 'opencode',
              cwd: r'E:\src\octodo',
              focused: true,
            ),
          ],
        ),
        FeishuPaneStatus(id: 'pane_2', number: 2, focused: false, tabs: []),
      ];
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_status',
      text: '/status',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final reply = sent.single.$2;
    expect(reply, contains('Workspaces:'));
    expect(reply, contains('1. octodo'));
    expect(reply, contains('Target: the active workspace'));
    expect(reply, contains('Panes:'));
    expect(reply, contains('1. [focused]'));
    expect(reply, contains('2.'));
    expect(reply, contains('opencode'));
    expect(reply, contains(r'E:\src\octodo'));
  });

  test('/attach <n> binds the chat to the n-th workspace, <n>.<m> to '
      'its m-th pane', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [
        FeishuWorkspace('ws_1', 'octodo'),
        FeishuWorkspace('ws_2', 'docs'),
      ]
      ..panes = const [
        FeishuPaneStatus(id: 'pane_1', number: 1, focused: true, tabs: []),
        FeishuPaneStatus(id: 'pane_2', number: 2, focused: false, tabs: []),
      ];
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onSend: (chat, text) => sent.add((chat, text)),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_attach',
      text: '/attach 2.2',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sent.last.$2, contains('docs'));
    expect(sent.last.$2, contains('pane 2'));

    // The command now goes to that workspace — and the pane is
    // focused first, so it lands in the right one.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_cmd',
      text: 'echo hi',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(bridge.targets, ['ws_2']);
    expect(bridge.focusedPanes, ['pane_2']);
  });

  test('/attach sends the workspace picker card', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [
        FeishuWorkspace('ws_1', 'octodo'),
        FeishuWorkspace('ws_2', 'docs'),
      ];
    final cards = <Map<String, dynamic>>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      onCard: (_, card) => cards.add(card),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_attach',
      text: '/attach',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(cards.length, 1);
    final body = cards.single['body'] as Map<String, dynamic>;
    final elements = body['elements'] as List;
    expect(elements.length, 2);
    final first = (elements.first as Map)['actions'] as List;
    final value = ((first.first as Map)['value']) as Map<String, dynamic>;
    expect(value['a'], 'attach');
    expect(value['id'], 'ws_1');
  });

  test('a bound chat drives its own workspace', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [
        FeishuWorkspace('ws_1', 'octodo'),
        FeishuWorkspace('ws_2', 'docs'),
      ];
    final channel = _FakeChannel();
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
    );

    // Bind the chat to the second workspace through the card.
    final answer = await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: {'a': 'attach', 'id': 'ws_2'},
    ));
    expect((answer!['toast'] as Map)['content'], contains('docs'));

    // The next command goes to the bound workspace, not the active
    // one.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_cmd',
      text: 'echo hi',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(bridge.commands, ['echo hi\n']);
    expect(bridge.targets, ['ws_2']);
  });

  test('/detach sends the chat back to the active workspace', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [FeishuWorkspace('ws_2', 'docs')];
    final channel = _FakeChannel();
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
      onSend: (chat, text) => sent.add((chat, text)),
    );

    await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: {'a': 'attach', 'id': 'ws_2'},
    ));

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_detach',
      text: '/detach',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_cmd',
      text: 'echo hi',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(bridge.targets, [null]);
  });

  test('a card action from an unlisted operator is refused', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [FeishuWorkspace('ws_1', 'octodo')];
    final channel = _FakeChannel();
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
    );

    final answer = await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_stranger',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: {'a': 'attach', 'id': 'ws_1'},
    ));
    expect((answer!['toast'] as Map)['type'], 'error');

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_cmd',
      text: 'echo hi',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(bridge.targets, [null], reason: 'the binding was not made');
  });

  test('a dangerous command waits for the confirmation card', () async {
    final bridge = _RecordingBridge();
    final cards = <Map<String, dynamic>>[];
    final updates = <(String, Map<String, dynamic>)>[];
    final channel = _FakeChannel();
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
      onCard: (_, card) => cards.add(card),
      onUpdateCard: (token, card) => updates.add((token, card)),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_rm',
      text: 'rm -rf build',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(bridge.commands, isEmpty,
        reason: 'nothing runs before the user confirms');
    expect(cards.length, 1);
    final elements = (cards.single['body'] as Map)['elements'] as List;
    final action = elements.firstWhere((e) => (e as Map)['tag'] == 'action');
    final buttons = (action as Map)['actions'] as List;
    expect(buttons.length, 3, reason: 'run once / always / cancel (§4.1)');
    final runValue = ((buttons.first as Map)['value']) as Map<String, dynamic>;
    expect(runValue['a'], 'confirm');
    expect(runValue['d'], 'once');
    expect(((buttons[1] as Map)['value'])['d'], 'always');
    expect(((buttons.last as Map)['value'])['a'], 'cancel');

    // The user presses "Run once": the command goes out.
    final answer = await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: runValue,
    ));
    expect((answer!['toast'] as Map)['content'], 'Running.');
    expect(bridge.commands, ['rm -rf build\n']);

    // After the answer, the card settles into its terminal state
    // (mode B — the deferred update spends the callback token).
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(updates.length, 1);
    expect(updates.single.$1, 'c-1');
    expect(updates.single.$2['header']['title']['content'],
        'Command dispatched');
    expect(updates.single.$2['body']['elements'], hasLength(1),
        reason: 'no buttons left on the terminal state');
  });

  test('"Always" grants the pattern for the bound workspace', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [FeishuWorkspace('ws_1', 'octodo')];
    final cards = <Map<String, dynamic>>[];
    final channel = _FakeChannel();
    File? approvalFile;
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
      onCard: (_, card) => cards.add(card),
      approvalFileOut: (f) => approvalFile = f,
    );

    // Bind the chat to ws_1 — a grant is keyed to a bound workspace.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_attach',
      text: '/attach 1',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    Future<(String, Map<String, dynamic>)> askAndAlways(String id) async {
      integration.handleEvent(FeishuInboundEvent(
        senderOpenId: 'ou_owner',
        chatId: 'oc_chat',
        messageId: 'om_$id',
        text: 'rm -rf $id',
        createTime: DateTime.now().millisecondsSinceEpoch,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final elements = (cards.last['body'] as Map)['elements'] as List;
      final action =
          elements.firstWhere((e) => (e as Map)['tag'] == 'action') as Map;
      final alwaysValue = ((action['actions'] as List)[1] as Map)['value']
          as Map<String, dynamic>;
      final answer = await channel.handler!(FeishuCardActionEvent(
        operatorOpenId: 'ou_owner',
        chatId: 'oc_chat',
        messageId: 'om_card_$id',
        token: 'c-$id',
        value: alwaysValue,
      ));
      return (id, answer!);
    }

    // First occurrence: asks; "Always" runs it and records the grant.
    final (id, answer) = await askAndAlways('first');
    expect((answer['toast'] as Map)['content'], 'Running.');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final grants =
        await FeishuApprovalStore(approvalFile!).load();
    expect(grants, contains('ws_1\nrm -rf'),
        reason: 'the grant is persisted for the restart');

    // Second occurrence: same pattern, same workspace — no card, it
    // just runs.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_second',
      text: 'rm -rf second',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cards.length, 1,
        reason: 'the grant suppresses the second confirmation');
    expect(bridge.commands.last, 'rm -rf second\n');
  });

  test('"Always" never bypasses the hard-deny patterns', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [FeishuWorkspace('ws_1', 'octodo')];
    final cards = <Map<String, dynamic>>[];
    final channel = _FakeChannel();
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
      onCard: (_, card) => cards.add(card),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_attach',
      text: '/attach 1',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    Map<String, dynamic> alwaysValue() {
      final elements = (cards.last['body'] as Map)['elements'] as List;
      final action =
          elements.firstWhere((e) => (e as Map)['tag'] == 'action') as Map;
      return ((action['actions'] as List)[1] as Map)['value']
          as Map<String, dynamic>;
    }

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_format',
      text: 'format e: /q',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cards.length, 1);
    await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: alwaysValue(),
    ));
    expect(bridge.commands.last, 'format e: /q\n');

    // The identical command asks again — a hard-deny pattern is a
    // human decision every time (§4.2).
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_format2',
      text: 'format e: /q',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cards.length, 2,
        reason: 'format is hard-denied: "always" must not suppress it');
  });

  test('a declined dangerous command never runs', () async {
    final bridge = _RecordingBridge();
    final cards = <Map<String, dynamic>>[];
    final updates = <(String, Map<String, dynamic>)>[];
    final channel = _FakeChannel();
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
      onCard: (_, card) => cards.add(card),
      onUpdateCard: (token, card) => updates.add((token, card)),
    );

    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_rm',
      text: 'git reset --hard',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final elements = (cards.single['body'] as Map)['elements'] as List;
    final action = elements.firstWhere((e) => (e as Map)['tag'] == 'action');
    final buttons = (action as Map)['actions'] as List;
    final cancelValue =
        ((buttons.last as Map)['value']) as Map<String, dynamic>;

    await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: cancelValue,
    ));
    expect(bridge.commands, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(updates.single.$2['header']['title']['content'], 'Cancelled');
    expect(updates.single.$2['header']['template'], 'grey');
  });

  test('a non-binder may not drive a chat someone else bound', () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [FeishuWorkspace('ws_1', 'octodo')];
    final sent = <(String, String)>[];
    final integration = await _routerFor(
      creds: _ownerCreds(allowed: ['ou_owner', 'ou_friend']),
      bridge: bridge,
      channel: _FakeChannel(),
      onSend: (chat, text) => sent.add((chat, text)),
    );

    // ou_owner binds the chat to ws_1.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_attach',
      text: '/attach 1',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // ou_friend (whitelisted, but not the binder) sends a command.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_friend',
      chatId: 'oc_chat',
      messageId: 'om_cmd',
      text: 'echo hijacked',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(bridge.commands, isEmpty,
        reason: 'only the binder may drive the terminal (§3.2)');
    expect(sent.last.$2, contains('another member'));

    // /status stays open — read-only.
    final before = sent.length;
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_friend',
      chatId: 'oc_chat',
      messageId: 'om_status',
      text: '/status',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sent.length, greaterThan(before),
        reason: 'read-only commands answer for everyone whitelisted');
  });

  test('the picker card disables the current binding and offers unbind',
      () async {
    final bridge = _RecordingBridge()
      ..workspaces = const [
        FeishuWorkspace('ws_1', 'octodo'),
        FeishuWorkspace('ws_2', 'docs'),
      ];
    final cards = <Map<String, dynamic>>[];
    final channel = _FakeChannel();
    final integration = await _routerFor(
      creds: _ownerCreds(),
      bridge: bridge,
      channel: channel,
      onCard: (_, card) => cards.add(card),
    );

    // Before binding: ws_1 is a plain, enabled button.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_pick0',
      text: '/attach',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    List<Map> buttonsOf(Map card) => ((card['body'] as Map)['elements'] as List)
        .where((e) => (e as Map)['tag'] == 'action')
        .expand((e) => e['actions'] as List)
        .cast<Map>()
        .toList();

    final before = buttonsOf(cards.last)
        .firstWhere((b) => (b['value'] as Map)['id'] == 'ws_1');
    expect(before['disabled'] ?? false, isFalse);
    expect(before['type'], 'default');

    // Press it: the answer re-renders the picker in place (mode A) —
    // the bound workspace is disabled and marked, and an unbind
    // button appears.
    final answer = await channel.handler!(FeishuCardActionEvent(
      operatorOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_card',
      token: 'c-1',
      value: {'a': 'attach', 'id': 'ws_1'},
    ));
    final card = answer!['card'] as Map;
    expect(card['type'], 'raw');
    final bound = buttonsOf(card['data'] as Map)
        .firstWhere((b) => (b['value'] as Map)['id'] == 'ws_1');
    expect(bound['disabled'], isTrue, reason: 'no double binding (§3.1)');
    expect((bound['text'] as Map)['content'], contains('current'));
    expect(
      buttonsOf(card['data'] as Map)
          .any((b) => (b['value'] as Map)['a'] == 'detach'),
      isTrue,
      reason: 'the bound chat gets an unbind button',
    );
    expect((answer['toast'] as Map)['content'], contains('octodo'));

    // The next picker reflects the binding too.
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_pick',
      text: '/attach',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final after = buttonsOf(cards.last)
        .firstWhere((b) => (b['value'] as Map)['id'] == 'ws_1');
    expect(after['disabled'], isTrue);
  });
}

/// Build a router wired to fakes. [onSend] records outbound text.
/// Async so the credential save is flushed before the router reads.
Future<FeishuIntegration> _routerFor({
  required FeishuCredentials creds,
  required _RecordingBridge bridge,
  void Function(String chat, String text)? onSend,
  void Function(String chat, int bytes)? onImage,
  void Function(String chat, Map<String, dynamic> card)? onCard,
  void Function(String token, Map<String, dynamic> card)? onUpdateCard,
  void Function(File approvalFile)? approvalFileOut,
  Duration outputWindow = const Duration(seconds: 5),
  Duration maxOutputWindow = const Duration(minutes: 5),
  OpencodeGateway? gateway,
  _FakeChannel? channel,
}) async {
  final dir = Directory.systemTemp.createTempSync('feishu_router');
  addTearDown(() => dir.deleteSync(recursive: true));
  final store = FeishuCredentialStore(
      File('${dir.path}${Platform.pathSeparator}c.json'));
  await store.save(creds);

  final approvalFile =
      File('${dir.path}${Platform.pathSeparator}a.json');
  approvalFileOut?.call(approvalFile);

  final api = _RecordingApiClient(onSend ?? (_, _) {},
      onImage: onImage, onCard: onCard, onUpdateCard: onUpdateCard);
  final integration = FeishuIntegration(
    bridge: bridge,
    channel: channel ?? _FakeChannel(),
    api: api,
    credentialStore: store,
    bindingStore: FeishuBindingStore(
        File('${dir.path}${Platform.pathSeparator}b.json')),
    approvalStore: FeishuApprovalStore(approvalFile),
    outputWindow: outputWindow,
    maxOutputWindow: maxOutputWindow,
    opencode: gateway ?? _FakeGateway(),
  );
  // Load the credentials written above so the whitelist is active.
  await integration.sync(enabled: true);
  return integration;
}

/// Subclass of the real client overriding the outbound path so no
/// HTTP happens; sends are recorded via [onSend], images via
/// [onImage], cards via [onCard], deferred card updates via
/// [onUpdateCard].
class _RecordingApiClient extends FeishuApiClient {
  final void Function(String chat, String text) onSend;
  final void Function(String chat, int bytes)? onImage;
  final void Function(String chat, Map<String, dynamic> card)? onCard;
  final void Function(String token, Map<String, dynamic> card)? onUpdateCard;
  _RecordingApiClient(this.onSend,
      {this.onImage, this.onCard, this.onUpdateCard})
      : super();

  @override
  Future<void> sendText(String chatId, String text) async =>
      onSend(chatId, text);

  @override
  Future<void> sendImage(String chatId, Uint8List png) async =>
      onImage?.call(chatId, png.length);

  @override
  Future<void> sendCard(String chatId, Map<String, dynamic> card) async =>
      onCard?.call(chatId, card);

  @override
  Future<void> updateCard({
    required String token,
    required Map<String, dynamic> card,
  }) async =>
      onUpdateCard?.call(token, card);
}
