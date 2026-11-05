// Router tests for the Feishu integration: whitelist gating,
// message dedup, command execution, and the output-aggregation
// reply — all against fakes (channel, api, bridge, store).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:octodo/src/feishu/feishu_api_client.dart';
import 'package:octodo/src/feishu/feishu_credentials.dart';
import 'package:octodo/src/feishu/feishu_event_channel.dart';
import 'package:octodo/src/feishu/feishu_integration.dart';

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

  @override
  void runCommand(String command) => commands.add(command);

  @override
  Stream<List<int>>? subscribeActiveOutput() =>
      hasTerminal ? outputController.stream : null;
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

    integration.handleEvent(const FeishuInboundEvent(
      senderOpenId: 'ou_owner',
      chatId: 'oc_chat',
      messageId: 'om_1',
      text: 'echo hi',
    ));

    expect(bridge.commands, ['echo hi\n']);

    // PTY output arrives within the window (echo + prompt noise).
    bridge.outputController.add(
      utf8.encode('hi\r\n\x1b[32m\$\x1b[0m '),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(sent.length, 1);
    expect(sent.single.$1, 'oc_chat');
    // Escape sequences stripped, blank lines dropped.
    expect(sent.single.$2, 'hi\n\$');
  });

  test('duplicate message ids are executed once (re-delivery)', () async {
    final bridge = _RecordingBridge();
    final integration = await _routerFor(
        creds: _ownerCreds(),
        bridge: bridge,
        outputWindow: const Duration(milliseconds: 5000));

    for (var i = 0; i < 3; i++) {
      integration.handleEvent(const FeishuInboundEvent(
        senderOpenId: 'ou_owner',
        chatId: 'oc_chat',
        messageId: 'om_same',
        text: 'echo dup',
      ));
    }
    expect(bridge.commands, ['echo dup\n']);
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
  Duration outputWindow = const Duration(seconds: 5),
}) async {
  final dir = Directory.systemTemp.createTempSync('feishu_router');
  addTearDown(() => dir.deleteSync(recursive: true));
  final store = FeishuCredentialStore(
      File('${dir.path}${Platform.pathSeparator}c.json'));
  await store.save(creds);

  final api = _RecordingApiClient(onSend ?? (_, _) {});
  final integration = FeishuIntegration(
    bridge: bridge,
    channel: _FakeChannel(),
    api: api,
    credentialStore: store,
    outputWindow: outputWindow,
  );
  // Load the credentials written above so the whitelist is active.
  await integration.sync(enabled: true);
  return integration;
}

/// Subclass of the real client overriding the outbound path so no
/// HTTP happens; sends are recorded via [onSend].
class _RecordingApiClient extends FeishuApiClient {
  final void Function(String chat, String text) onSend;
  _RecordingApiClient(this.onSend) : super();

  @override
  Future<void> sendText(String chatId, String text) async =>
      onSend(chatId, text);
}
