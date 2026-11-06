// Router tests for the Feishu integration: whitelist gating,
// message dedup, command execution, and the output-aggregation
// reply — all against fakes (channel, api, bridge, store).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_api_client.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';
import 'package:octodo/src/feishu/feishu_event_channel.dart';
import 'package:octodo/src/feishu/feishu_integration.dart';
import 'package:octodo/src/feishu/opencode_client.dart';

class _FakeChannel implements FeishuEventChannel {
  final eventsController = StreamController<FeishuInboundEvent>.broadcast();
  FeishuCredentials? startedWith;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<FeishuInboundEvent> get events => eventsController.stream;

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
  final outputController = StreamController<List<int>>.broadcast();
  bool hasTerminal = true;
  bool inAltScreen = false;
  List<String>? screenLines;
  String terminalId = 'term_1';
  String? cwd;
  Uint8List? png;

  @override
  void runCommand(String command) => commands.add(command);

  @override
  Stream<List<int>>? subscribeActiveOutput() =>
      hasTerminal ? outputController.stream : null;

  @override
  bool? activeTerminalInAltScreen() =>
      hasTerminal ? inAltScreen : null;

  @override
  List<String>? snapshotActiveScreen() =>
      hasTerminal ? screenLines : null;

  @override
  String? activeTerminalId() => hasTerminal ? terminalId : null;

  @override
  String? activeTerminalCwd() => hasTerminal ? cwd : null;

  @override
  Future<Uint8List?> snapshotActiveTerminalPng() async =>
      hasTerminal ? png : null;
}

/// Server-side of the opencode path, faked: [ready] gates both
/// ensure() and chat(); [tail] is what conversationTail returns.
class _FakeGateway implements OpencodeGateway {
  bool ready = false;
  String? reply;
  String? tail;
  String? lastDir;
  String? lastMsg;

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
      ..inAltScreen = true
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
    // purpose (chat input, 'q', '/' …).
    expect(bridge.commands, ['hi\n']);

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
  });

  test('/screen of an opencode TUI returns the conversation tail '
      'as clean text', () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..inAltScreen = true
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
      text: '/screen',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sent.single.$2, '🧑 status?\n\n🤖 all green');
    expect(images, isEmpty, reason: 'conversation beats a picture');
  });

  test('/screen sends a rendered PNG when available, the text '
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
      text: '/screen',
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
      text: '/screen',
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
    expect(sent.single.$2, contains('opencode is running'));
    expect(sent.single.$2, isNot(contains('┌')));
  });

  test('messages into a running opencode TUI auto-route via the server',
      () async {
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
    expect(sent.single.$2, contains('opencode is running'));

    // Follow-up chat while the TUI owns the terminal: server path,
    // pure text reply, no keystrokes typed into the TUI.
    sent.clear();
    bridge.inAltScreen = true;
    integration.handleEvent(FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_chat',
      text: 'status?',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(bridge.commands, ['opencode\n'],
        reason: 'only the launch itself hit the terminal');
    expect(gateway.lastMsg, 'status?');
    expect(sent.single.$2, 'the answer');
  });

  test('a locally-launched opencode TUI is recognized from its '
      'screen and routed via the server', () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..inAltScreen = true
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
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(bridge.commands, isEmpty, reason: 'server path, no keystrokes');
    expect(gateway.lastMsg, 'status?');
    expect(sent.single.$2, 'the answer');
  });

  test('/type relays raw text into a TUI even when it is opencode',
      () async {
    final bridge = _RecordingBridge()
      ..cwd = 'E:\\proj'
      ..inAltScreen = true
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
      text: '/type q',
      createTime: DateTime.now().millisecondsSinceEpoch,
    ));

    // Raw keys go into the TUI (quit it), the server is bypassed
    // (the default fake gateway is not ready and never consulted),
    // and the reply is the mirrored screen (verbatim spacing).
    expect(bridge.commands, ['q\n']);
    await Future<void>.delayed(const Duration(milliseconds: 80));
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
}

/// Build a router wired to fakes. [onSend] records outbound text.
/// Async so the credential save is flushed before the router reads.
Future<FeishuIntegration> _routerFor({
  required FeishuCredentials creds,
  required _RecordingBridge bridge,
  void Function(String chat, String text)? onSend,
  void Function(String chat, int bytes)? onImage,
  Duration outputWindow = const Duration(seconds: 5),
  Duration maxOutputWindow = const Duration(minutes: 5),
  OpencodeGateway? gateway,
}) async {
  final dir = Directory.systemTemp.createTempSync('feishu_router');
  addTearDown(() => dir.deleteSync(recursive: true));
  final store = FeishuCredentialStore(
      File('${dir.path}${Platform.pathSeparator}c.json'));
  await store.save(creds);

  final api = _RecordingApiClient(onSend ?? (_, _) {}, onImage: onImage);
  final integration = FeishuIntegration(
    bridge: bridge,
    channel: _FakeChannel(),
    api: api,
    credentialStore: store,
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
/// [onImage].
class _RecordingApiClient extends FeishuApiClient {
  final void Function(String chat, String text) onSend;
  final void Function(String chat, int bytes)? onImage;
  _RecordingApiClient(this.onSend, {this.onImage}) : super();

  @override
  Future<void> sendText(String chatId, String text) async =>
      onSend(chatId, text);

  @override
  Future<void> sendImage(String chatId, Uint8List png) async =>
      onImage?.call(chatId, png.length);
}
